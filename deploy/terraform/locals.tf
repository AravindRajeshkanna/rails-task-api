data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Multi-region (docs/aws/multi-region.md). The standby is the same code in another region and its own state, with "-dr"
  # added to every name so the account-global ones (IAM roles, the SES user) cannot collide with the primary's.
  is_secondary = var.dr_role == "secondary"
  is_primary   = var.dr_role == "primary"
  dr_enabled   = var.dr_role != "none"
  app_env      = "${var.environment}${local.is_secondary ? "-dr" : ""}" # the GitOps environment (deploy/gitops/envs/<app_env>) and the CloudWatch Environment dimension
  peer_app_env = local.is_secondary ? var.environment : "${var.environment}-dr"
  peer_name    = "task-api-${local.peer_app_env}"
  replicate    = local.dr_enabled && var.peer_ready # data flows to the peer: S3 now, DNS failover (primary only) too
  failover     = local.is_primary && var.peer_ready && var.alb_exists

  global_cluster_id = "task-api-${var.environment}-global"

  name       = "task-api-${local.app_env}"
  account_id = data.aws_caller_identity.current.account_id
  azs        = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  is_prod    = var.environment == "prod"

  alb_name        = local.name # the Ingress sets alb.ingress.kubernetes.io/load-balancer-name to this
  api_domain      = "${var.api_subdomain}.${var.root_domain}"
  frontend_domain = "${var.frontend_subdomain}.${var.root_domain}"

  namespace = "task-api"
  services  = ["api", "auth", "ai", "notifications"]

  # Kubernetes ServiceAccounts (= Helm release names) that get AWS access through EKS Pod Identity.
  secret_prefix = "task-api/${var.environment}" # the same in both regions: the standby reads replicas of the primary's secrets
}
