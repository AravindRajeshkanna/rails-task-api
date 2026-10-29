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
