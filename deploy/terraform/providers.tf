provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "task-api"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
