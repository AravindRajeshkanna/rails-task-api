data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name       = "task-api-${var.environment}"
  account_id = data.aws_caller_identity.current.account_id
  azs        = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  is_prod    = var.environment == "prod"

  alb_name        = local.name # the Ingress sets alb.ingress.kubernetes.io/load-balancer-name to this
  api_domain      = "${var.api_subdomain}.${var.root_domain}"
  frontend_domain = "${var.frontend_subdomain}.${var.root_domain}"

  namespace = "task-api"
  services  = ["api", "auth", "ai", "notifications"]

  # Kubernetes ServiceAccounts (= Helm release names) that get AWS access through EKS Pod Identity.
  secret_prefix = "task-api/${var.environment}"
}
