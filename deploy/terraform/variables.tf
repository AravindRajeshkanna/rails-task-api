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

# --- Multi-region (docs/aws/multi-region.md) ---
variable "dr_role" {
  description = "How this stack takes part in a two-region pair. none: a single region (the default; nothing below applies). primary: the active region, which replicates its data to the standby. secondary: the warm standby in another region, built from this same code in its own state. It describes how the stack was built, not which side is serving traffic after a failover."
  type        = string
  default     = "none"
  validation {
    condition     = contains(["none", "primary", "secondary"], var.dr_role)
    error_message = "dr_role must be none, primary or secondary."
  }
}

variable "peer_region" {
  description = "The other region of the pair: the standby's for a primary, the primary's for a secondary. Required unless dr_role is none."
  type        = string
  default     = ""
  validation {
    condition     = var.dr_role == "none" || (var.peer_region != "" && var.peer_region != var.region)
    error_message = "When dr_role is primary or secondary, peer_region must name a region other than this stack's own."
  }
}

variable "peer_ready" {
  description = "Set true once the OTHER stack exists. For the primary: the standby's bucket and load balancer exist, which turns on S3 replication to it and the DNS failover records. For the standby: the primary's bucket exists, which turns on replication back for failback. Leave false on the first apply."
  type        = bool
  default     = false
}

variable "db_engine_version" {
  description = "Pin the Aurora PostgreSQL version (for example 17.5). Empty takes the latest 17.x, which is right for a single region. The members of a global database must match, so set the standby to the primary's (terraform output database_engine_version)."
  type        = string
  default     = ""
}

variable "dr_s3_replication_time_control" {
  description = "S3 Replication Time Control: replicates 99.99% of objects within 15 minutes, with metrics and an SLA, for an extra per-GB fee. False replicates on a best-effort basis (usually seconds, no guarantee)."
  type        = bool
  default     = true
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

# --- Backups: a copy in another region (docs/runbooks/backup-and-restore.md) ---
variable "backup_copy_region" {
  description = "Region that receives a daily copy of the database's snapshots (AWS Backup) and of the pg_dump bucket. Empty (the default) creates neither. It is independent of dr_role, and usually the region a standby would live in."
  type        = string
  default     = ""
  validation {
    condition     = var.backup_copy_region != var.region
    error_message = "backup_copy_region must be a different region from this stack's own; a copy next to the original protects against less."
  }
}

variable "backup_schedule" {
  description = "When AWS Backup snapshots the database (an EventBridge cron expression, UTC). This, not the Aurora point-in-time window, is the recovery point of the copy in the other region."
  type        = string
  default     = "cron(0 3 * * ? *)"
}

variable "backup_retention_days" {
  description = "How long snapshots stay in this region's vault, and, separately, in the other region's."
  type        = number
  default     = 35
}

variable "dump_retention_days" {
  description = "How long pg_dump files are kept in the dump bucket (and its copy). Older versions of an overwritten file go after 30 days."
  type        = number
  default     = 90
}


# --- Encryption keys (KMS): docs/aws/kms.md ---
variable "data_key_generations" {
  description = "Generations of the application's data key (the one that protects the keys of encrypted database columns). Normally [1]. A manual rotation adds the next number: new values are made under the newest key straight away, the older ones stay allowed to Decrypt until `bin/rails kms:status` shows that no value refers to them, and only then is the old number removed (which schedules that key's deletion). Set the same list in both regions of a pair. Routine yearly rotation needs none of this: it is on, and AWS does it."
  type        = list(number)
  default     = [1]
  validation {
    condition     = length(var.data_key_generations) > 0 && length(distinct(var.data_key_generations)) == length(var.data_key_generations) && alltrue([for generation in var.data_key_generations : generation >= 1 && floor(generation) == generation])
    error_message = "data_key_generations must be a non-empty list of distinct whole numbers from 1 up."
  }
}

variable "storage_kms_encryption" {
  description = "Encrypt the Active Storage bucket with a customer-managed key (SSE-KMS) instead of the S3-managed one. Needs the same setting in both regions of a pair. Objects written before it was turned on stay under the old encryption until they are copied over themselves."
  type        = bool
  default     = true
}

variable "secrets_kms_encryption" {
  description = "Encrypt Secrets Manager's secrets with a customer-managed key. A standby region's replicas stay under that region's AWS-managed key."
  type        = bool
  default     = true
}

variable "enable_kms_audit" {
  description = "A CloudTrail trail for KMS events only (who generated and decrypted keys, who changed a key), kept in S3 and CloudWatch Logs, with alarms on decrypt volume, refusals and key changes. Set false where the account already has a trail that records KMS events: a second copy of management events is billed."
  type        = bool
  default     = true
}

variable "kms_decrypt_alarm_threshold" {
  description = "Decrypt requests from the application in five minutes above which the unusual-volume alarm fires. CHOSEN, NOT MEASURED: the application caches unwrapped keys, so steady state is a few requests per webhook per pod per five minutes. Read the TaskApi/KMS DecryptRequests metric for a few weeks, then set it to a multiple of the busiest ordinary window."
  type        = number
  default     = 2000
}

variable "kms_audit_retention_days" {
  description = "How long CloudTrail's log files for KMS events stay in S3 (CloudWatch Logs keeps 90 days)."
  type        = number
  default     = 365
}
