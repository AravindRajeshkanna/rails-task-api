locals {
  ecr_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after a week"
        selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 7 }
        action       = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the 50 most recent images"
        selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 50 }
        action       = { type = "expire" }
      }
    ]
  })
}

resource "aws_ecr_repository" "service" {
  for_each = var.create_ecr ? toset(local.services) : toset([])

  name                 = "task-api/${each.key}"
  image_tag_mutability = "IMMUTABLE" # a tag is a git SHA; it must never be repointed
  force_delete         = !local.is_prod

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "service" {
  for_each   = aws_ecr_repository.service
  repository = each.value.name

  policy = local.ecr_lifecycle_policy
}

# --- Multi-region (docs/aws/multi-region.md) ---
# The primary pushes every image to its own registry; ECR copies each one to the standby's region as it arrives. Images
# pushed before this exists are not copied: re-push them, or run a one-off copy for the tags a deployment needs.
resource "aws_ecr_replication_configuration" "to_standby" {
  count = local.is_primary ? 1 : 0

  replication_configuration {
    rule {
      destination {
        region      = var.peer_region
        registry_id = local.account_id
      }
      repository_filter {
        filter      = "task-api/"
        filter_type = "PREFIX_MATCH"
      }
    }
  }
}

# Replication creates the repositories in the standby's registry by itself. This gives them the same rules as the primary's
# (immutable tags, the same lifecycle) instead of ECR's defaults. Scan-on-push is not part of a creation template; turn on
# registry scanning in this region if the standby's images should be scanned too.
resource "aws_ecr_repository_creation_template" "replicated" {
  count = local.is_secondary ? 1 : 0

  prefix               = "task-api"
  description          = "Repositories created by replication from the primary region"
  applied_for          = ["REPLICATION"]
  image_tag_mutability = "IMMUTABLE"
  lifecycle_policy     = local.ecr_lifecycle_policy

  encryption_configuration {
    encryption_type = "AES256"
  }
}
