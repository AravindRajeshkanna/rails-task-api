# Offline checks of the multi-region wiring, of the cross-region backup copy and of the KMS keys: the plan for each role is computed against mocked AWS
# providers, so no credentials are used and nothing is created. They prove the conditional logic (what each role creates and names, who may use which
# key), not that AWS accepts it: that needs a real account (docs/aws/multi-region.md, docs/aws/kms.md).
#
#   cd deploy/terraform && terraform init -backend=false && terraform test

# One mock per provider configuration: the default region, the peer region of the pair, and the region backups are copied to.
mock_provider "aws" {
  # What a mock cannot invent: the identity, the partition, the zones, and anything that is parsed as JSON or as an ARN.
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/tester"
      user_id    = "AIDATESTER"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }
  mock_data "aws_iam_session_context" {
    defaults = {
      arn        = "arn:aws:sts::123456789012:assumed-role/tester/session"
      issuer_arn = "arn:aws:iam::123456789012:role/tester"
    }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:us-east-1:123456789012:mock" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = { arn = "arn:aws:sqs:us-east-1:123456789012:mock" }
  }
  mock_resource "aws_wafv2_web_acl" {
    defaults = { arn = "arn:aws:wafv2:us-east-1:123456789012:regional/webacl/mock/00000000-0000-0000-0000-000000000000" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:123456789012:log-group:mock" }
  }
  mock_resource "aws_cloudwatch_event_bus" {
    defaults = { arn = "arn:aws:events:us-east-1:123456789012:event-bus/mock" }
  }
  mock_resource "aws_ce_anomaly_monitor" {
    defaults = { arn = "arn:aws:ce::123456789012:anomalymonitor/00000000-0000-0000-0000-000000000000" }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/mock" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::mock" }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000" }
  }
  mock_resource "aws_lambda_function" {
    defaults = { arn = "arn:aws:lambda:us-east-1:123456789012:function:mock" }
  }
  mock_resource "aws_acm_certificate" {
    defaults = { arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000" }
  }
  mock_resource "aws_rds_cluster" {
    defaults = { arn = "arn:aws:rds:us-east-1:123456789012:cluster:mock" }
  }
  mock_resource "aws_backup_vault" {
    defaults = { arn = "arn:aws:backup:us-east-1:123456789012:backup-vault:mock" }
  }
  mock_data "aws_eks_addon_version" {
    defaults = { version = "v1.0.0-eksbuild.1" }
  }
  mock_resource "aws_eks_cluster" {
    defaults = {
      arn                   = "arn:aws:eks:us-east-1:123456789012:cluster/mock"
      endpoint              = "https://MOCK.gr7.us-east-1.eks.amazonaws.com"
      version               = "1.33"
      platform_version      = "eks.1"
      identity              = [{ oidc = [{ issuer = "https://oidc.eks.us-east-1.amazonaws.com/id/MOCK" }] }]
      certificate_authority = [{ data = "bW9jaw==" }]
    }
  }
  mock_resource "aws_launch_template" {
    defaults = {
      id             = "lt-0123456789abcdef0"
      latest_version = 1
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  # An alias made in the other stack: the standby finds the primary's replica keys, the primary finds the standby's storage key.
  mock_data "aws_kms_alias" {
    defaults = {
      target_key_arn = "arn:aws:kms:us-east-1:123456789012:key/mrk-00000000000000000000000000000000"
      target_key_id  = "mrk-00000000000000000000000000000000"
    }
  }
}

mock_provider "aws" {
  alias = "peer"

  mock_resource "aws_kms_replica_key" {
    defaults = { arn = "arn:aws:kms:us-west-2:123456789012:key/mrk-00000000000000000000000000000000" }
  }
  mock_data "aws_kms_alias" {
    defaults = {
      target_key_arn = "arn:aws:kms:us-west-2:123456789012:key/00000000-0000-0000-0000-000000000000"
      target_key_id  = "00000000-0000-0000-0000-000000000000"
    }
  }
}

mock_provider "aws" {
  alias = "backup_copy"

  mock_resource "aws_backup_vault" {
    defaults = { arn = "arn:aws:backup:us-west-2:123456789012:backup-vault:mock" }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-west-2:123456789012:key/00000000-0000-0000-0000-000000000000" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::mock-copy" }
  }
}

mock_provider "random" {}
mock_provider "tls" {
  mock_data "tls_certificate" {
    defaults = {
      certificates = [{ sha1_fingerprint = "0000000000000000000000000000000000000000" }]
    }
  }
}
mock_provider "archive" {}
mock_provider "time" {}

variables {
  environment        = "prod"
  root_domain        = "example.com"
  api_subdomain      = "api"
  frontend_subdomain = "app"
  github_repository  = "owner/repo"
  bedrock_model_id   = "model"
}

# The values AWS returns once a certificate exists; the plan only needs them to be well-formed.
override_resource {
  target = aws_acm_certificate.api
  values = {
    domain_validation_options = [{
      domain_name           = "api.example.com"
      resource_record_name  = "_x.api.example.com."
      resource_record_type  = "CNAME"
      resource_record_value = "_y.acm-validations.aws."
    }]
  }
}

run "single_region_creates_none_of_it" {
  command = apply

  assert {
    condition     = local.name == "task-api-prod" && local.app_env == "prod"
    error_message = "A single region keeps the names it always had."
  }
  assert {
    condition     = length(aws_rds_global_cluster.this) == 0 && length(aws_ecr_replication_configuration.to_standby) == 0 && length(aws_s3_bucket_replication_configuration.storage) == 0
    error_message = "A single region has no global database, no ECR replication and no S3 replication."
  }
  assert {
    condition     = length(aws_secretsmanager_secret.service) == 4 && length(aws_iam_role.github_deploy) == 1
    error_message = "A single region owns its secrets and its deploy role."
  }
}

run "primary_publishes_its_data_to_the_standby" {
  command = apply

  variables {
    dr_role     = "primary"
    peer_region = "us-west-2"
  }

  assert {
    condition     = local.name == "task-api-prod" && local.peer_name == "task-api-prod-dr"
    error_message = "The primary keeps its names and knows the standby's."
  }
  assert {
    condition     = length(aws_rds_global_cluster.this) == 1 && aws_rds_global_cluster.this[0].global_cluster_identifier == "task-api-prod-global"
    error_message = "The primary's database joins a global cluster."
  }
  assert {
    condition     = length(aws_ecr_replication_configuration.to_standby) == 1 && length(aws_ecr_repository_creation_template.replicated) == 0
    error_message = "The primary replicates images out; it does not need the creation template."
  }
  assert {
    condition     = alltrue([for name, secret in aws_secretsmanager_secret.service : one(secret.replica).region == "us-west-2"]) && one(aws_secretsmanager_secret.ai_service_token[0].replica).region == "us-west-2"
    error_message = "Every secret has a replica in the standby's region."
  }
  assert {
    condition     = length(aws_s3_bucket_replication_configuration.storage) == 0 && length(aws_route53_record.api_standby) == 0
    error_message = "Until the standby exists there is no S3 replication and no DNS failover."
  }
}

run "primary_with_a_ready_standby_replicates_storage_and_fails_over_dns" {
  command = apply

  variables {
    dr_role     = "primary"
    peer_region = "us-west-2"
    peer_ready  = true
    alb_exists  = true
  }

  assert {
    condition     = one(aws_s3_bucket_replication_configuration.storage[0].rule).destination[0].bucket == "arn:aws:s3:::task-api-prod-dr-storage-123456789012"
    error_message = "Storage replicates to the standby's bucket, whose name is derived, not looked up."
  }
  assert {
    condition     = length(aws_iam_role.storage_replication) == 1 && length(aws_iam_role_policy.storage_replication) == 1
    error_message = "Replication runs as its own role."
  }
  assert {
    condition     = aws_route53_record.api[0].set_identifier == "primary" && aws_route53_record.api_standby[0].set_identifier == "standby"
    error_message = "The name has a primary and a standby answer."
  }
  assert {
    condition     = one(aws_route53_record.api[0].failover_routing_policy).type == "PRIMARY" && one(aws_route53_record.api_standby[0].failover_routing_policy).type == "SECONDARY"
    error_message = "Route 53 serves the primary while it is healthy and the standby when it is not."
  }
  assert {
    condition     = length(aws_route53_health_check.api) == 1 && aws_route53_health_check.api[0].resource_path == "/readyz" && aws_route53_health_check.api[0].failure_threshold == 3
    error_message = "The primary load balancer is health checked on /readyz (database included), not /up."
  }
}

run "dns_failover_waits_for_the_primary_load_balancer" {
  command = apply

  variables {
    dr_role     = "primary"
    peer_region = "us-west-2"
    peer_ready  = true
    alb_exists  = false
  }

  assert {
    condition     = length(aws_route53_record.api) == 0 && length(aws_route53_record.api_standby) == 0 && length(aws_route53_health_check.api) == 0
    error_message = "With no load balancer yet there is nothing to point DNS at."
  }
}

run "standby_is_the_same_code_in_another_region_with_nothing_global" {
  command = apply

  variables {
    region                      = "us-west-2"
    dr_role                     = "secondary"
    peer_region                 = "us-east-1"
    peer_ready                  = true
    alb_exists                  = true
    db_engine_version           = "17.5"
    create_ecr                  = false
    create_github_oidc_provider = false
  }

  assert {
    condition     = local.name == "task-api-prod-dr" && local.app_env == "prod-dr" && local.secret_prefix == "task-api/prod"
    error_message = "The standby has names of its own but reads the primary's secrets."
  }
  assert {
    condition     = length(aws_secretsmanager_secret.service) == 0 && length(aws_secretsmanager_secret.ai_service_token) == 0 && length(tls_private_key.auth_jwt) == 0 && length(aws_iam_user.ses_smtp) == 0
    error_message = "The standby creates no secrets, signing key or SES user: it reads replicas of the primary's."
  }
  assert {
    condition     = length(aws_iam_role.github_deploy) == 0 && length(aws_ecr_repository.service) == 0
    error_message = "CI pushes only to the primary; images reach the standby by replication."
  }
  assert {
    condition     = length(aws_ecr_repository_creation_template.replicated) == 1 && length(aws_ecr_replication_configuration.to_standby) == 0
    error_message = "The standby gives replicated repositories the primary's rules."
  }
  assert {
    condition     = length(aws_kms_key.standby_database) == 1 && length(aws_rds_global_cluster.this) == 0
    error_message = "The standby encrypts its replica with its own key and does not create the global cluster."
  }
  assert {
    condition     = one(aws_s3_bucket_replication_configuration.storage[0].rule).destination[0].bucket == "arn:aws:s3:::task-api-prod-storage-123456789012"
    error_message = "The standby replicates back to the primary's bucket, which is what makes failback a switchover."
  }
  assert {
    condition     = length(aws_route53_record.api) == 0 && length(aws_route53_record.certificate_validation) == 0 && length(aws_route53_record.api_standby) == 0
    error_message = "The standby never owns the public name or the certificate's validation record."
  }
}

run "a_pair_needs_to_name_its_other_half" {
  command = plan

  variables {
    dr_role = "primary"
  }

  expect_failures = [var.peer_region]
}

run "a_region_cannot_be_its_own_standby" {
  command = plan

  variables {
    region      = "us-east-1"
    dr_role     = "secondary"
    peer_region = "us-east-1"
  }

  expect_failures = [var.peer_region]
}

run "an_unknown_role_is_refused" {
  command = plan

  variables {
    dr_role = "tertiary"
  }

  expect_failures = [var.dr_role]
}

# --- Cross-region backup copy (backup.tf) ---

run "no_backup_copy_unless_asked_for" {
  command = apply

  assert {
    condition     = length(aws_backup_plan.database) == 0 && length(aws_backup_vault.copy) == 0 && length(aws_s3_bucket.dumps) == 0 && length(aws_s3_bucket.dumps_copy) == 0
    error_message = "With backup_copy_region empty nothing is created for backups."
  }
}

run "backup_copy_snapshots_the_database_daily_and_copies_it_to_the_other_region" {
  command = apply

  variables {
    backup_copy_region = "us-west-2"
  }

  assert {
    condition     = aws_backup_vault.local[0].name == "task-api-prod-backups" && aws_backup_vault.copy[0].name == "task-api-prod-backups"
    error_message = "A vault in each region, named alike."
  }
  assert {
    condition     = one(aws_backup_plan.database[0].rule).schedule == "cron(0 3 * * ? *)" && one(aws_backup_plan.database[0].rule).target_vault_name == aws_backup_vault.local[0].name
    error_message = "The plan snapshots daily into the local vault."
  }
  assert {
    condition     = one(one(aws_backup_plan.database[0].rule).copy_action).destination_vault_arn == aws_backup_vault.copy[0].arn
    error_message = "...and copies every recovery point to the vault in the other region."
  }
  assert {
    condition     = one(one(aws_backup_plan.database[0].rule).lifecycle).delete_after == 35 && one(one(one(aws_backup_plan.database[0].rule).copy_action).lifecycle).delete_after == 35
    error_message = "Both copies expire after backup_retention_days."
  }
  assert {
    condition     = toset(aws_backup_selection.database[0].resources) == toset([module.db.cluster_arn])
    error_message = "It backs up the Aurora cluster, and only that."
  }
  assert {
    condition     = length(aws_backup_vault_notifications.local) == 1 && contains(aws_backup_vault_notifications.local[0].backup_vault_events, "COPY_JOB_FAILED")
    error_message = "A failed backup or copy reaches the alerts topic."
  }
  assert {
    condition     = aws_backup_vault.local[0].kms_key_arn == aws_kms_key.backup[0].arn && aws_backup_vault.copy[0].kms_key_arn == aws_kms_key.backup_copy[0].arn
    error_message = "Each vault is encrypted with a key of its own region."
  }
}

run "dumps_are_uploaded_write_only_and_replicated_without_their_deletions" {
  command = apply

  variables {
    backup_copy_region = "us-west-2"
  }

  assert {
    condition     = aws_s3_bucket.dumps[0].bucket == "task-api-prod-dumps-123456789012" && aws_s3_bucket.dumps_copy[0].bucket == "task-api-prod-dumps-copy-123456789012"
    error_message = "A dump bucket and its copy."
  }
  assert {
    condition     = one(aws_s3_bucket_replication_configuration.dumps[0].rule).destination[0].bucket == aws_s3_bucket.dumps_copy[0].arn && one(aws_s3_bucket_replication_configuration.dumps[0].rule).delete_marker_replication[0].status == "Disabled"
    error_message = "Dumps replicate to the copy bucket, and a deletion does not."
  }
  assert {
    condition     = aws_s3_bucket_versioning.dumps[0].versioning_configuration[0].status == "Enabled" && aws_s3_bucket_versioning.dumps_copy[0].versioning_configuration[0].status == "Enabled"
    error_message = "Replication needs versioning on both sides."
  }
  assert {
    condition     = one(aws_s3_bucket_lifecycle_configuration.dumps[0].rule).expiration[0].days == 90
    error_message = "Dumps expire after dump_retention_days."
  }
  assert {
    condition     = toset(one(data.aws_iam_policy_document.dump_upload[0].statement).actions) == toset(["s3:AbortMultipartUpload", "s3:PutObject"])
    error_message = "The upload policy can add objects and nothing else: no read, list or delete."
  }
}

run "a_standby_does_not_back_up_what_the_primary_backs_up" {
  command = apply

  variables {
    region             = "us-west-2"
    dr_role            = "secondary"
    peer_region        = "us-east-1"
    backup_copy_region = "us-east-1"
  }

  assert {
    condition     = length(aws_backup_plan.database) == 0 && length(aws_s3_bucket.dumps) == 0
    error_message = "Only the primary's cluster is backed up."
  }
}

run "a_backup_copy_in_the_same_region_is_refused" {
  command = plan

  variables {
    region             = "us-east-1"
    backup_copy_region = "us-east-1"
  }

  expect_failures = [var.backup_copy_region]
}

# --- The staging pair (envs/staging-dr.tfvars): the same code, to rehearse on ---

run "the_staging_standby_is_named_for_staging_and_answers_to_stagings_name" {
  command = apply

  variables {
    environment        = "staging"
    region             = "us-west-2"
    api_subdomain      = "api.staging"
    frontend_subdomain = "app.staging"
    dr_role            = "secondary"
    peer_region        = "us-east-1"
    peer_ready         = true
    create_ecr         = false
  }

  assert {
    condition     = local.name == "task-api-staging-dr" && local.app_env == "staging-dr" && local.peer_name == "task-api-staging"
    error_message = "The staging standby is task-api-staging-dr and its peer is task-api-staging."
  }
  assert {
    condition     = local.global_cluster_id == "task-api-staging-global" && local.api_domain == "api.staging.example.com"
    error_message = "It joins staging's global cluster and serves staging's name."
  }
  assert {
    condition     = length(aws_secretsmanager_secret.service) == 0 && length(aws_iam_role.github_deploy) == 0 && length(aws_rds_global_cluster.this) == 0
    error_message = "A staging standby owns no secrets, deploy role or global cluster either."
  }
}


# --- KMS keys (docs/aws/kms.md) ---

run "kms_data_key_is_replicable_rotates_and_is_the_only_one_the_application_uses_for_columns" {
  command = apply

  assert {
    condition     = aws_kms_key.data["1"].multi_region == true && aws_kms_key.data["1"].enable_key_rotation == true && aws_kms_key.data["1"].rotation_period_in_days == 365
    error_message = "The data key is a multi-Region key (it cannot be made one later) and rotates every year."
  }
  assert {
    condition     = aws_kms_alias.data[0].name == "alias/task-api-prod-data" && aws_kms_alias.data_generation["1"].name == "alias/task-api-prod-data-g1" && output.kms_data_key_alias == "alias/task-api-prod-data"
    error_message = "The application is configured with one stable alias; each generation has its own as well."
  }
  assert {
    condition     = length(aws_kms_replica_key.data_peer) == 0 && length(data.aws_kms_alias.data_generation) == 0
    error_message = "A single region has no replica to make and nothing to look up."
  }
  assert {
    condition     = anytrue([for statement in data.aws_iam_policy_document.data_key.statement : statement.sid == "RequireTheApplicationContext" && statement.effect == "Deny"])
    error_message = "The key policy refuses any use of the data key that does not carry the application's encryption context."
  }
  assert {
    condition     = aws_kms_key.data["1"].deletion_window_in_days == 30
    error_message = "Production keys wait the longest before deletion."
  }
}

run "kms_wrapped_master_is_bound_to_the_context_the_application_uses" {
  command = apply

  assert {
    condition     = length(aws_kms_ciphertext.deterministic_master[0].context) == 2 && aws_kms_ciphertext.deterministic_master[0].context["app"] == "task-api" && aws_kms_ciphertext.deterministic_master[0].context["purpose"] == "deterministic-master"
    error_message = "The wrapped master must carry exactly the context KmsEncryption.master_context sends, or the application cannot unwrap it."
  }
  assert {
    condition     = contains(keys(local.secrets["api"]), "kms_wrapped_deterministic_key") && !contains(keys(local.secrets["auth"]), "kms_wrapped_deterministic_key")
    error_message = "Only the api's secret carries the wrapped master; the other services do not read these columns."
  }
  assert {
    condition     = length(random_bytes.deterministic_master) == 1 && random_bytes.deterministic_master[0].length == 32
    error_message = "The master is 32 random bytes."
  }
}

run "kms_is_granted_to_the_api_and_worker_alone_and_only_what_each_needs" {
  command = apply

  assert {
    condition     = [for statement in local.workload_statements["api"] : statement.actions if statement.sid == "WrapDataKeys"] == [["kms:GenerateDataKey", "kms:Decrypt"]]
    error_message = "The api makes keys for the values it writes and unwraps them to read."
  }
  assert {
    condition     = [for statement in local.workload_statements["worker"] : statement.actions if statement.sid == "UnwrapDataKeys"] == [["kms:Decrypt"]] && !anytrue([for statement in local.workload_statements["worker"] : statement.sid == "WrapDataKeys"])
    error_message = "The worker only reads encrypted columns, so it may only unwrap."
  }
  assert {
    condition = alltrue([
      for name in ["api", "worker"] : alltrue([
        for statement in local.workload_statements[name] : statement.condition != null && length(statement.condition) == 1 && statement.condition[0].values != null
        if startswith(statement.sid, "WrapData") || startswith(statement.sid, "UnwrapData")
      ])
    ])
    error_message = "Every grant on the data key names the encryption context it requires."
  }
  assert {
    condition = alltrue([
      for name in ["api", "worker"] : alltrue([
        for statement in local.workload_statements[name] : statement.condition[0].variable == "kms:EncryptionContext:app" && statement.condition[0].values == ["task-api"]
        if statement.sid == "WrapDataKeys" || statement.sid == "UnwrapDataKeys"
      ])
    ])
    error_message = "The context a grant requires is the one the application sends."
  }
  assert {
    condition     = !anytrue([for name, statements in local.workload_statements : anytrue([for statement in statements : anytrue([for action in statement.actions : action == "kms:Encrypt" || action == "kms:DescribeKey" || action == "kms:*"])])])
    error_message = "No workload may call Encrypt, DescribeKey or everything: the application calls none of them."
  }
  assert {
    condition     = alltrue([for name in ["auth", "ai", "notifications"] : !anytrue([for statement in local.workload_statements[name] : anytrue([for action in statement.actions : startswith(action, "kms:")])])])
    error_message = "The other services read none of these columns and need no KMS permission."
  }
  assert {
    condition     = [for statement in local.workload_statements["api"] : statement.condition[0].values if statement.sid == "StorageKeyThroughS3"] == [["s3.us-east-1.amazonaws.com"]]
    error_message = "The storage key can be used only through S3."
  }
}

run "kms_storage_and_secrets_use_keys_of_their_own" {
  command = apply

  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.storage.rule).apply_server_side_encryption_by_default[0].sse_algorithm == "aws:kms" && one(aws_s3_bucket_server_side_encryption_configuration.storage.rule).bucket_key_enabled == true
    error_message = "Files are encrypted with the bucket's key, with a bucket key so S3 does not call KMS for every object."
  }
  assert {
    condition     = length(aws_kms_key.storage) == 1 && length(aws_kms_key.secrets) == 1 && aws_kms_key.storage[0].enable_key_rotation && aws_kms_key.secrets[0].enable_key_rotation
    error_message = "Files and secrets each have a rotating key of their own."
  }
  assert {
    condition     = alltrue([for name, secret in aws_secretsmanager_secret.service : secret.kms_key_id != null]) && aws_secretsmanager_secret.ai_service_token[0].kms_key_id != null
    error_message = "Every secret is under the customer-managed key."
  }
  assert {
    condition     = length(local.external_secrets_kms_key_arns) == 1 && local.external_secrets_kms_key_arns[0] == aws_kms_key.secrets[0].arn
    error_message = "External Secrets may decrypt the secrets key, or no ExternalSecret syncs and no pod starts."
  }
}

run "kms_can_be_left_off_where_it_is_not_wanted" {
  command = apply

  variables {
    storage_kms_encryption = false
    secrets_kms_encryption = false
    enable_kms_audit       = false
  }

  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.storage.rule).apply_server_side_encryption_by_default[0].sse_algorithm == "AES256" && length(aws_kms_key.storage) == 0
    error_message = "With the switch off the bucket is encrypted as it was."
  }
  assert {
    condition     = length(aws_kms_key.secrets) == 0 && local.secrets_key_arn == null && alltrue([for name, secret in aws_secretsmanager_secret.service : secret.kms_key_id == null])
    error_message = "With the switch off the secrets use the AWS-managed key."
  }
  assert {
    condition     = length(local.external_secrets_kms_key_arns) == 0
    error_message = "And External Secrets is granted no key that does not exist."
  }
  assert {
    condition     = length(aws_cloudtrail.kms) == 0 && length(aws_cloudwatch_metric_alarm.kms) == 0 && length(aws_s3_bucket.kms_audit) == 0
    error_message = "With auditing off there is no trail, bucket or alarm."
  }
  assert {
    condition     = !anytrue([for statement in local.workload_statements["api"] : statement.sid == "StorageKeyThroughS3"])
    error_message = "The api asks for no storage key that does not exist."
  }
  assert {
    condition     = length(aws_kms_key.data) == 1
    error_message = "The data key is not optional: the columns are encrypted either way."
  }
}

run "kms_audit_records_kms_events_only_and_alarms_on_volume_refusals_and_key_changes" {
  command = apply

  assert {
    condition     = length(aws_cloudtrail.kms) == 1 && aws_cloudtrail.kms[0].enable_log_file_validation == true && aws_cloudtrail.kms[0].is_multi_region_trail == false
    error_message = "One regional trail with validated log files."
  }
  assert {
    condition = alltrue([
      for selector in aws_cloudtrail.kms[0].advanced_event_selector : anytrue([
        for field in selector.field_selector : field.field == "eventSource" && length(field.equals) == 1 && contains(field.equals, "kms.amazonaws.com")
      ])
    ])
    error_message = "The trail records KMS events and nothing else, which is what keeps its bill small."
  }
  assert {
    condition     = join(",", sort(keys(aws_cloudwatch_metric_alarm.kms))) == "access_denied,decrypt_volume,key_changes" && aws_cloudwatch_metric_alarm.kms["decrypt_volume"].threshold == 2000
    error_message = "Three alarms: unusual decrypt volume, refusals, and changes to a key."
  }
  assert {
    condition     = strcontains(aws_cloudwatch_log_metric_filter.kms["decrypt_volume"].pattern, "encryptionContext.app = \"task-api\"")
    error_message = "Decrypt volume counts the application's requests, which the context identifies."
  }
  assert {
    condition     = strcontains(aws_cloudwatch_log_metric_filter.kms["key_changes"].pattern, "ScheduleKeyDeletion") && strcontains(aws_cloudwatch_log_metric_filter.kms["key_changes"].pattern, "UpdateAlias")
    error_message = "Scheduling a key's deletion and re-pointing an alias both raise the alarm."
  }
  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.kms_audit[0].rule).apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
    error_message = "The log bucket is not under a KMS key: logging a key's use into a bucket that uses it would make every log file a KMS event."
  }
}

run "kms_rotation_by_hand_adds_a_generation_and_keeps_the_old_one_usable" {
  command = apply

  variables {
    data_key_generations = [1, 2]
  }

  assert {
    condition     = length(aws_kms_key.data) == 2 && length(aws_kms_alias.data_generation) == 2
    error_message = "Each generation is a key with an alias."
  }
  assert {
    condition     = aws_kms_alias.data[0].target_key_id == aws_kms_key.data["2"].key_id && aws_kms_alias.data[0].target_key_id != aws_kms_key.data["1"].key_id
    error_message = "New values are made under the newest key: the stable alias points at it."
  }
  assert {
    condition     = aws_kms_ciphertext.deterministic_master[0].key_id == aws_kms_key.data["2"].key_id
    error_message = "The master is wrapped again under the newest key, so retiring the old one never takes the only copy with it."
  }
  assert {
    condition     = length(local.data_key_arns) == 2 && alltrue([for statement in local.workload_statements["worker"] : length(statement.resources) == 2 if statement.sid == "UnwrapDataKeys"])
    error_message = "Both generations may still be unwrapped, until nothing refers to the old one."
  }
}

run "kms_generations_must_be_distinct_whole_numbers" {
  command = plan

  variables {
    data_key_generations = [1, 1]
  }

  expect_failures = [var.data_key_generations]
}

run "kms_primary_makes_the_standbys_copy_of_the_data_key" {
  command = apply

  variables {
    dr_role              = "primary"
    peer_region          = "us-west-2"
    data_key_generations = [1, 2]
  }

  assert {
    condition     = length(aws_kms_replica_key.data_peer) == 2 && alltrue([for generation, replica in aws_kms_replica_key.data_peer : replica.primary_key_arn == aws_kms_key.data[generation].arn])
    error_message = "Every generation has a replica in the standby's region, made from the primary's key."
  }
  assert {
    condition     = aws_kms_alias.data_peer[0].name == "alias/task-api-prod-data" && aws_kms_alias.data_peer_generation["1"].name == "alias/task-api-prod-data-g1"
    error_message = "The standby region has the same alias names, so the application there is configured exactly like this one."
  }
}

run "kms_standby_finds_the_primarys_replica_keys_and_makes_none_of_its_own" {
  command = apply

  variables {
    region                      = "us-west-2"
    dr_role                     = "secondary"
    peer_region                 = "us-east-1"
    peer_ready                  = true
    alb_exists                  = true
    db_engine_version           = "17.5"
    create_ecr                  = false
    create_github_oidc_provider = false
  }

  assert {
    condition     = length(aws_kms_key.data) == 0 && length(aws_kms_replica_key.data_peer) == 0 && length(aws_kms_alias.data) == 0
    error_message = "The data key and its replica are the primary's to make."
  }
  assert {
    condition     = length(data.aws_kms_alias.data_generation) == 1 && length(local.data_key_arns) == 1
    error_message = "The standby's application is allowed to unwrap with the replica it finds by alias."
  }
  assert {
    condition     = length(aws_kms_ciphertext.deterministic_master) == 0 && length(random_bytes.deterministic_master) == 0 && length(aws_kms_key.secrets) == 0
    error_message = "The standby makes no secret of its own and wraps nothing: it reads replicas of the primary's."
  }
  assert {
    condition     = length(local.external_secrets_kms_key_arns) == 0
    error_message = "The standby's replicas are under its region's AWS-managed key, which needs no grant."
  }
  assert {
    condition     = length(aws_kms_key.storage) == 1 && aws_kms_alias.storage[0].name == "alias/task-api-prod-dr-storage"
    error_message = "Each region's bucket has a key of its own, named for the stack."
  }
  assert {
    condition     = [for statement in local.workload_statements["api"] : statement.sid if statement.sid == "WrapDataKeys"] == ["WrapDataKeys"]
    error_message = "The standby's api can wrap and unwrap once it is promoted, with its own region's replica."
  }
}

run "kms_storage_replication_carries_the_encrypted_objects_across" {
  command = apply

  variables {
    dr_role     = "primary"
    peer_region = "us-west-2"
    peer_ready  = true
    alb_exists  = true
  }

  assert {
    condition     = one(aws_s3_bucket_replication_configuration.storage[0].rule).source_selection_criteria[0].sse_kms_encrypted_objects[0].status == "Enabled"
    error_message = "S3 skips objects encrypted with a KMS key unless the rule says to replicate them."
  }
  assert {
    condition     = one(aws_s3_bucket_replication_configuration.storage[0].rule).destination[0].encryption_configuration[0].replica_kms_key_id == data.aws_kms_alias.peer_storage[0].target_key_arn
    error_message = "Replicas are encrypted with the standby's own bucket key."
  }
  assert {
    condition     = anytrue([for statement in data.aws_iam_policy_document.replication.statement : statement.sid == "DecryptSourceObjects"]) && anytrue([for statement in data.aws_iam_policy_document.replication.statement : statement.sid == "EncryptReplicas"])
    error_message = "The replication role may read under this region's key and write under the other's, and only through S3."
  }
}

run "kms_storage_replication_without_kms_is_as_it_was" {
  command = apply

  variables {
    dr_role                = "primary"
    peer_region            = "us-west-2"
    peer_ready             = true
    alb_exists             = true
    storage_kms_encryption = false
  }

  assert {
    condition     = length(one(aws_s3_bucket_replication_configuration.storage[0].rule).source_selection_criteria) == 0 && length(one(aws_s3_bucket_replication_configuration.storage[0].rule).destination[0].encryption_configuration) == 0
    error_message = "With the bucket on S3-managed keys the replication rule needs nothing about KMS."
  }
  assert {
    condition     = length(data.aws_kms_alias.peer_storage) == 0
    error_message = "And looks up no key."
  }
}

# Who may push images from GitHub: one exact subject, never a wildcard, never "any run on main". AWS evaluates only aud and sub, so this is the whole of what
# the trust can say about the caller (ADR 72).
run "github_deploy_role_trusts_one_subject" {
  command = apply

  assert {
    condition     = length([for condition in one(data.aws_iam_policy_document.github_trust.statement).condition : condition if condition.variable == "token.actions.githubusercontent.com:sub"]) == 1
    error_message = "One condition on the subject."
  }
  assert {
    condition     = one([for condition in one(data.aws_iam_policy_document.github_trust.statement).condition : condition.test if condition.variable == "token.actions.githubusercontent.com:sub"]) == "StringEquals"
    error_message = "The subject is matched exactly: a StringLike would let a pattern in."
  }
  assert {
    condition     = join(",", one([for condition in one(data.aws_iam_policy_document.github_trust.statement).condition : tolist(condition.values) if condition.variable == "token.actions.githubusercontent.com:sub"])) == "repo:owner/repo:environment:prod"
    error_message = "Without a prefix the subject is the repository's name, in this environment's GitHub Environment, and nothing else (not the main branch on its own)."
  }
  assert {
    condition     = one([for condition in one(data.aws_iam_policy_document.github_trust.statement).condition : tolist(condition.values) if condition.variable == "token.actions.githubusercontent.com:aud"])[0] == "sts.amazonaws.com"
    error_message = "The audience is still checked."
  }
}

run "github_deploy_role_follows_the_ids_when_github_uses_them" {
  command = apply

  variables {
    environment                = "dev"
    github_oidc_subject_prefix = "repo:owner@22373811/repo@1436955495"
  }

  assert {
    condition     = join(",", one([for condition in one(data.aws_iam_policy_document.github_trust.statement).condition : tolist(condition.values) if condition.variable == "token.actions.githubusercontent.com:sub"])) == "repo:owner@22373811/repo@1436955495:environment:dev"
    error_message = "A repository whose tokens carry the owner's and its own IDs is trusted by those IDs, so a re-registered name inherits nothing."
  }
}

run "github_subject_prefix_cannot_carry_a_pattern" {
  command = plan

  variables {
    github_oidc_subject_prefix = "repo:owner/*"
  }

  expect_failures = [var.github_oidc_subject_prefix]
}
