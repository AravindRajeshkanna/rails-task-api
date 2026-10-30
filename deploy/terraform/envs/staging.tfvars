environment        = "staging"
region             = "us-east-1"
root_domain        = "example.com"
api_subdomain      = "api.staging"
frontend_subdomain = "app.staging"

github_repository = "AravindRajeshkanna/rails-task-api"
bedrock_model_id  = "REPLACE_WITH_BEDROCK_INFERENCE_PROFILE_ID"

single_nat_gateway = true
db_max_acu         = 8
db_instance_count  = 2
create_ecr         = false # shares the dev account's repositories; remove this line if staging is its own account
alert_emails       = []

# --- A standby to rehearse a failover on (docs/runbooks/failover-drill.md): uncomment in this order ---
# 1. dr_role = "primary", peer_region = "us-west-2"          apply: joins the database to a global cluster, replicates secrets and images
# 2. build the standby (envs/staging-dr.tfvars) and let its load balancer appear
# 3. peer_ready = true                                       apply: S3 replication and the DNS failover records
# dr_role     = "primary"
# peer_region = "us-west-2"
# peer_ready  = false
