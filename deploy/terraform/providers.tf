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

# The other region of a multi-region pair (docs/aws/multi-region.md). With dr_role = none it is the same region and
# nothing uses it.
provider "aws" {
  alias  = "peer"
  region = var.peer_region != "" ? var.peer_region : var.region

  default_tags {
    tags = {
      Project     = "task-api"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# Where the cross-region backup copy lives (backup_copy_region). With it empty it is the same region and nothing uses it.
provider "aws" {
  alias  = "backup_copy"
  region = var.backup_copy_region != "" ? var.backup_copy_region : var.region

  default_tags {
    tags = {
      Project     = "task-api"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

