# GitHub Actions authenticates to AWS with short-lived OIDC tokens: no access keys are stored in GitHub.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  github_oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"

  # The one subject the deploy role trusts: this repository (by ID where GitHub uses IDs), running as this GitHub Environment.
  github_subject = "${coalesce(var.github_oidc_subject_prefix, "repo:${var.github_repository}")}:environment:${var.environment}"
}

data "aws_iam_policy_document" "github_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Only a run that deploys to this environment's GitHub Environment may push images, and the Environment is where the branch rule (main) and the
    # approvals live. Not "any run on main": a workflow with no Environment has none of those, and no wildcard (StringEquals) so that nothing but this
    # exact subject matches. AWS evaluates only aud and sub, so this is the whole of what the trust can say; who may start the run is decided in GitHub
    # (docs/aws/one-click.md, ADR 72).
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_subject]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  count = local.is_secondary ? 0 : 1 # the standby's images arrive by ECR replication; CI only pushes to the primary's registry

  name               = "${local.name}-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_trust.json
}

data "aws_iam_policy_document" "github_deploy" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload", "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart"
    ]
    resources = ["arn:${data.aws_partition.current.partition}:ecr:${var.region}:${local.account_id}:repository/task-api/*"]
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  count = local.is_secondary ? 0 : 1

  name   = "push-images"
  role   = aws_iam_role.github_deploy[0].id
  policy = data.aws_iam_policy_document.github_deploy.json
}
