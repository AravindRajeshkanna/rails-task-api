# These feed deploy/scripts/render_gitops.rb:  terraform output -json > ../../tmp/<env>-outputs.json

output "region" { value = var.region }
output "cluster_name" { value = module.eks.cluster_name }
output "ecr_registry" { value = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com" }
output "api_domain" { value = local.api_domain }
output "frontend_domain" { value = local.frontend_domain }
output "vpc_cidr" { value = module.vpc.vpc_cidr_block }
output "vpc_id" { value = module.vpc.vpc_id }
output "database_endpoint" { value = module.db.cluster_endpoint }
output "database_reader_endpoint" { value = module.db.cluster_reader_endpoint }                               # load-balances over the readers; with one instance it is the writer, which is harmless (ReplicaRouting)
output "database_master_secret_arn" { value = try(module.db.cluster_master_user_secret[0].secret_arn, null) } # none on a standby: it replicates the primary's users
output "events_topic_arn" { value = aws_sns_topic.events.arn }
output "notifications_queue_url" { value = aws_sqs_queue.notifications.url }
output "notifications_dlq_url" { value = aws_sqs_queue.notifications_dlq.url }
output "certificate_arn" { value = aws_acm_certificate_validation.api.certificate_arn }
output "waf_acl_arn" { value = aws_wafv2_web_acl.api.arn }
output "storage_bucket" { value = aws_s3_bucket.storage.bucket }
output "bedrock_model_id" { value = var.bedrock_model_id }
output "bedrock_embedding_model_id" { value = var.bedrock_embedding_model_id }
output "github_deploy_role_arn" { value = try(aws_iam_role.github_deploy[0].arn, null) }
output "karpenter_node_role_name" { value = module.karpenter.node_iam_role_name }
output "karpenter_interruption_queue" { value = module.karpenter.queue_name }
output "alerts_topic_arn" { value = aws_sns_topic.alerts.arn }
output "alb_name" { value = local.alb_name }

output "service_account_roles" {
  description = "Pod Identity roles by service account (informational)"
  value       = { for name, identity in module.workload_identity : name => identity.iam_role_arn }
}

output "aiops_rca_function" { value = try(aws_lambda_function.rca[0].function_name, null) }
output "aiops_remediate_function" { value = try(aws_lambda_function.remediate[0].function_name, null) }
output "remediation_dry_run" { value = var.remediation_dry_run }

# Multi-region (docs/aws/multi-region.md)
output "app_env" {
  description = "The GitOps environment name for this stack (deploy/gitops/envs/<app_env>): the environment, plus -dr on a standby"
  value       = local.app_env
}
output "dr_role" { value = var.dr_role }
output "database_engine_version" {
  description = "Put this in the standby's db_engine_version: a global database's members must match"
  value       = module.db.cluster_engine_version_actual
}
output "database_global_cluster_id" { value = try(aws_rds_global_cluster.this[0].id, null) }
output "peer_storage_bucket" {
  description = "The other region's bucket this stack replicates to"
  value       = local.dr_enabled ? "${local.peer_name}-storage-${local.account_id}" : null
}

# Cross-region backups (null unless backup_copy_region is set; docs/runbooks/backup-and-restore.md)
output "backup_vault_name" { value = try(aws_backup_vault.local[0].name, null) }
output "backup_copy_vault_arn" { value = try(aws_backup_vault.copy[0].arn, null) }
output "dump_bucket" { value = try(aws_s3_bucket.dumps[0].bucket, null) }
output "dump_copy_bucket" { value = try(aws_s3_bucket.dumps_copy[0].bucket, null) }
output "dump_upload_policy_arn" { value = try(aws_iam_policy.dump_upload[0].arn, null) }

