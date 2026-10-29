# terraform init -backend-config=envs/staging.backend.hcl
bucket       = "task-api-tfstate-REPLACE_WITH_ACCOUNT_ID"
key          = "staging/terraform.tfstate"
region       = "us-east-1"
encrypt      = true
use_lockfile = true # S3 native locking, no DynamoDB table needed
