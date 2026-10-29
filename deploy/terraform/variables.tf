variable "environment" {
  description = "dev, staging or prod. Each environment is a separate state and, ideally, a separate AWS account."
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

# --- DNS and TLS ---
variable "root_domain" {
  description = "A Route 53 public hosted zone you already own, e.g. example.com."
  type        = string
}

variable "api_subdomain" {
  description = "Host for the API, relative to root_domain, e.g. api.dev (-> api.dev.example.com)."
  type        = string
}

variable "frontend_subdomain" {
  description = "Host of the web client (used for CORS and links in emails)."
  type        = string
}

variable "alb_exists" {
  description = "Set true after the first deploy. The ALB is created by the AWS Load Balancer Controller when the Ingress syncs, not by Terraform; once it exists this adds the Route 53 alias and the load balancer alarms."
  type        = bool
  default     = false
}

# --- Network and cluster ---
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "az_count" {
  type    = number
  default = 3
}

variable "single_nat_gateway" {
  description = "One NAT gateway for the whole VPC (cheaper, no AZ redundancy). True for dev, false for prod."
  type        = bool
  default     = true
}

variable "kubernetes_version" {
  type    = string
  default = "1.33"
}

variable "cluster_admin_arns" {
  description = "IAM principals (roles or users) that get cluster-admin through EKS access entries."
  type        = list(string)
  default     = []
}

variable "api_public_access_cidrs" {
  description = "CIDRs allowed to reach the Kubernetes API endpoint from the internet. Narrow this to your office/VPN."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "system_node_instance_types" {
  description = "The small on-demand node group that runs Karpenter and cluster add-ons. Everything else runs on nodes Karpenter creates."
  type        = list(string)
  default     = ["m7g.large"]
}

# --- Database ---
variable "db_min_acu" {
  type    = number
  default = 0.5
}

variable "db_max_acu" {
  type    = number
  default = 4
}

variable "db_instance_count" {
  description = "Aurora instances (1 writer plus readers). Use at least 2 in prod for failover."
  type        = number
  default     = 1
}

variable "db_deletion_protection" {
  type    = bool
  default = false
}

# --- AI ---
variable "bedrock_model_id" {
  description = "Bedrock model or inference profile id for generation (list with: aws bedrock list-inference-profiles). The ai service calls it."
  type        = string
}

variable "bedrock_embedding_model_id" {
  type    = string
  default = "amazon.titan-embed-text-v2:0"
}

# --- Alerting ---
variable "alert_emails" {
  type    = list(string)
  default = []
}

variable "pagerduty_https_endpoint" {
  description = "PagerDuty Events API v2 'Amazon CloudWatch' integration URL (https://events.pagerduty.com/integration/<key>/enqueue). Empty = no PagerDuty."
  type        = string
  default     = ""
  sensitive   = true
}

variable "slack_workspace_id" {
  description = "Slack workspace id, after authorizing AWS Chatbot once in the console. Empty = no Slack."
  type        = string
  default     = ""
}

variable "slack_channel_id" {
  type    = string
  default = ""
}

variable "queue_depth_alarm_threshold" {
  type    = number
  default = 500
}

variable "enable_aiops_automation" {
  description = "Deploy the Phase 6 Lambdas (root-cause analysis with Bedrock, auto-remediation) and wire them to the alarms."
  type        = bool
  default     = true
}

variable "remediation_dry_run" {
  description = "When true, the remediation Lambda only reports what it would do. Start here."
  type        = bool
  default     = true
}

variable "enable_fis" {
  description = "Create AWS Fault Injection Service experiment templates (chaos engineering). Nothing runs until you start an experiment."
  type        = bool
  default     = false
}

# --- CI/CD ---
variable "create_ecr" {
  description = "Create the container repositories. In a single account shared by several environments, only one of them should."
  type        = bool
  default     = true
}

variable "create_github_oidc_provider" {
  description = "Create the account's GitHub Actions OIDC provider (one per account; set false if it already exists)."
  type        = bool
  default     = true
}

variable "github_repository" {
  description = "owner/name of the repository whose GitHub Actions may push images (OIDC, no stored keys)."
  type        = string
}

variable "monthly_budget_usd" {
  description = "Alerts at 80% forecast and 100% actual. 0 = no budget."
  type        = number
  default     = 0
}
