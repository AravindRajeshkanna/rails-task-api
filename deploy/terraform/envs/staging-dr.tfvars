# The standby of staging in a second region, to rehearse a failover on before production ever needs one (docs/runbooks/failover-drill.md):
# the same Terraform, its own state, dr_role = "secondary". NOTHING in this file has been applied.
#
#   terraform init -backend-config=envs/staging-dr.backend.hcl
#   terraform apply -var-file=envs/staging-dr.tfvars
#
# Apply staging first with dr_role = "primary" and peer_region (see the commented lines in staging.tfvars), then this, then peer_ready = true on staging.
# It must agree with staging.tfvars on environment, root_domain, api_subdomain and frontend_subdomain: the standby answers to the same name.
environment        = "staging"
region             = "us-west-2"
root_domain        = "example.com"
api_subdomain      = "api.staging"
frontend_subdomain = "app.staging"

dr_role     = "secondary"
peer_region = "us-east-1" # staging's region
peer_ready  = true
# Must equal staging's:  cd deploy/terraform && terraform output -raw database_engine_version   (with the staging state)
db_engine_version = "REPLACE_WITH_STAGING_ENGINE_VERSION"

github_repository = "AravindRajeshkanna/rails-task-api"
bedrock_model_id  = "REPLACE_WITH_BEDROCK_INFERENCE_PROFILE_ID_IN_THIS_REGION"

# What staging already owns in this account.
create_ecr                  = false
create_github_oidc_provider = false

vpc_cidr = "10.1.0.0/16" # must not overlap staging's 10.0.0.0/16

# As small as it can be: it only has to take a failover drill, not traffic.
single_nat_gateway      = true
db_min_acu              = 1
db_max_acu              = 8
db_instance_count       = 1
api_public_access_cidrs = ["203.0.113.0/24"]
alert_emails            = []

monthly_budget_usd      = 0
enable_aiops_automation = false
remediation_dry_run     = true
