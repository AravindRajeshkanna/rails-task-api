environment        = "prod"
region             = "us-east-1"
root_domain        = "example.com"
api_subdomain      = "api"
frontend_subdomain = "app"

github_repository = "AravindRajeshkanna/rails-task-api"
bedrock_model_id  = "REPLACE_WITH_BEDROCK_INFERENCE_PROFILE_ID"

single_nat_gateway      = false # one NAT gateway per availability zone
db_min_acu              = 1
db_max_acu              = 32
db_instance_count       = 2
db_deletion_protection  = true
api_public_access_cidrs = ["203.0.113.0/24"] # your VPN / office: the Kubernetes API is not for the internet
alert_emails            = ["oncall@example.com"]
monthly_budget_usd      = 2000
remediation_dry_run     = true
