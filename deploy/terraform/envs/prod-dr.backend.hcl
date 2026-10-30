# terraform init -backend-config=envs/prod-dr.backend.hcl
#
# The standby's state lives in a bucket in the STANDBY's region. If it were in the primary's region, the one outage this
# stack exists for would also take away the state you need to operate it.
bucket       = "task-api-tfstate-dr-REPLACE_WITH_ACCOUNT_ID"
key          = "prod-dr/terraform.tfstate"
region       = "us-west-2"
encrypt      = true
use_lockfile = true # S3 native locking, no DynamoDB table needed
