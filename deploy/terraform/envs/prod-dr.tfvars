# The warm standby of prod in a second region: the same Terraform, its own state, dr_role = "secondary".
# Read docs/aws/multi-region.md first; the order of operations is in its "Building it" section. NOTHING in this file has been applied.
#
#   terraform init -backend-config=envs/prod-dr.backend.hcl
#   terraform apply -var-file=envs/prod-dr.tfvars
#
# It must agree with prod.tfvars on environment, root_domain, api_subdomain and frontend_subdomain: the standby answers to the same name.
environment        = "prod"
region             = "us-west-2"
root_domain        = "example.com"
api_subdomain      = "api"
frontend_subdomain = "app"

dr_role     = "secondary"
peer_region = "us-east-1" # the primary's region
# The primary exists first, so the standby can replicate back to it from the start (that is what makes failback a switchover).
peer_ready = true
# Must equal the primary's:  cd deploy/terraform && terraform output -raw database_engine_version   (with the prod state)
db_engine_version = "REPLACE_WITH_PRIMARY_ENGINE_VERSION"

github_repository = "AravindRajeshkanna/rails-task-api"
# Inference profile ids differ by region: aws bedrock list-inference-profiles --region us-west-2 (and request model access there).
bedrock_model_id = "REPLACE_WITH_BEDROCK_INFERENCE_PROFILE_ID_IN_THIS_REGION"

# What the primary already owns in this account.
create_ecr                  = false # images arrive by ECR replication; repositories are created by it
create_github_oidc_provider = false # one per account

# Must not overlap the primary's 10.0.0.0/16 if the two are ever peered.
vpc_cidr = "10.1.0.0/16"

# Sized to hold a standby, not to carry production; at a failover ramp it up (docs/runbooks/regional-failover.md).
single_nat_gateway      = false # one per AZ, like prod: after promotion this is production. true saves ~$65 a month per extra gateway while it is only a standby
db_min_acu              = 2     # high enough to apply the replication stream from a busy primary
db_max_acu              = 32    # the same ceiling as prod: Serverless v2 scales to it once this cluster is promoted
db_instance_count       = 1     # a secondary needs one instance, which becomes the writer on promotion; add a reader afterwards
db_deletion_protection  = true
api_public_access_cidrs = ["203.0.113.0/24"]
alert_emails            = ["oncall@example.com"]

# The pager and the budget are the primary's; a second set would only double the noise.
monthly_budget_usd      = 0
enable_aiops_automation = false
remediation_dry_run     = true
