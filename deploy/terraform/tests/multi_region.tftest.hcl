# Offline checks of the multi-region wiring and of the cross-region backup copy: the plan for each role is computed against mocked AWS providers, so no
# credentials are used and nothing is created. They prove the conditional logic (what each role creates and names), not
# that AWS accepts it: that needs a real account (docs/aws/multi-region.md).
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
}

mock_provider "aws" {
  alias = "peer"
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
    condition     = length(aws_route53_health_check.api) == 1 && aws_route53_health_check.api[0].resource_path == "/up" && aws_route53_health_check.api[0].failure_threshold == 3
    error_message = "The primary load balancer is health checked on /up."
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

