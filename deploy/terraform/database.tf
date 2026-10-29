# Aurora PostgreSQL Serverless v2. One cluster, a database and role per service (databases.sql creates them),
# which keeps ownership separate now and lets any service move to its own cluster later without code changes.
data "aws_rds_engine_version" "postgres" {
  engine  = "aurora-postgresql"
  version = "17"
  latest  = true
}

module "db" {
  source  = "terraform-aws-modules/rds-aurora/aws"
  version = "~> 9.0"

  name           = local.name
  engine         = data.aws_rds_engine_version.postgres.engine
  engine_version = data.aws_rds_engine_version.postgres.version
  engine_mode    = "provisioned"

  master_username             = "postgres"
  manage_master_user_password = true # in Secrets Manager, rotated by RDS

  vpc_id                 = module.vpc.vpc_id
  create_db_subnet_group = true
  subnets                = module.vpc.private_subnets
  security_group_rules = {
    from_nodes = {
      description              = "PostgreSQL from the cluster's nodes (pods use the node security group)"
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
