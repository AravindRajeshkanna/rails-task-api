# terraform init -backend-config=envs/staging-dr.backend.hcl
#
# In a bucket in the STANDBY's region, like prod-dr: state held only in the failed region cannot be used to operate the standby.
bucket       = "task-api-tfstate-dr-REPLACE_WITH_ACCOUNT_ID"
key          = "staging-dr/terraform.tfstate"
region       = "us-west-2"
encrypt      = true
use_lockfile = true # S3 native locking, no DynamoDB table needed
