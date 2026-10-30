# Aurora PostgreSQL Serverless v2. One cluster, a database and role per service (databases.sql creates them),
# which keeps ownership separate now and lets any service move to its own cluster later without code changes.
data "aws_rds_engine_version" "postgres" {
  engine  = "aurora-postgresql"
  version = var.db_engine_version != "" ? var.db_engine_version : "17"
  latest  = var.db_engine_version == ""
}

# The standby's cluster is encrypted with a key of its own in its own region (an encrypted global-database member cannot use another region's key).
resource "aws_kms_key" "standby_database" {
  count = local.is_secondary ? 1 : 0

  description             = "${local.name}: Aurora storage encryption in the standby region"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "standby_database" {
  count = local.is_secondary ? 1 : 0

  name          = "alias/${local.name}-database"
  target_key_id = aws_kms_key.standby_database[0].key_id
}

module "db" {
  source  = "terraform-aws-modules/rds-aurora/aws"
  version = "~> 9.0"

  name           = local.name
  engine         = data.aws_rds_engine_version.postgres.engine
  engine_version = data.aws_rds_engine_version.postgres.version
  engine_mode    = "provisioned"

  # A standby is a secondary member of the global database: it has no master user of its own (it replicates the
  # primary's) and no writer until it is promoted.
  is_primary_cluster          = !local.is_secondary
  global_cluster_identifier   = local.is_secondary ? local.global_cluster_id : null
  source_region               = local.is_secondary ? var.peer_region : null
  kms_key_id                  = local.is_secondary ? aws_kms_key.standby_database[0].arn : null
  master_username             = local.is_secondary ? null : "postgres"
  manage_master_user_password = !local.is_secondary # in Secrets Manager, rotated by RDS

  vpc_id                 = module.vpc.vpc_id
  create_db_subnet_group = true
  subnets                = module.vpc.private_subnets
  security_group_rules = {
    from_nodes = {
      description              = "PostgreSQL from the cluster nodes (pods use the node security group)"
      source_security_group_id = module.eks.node_security_group_id
    }
  }

  instance_class = "db.serverless"
  instances      = { for index in range(var.db_instance_count) : "instance-${index + 1}" => {} }
  serverlessv2_scaling_configuration = {
    min_capacity = var.db_min_acu
    max_capacity = var.db_max_acu
  }

  storage_encrypted               = true
  deletion_protection             = var.db_deletion_protection
  backup_retention_period         = local.is_prod ? 14 : 3
  skip_final_snapshot             = !local.is_prod
  copy_tags_to_snapshot           = true
  enabled_cloudwatch_logs_exports = ["postgresql"]
  performance_insights_enabled    = true
  apply_immediately               = !local.is_prod

  create_db_cluster_parameter_group      = true
  db_cluster_parameter_group_family      = "aurora-postgresql17"
  db_cluster_parameter_group_name        = local.name
  db_cluster_parameter_group_description = "Task API: TLS required"
  db_cluster_parameter_group_parameters = [
    { name = "rds.force_ssl", value = "1", apply_method = "immediate" },
    { name = "log_min_duration_statement", value = "1000", apply_method = "immediate" }
  ]
}

# The primary joins its cluster to a global database, which is what lets another region hold a replica of it. Creating
# this does not interrupt the cluster. After a failover the roles swap in AWS but not in this code: the resource below
# keeps describing the same global database, and nothing here needs to change (docs/runbooks/regional-failover.md).
resource "aws_rds_global_cluster" "this" {
  count = local.is_primary ? 1 : 0

  global_cluster_identifier    = local.global_cluster_id
  source_db_cluster_identifier = module.db.cluster_arn
  force_destroy                = false
  deletion_protection          = var.db_deletion_protection

  # Minor upgrades change the engine version out from under Terraform; the source is only read when the global cluster is created.
  lifecycle {
    ignore_changes = [source_db_cluster_identifier, engine_version]
  }
}
