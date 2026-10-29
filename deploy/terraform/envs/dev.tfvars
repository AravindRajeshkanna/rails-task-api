environment        = "dev"
region             = "us-east-1"
root_domain        = "example.com" # a Route 53 public hosted zone you own
api_subdomain      = "api.dev"
frontend_subdomain = "app.dev"

github_repository = "AravindRajeshkanna/rails-task-api"
bedrock_model_id  = "REPLACE_WITH_BEDROCK_INFERENCE_PROFILE_ID" # aws bedrock list-inference-profiles

single_nat_gateway = true
db_max_acu         = 4
alert_emails       = []
