terraform {
  required_version = ">= 1.10"

  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 6.0" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
    tls     = { source = "hashicorp/tls", version = "~> 4.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.7" }
  }

  # Remote state with S3 native locking. Create the bucket once (docs/aws/setup-guide.md, step 2), then:
  #   terraform init -backend-config=envs/dev.backend.hcl
  backend "s3" {}
}
