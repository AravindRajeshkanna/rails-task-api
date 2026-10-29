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

  policy = jsonencode({
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
