# Secrets Manager holds everything sensitive; External Secrets Operator syncs it into the cluster. Terraform
# generates the values nobody needs to choose (passwords, signing keys). Values you must supply are created as
# placeholders and ignored afterwards, so `terraform apply` never overwrites what you put there.
#
# A standby region (dr_role = secondary) creates none of this: its secrets are replicas of the primary's, made by the primary's
# stack (the `replica` blocks below), and nothing sensitive is generated or stored in the standby's state.

locals {
  create_secrets = !local.is_secondary
}

resource "random_password" "api_database" {
  count = local.create_secrets ? 1 : 0

  length  = 32
  special = false
}

resource "random_password" "auth_database" {
  count = local.create_secrets ? 1 : 0

  length  = 32
  special = false
}

resource "random_password" "notifications_database" {
  count = local.create_secrets ? 1 : 0

  length  = 32
  special = false
}

resource "random_password" "metrics_token" {
  count = local.create_secrets ? 1 : 0

  length  = 40
  special = false
}

resource "random_password" "ai_service_token" {
  count = local.create_secrets ? 1 : 0

  length  = 48
  special = false
}

resource "random_password" "secret_key_base" {
  for_each = local.create_secrets ? toset(["auth", "ai", "notifications"]) : toset([])
  length   = 128
  special  = false
}

# The Auth service's RS256 signing key. It lives in Terraform state (keep that bucket private and encrypted).
# Rotate by putting a new value in the secret and listing the old public key in AUTH_JWT_PREVIOUS_PUBLIC_KEYS.
resource "tls_private_key" "auth_jwt" {
  count     = local.create_secrets ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 3072
}

locals {
  secrets = local.is_secondary ? {} : {
    api = {
      rails_master_key  = "REPLACE_ME" # cat config/master.key; see docs/aws/setup-guide.md
      database_password = random_password.api_database[0].result
      metrics_token     = random_password.metrics_token[0].result
    }
    auth = {
      secret_key_base   = random_password.secret_key_base["auth"].result
      database_password = random_password.auth_database[0].result
      jwt_private_key   = base64encode(tls_private_key.auth_jwt[0].private_key_pem)
    }
    ai = {
      secret_key_base = random_password.secret_key_base["ai"].result
    }
    notifications = {
      secret_key_base   = random_password.secret_key_base["notifications"].result
      database_password = random_password.notifications_database[0].result
      smtp_username     = aws_iam_access_key.ses_smtp[0].id
      smtp_password     = aws_iam_access_key.ses_smtp[0].ses_smtp_password_v4
      slack_webhook_url = "" # optional: https://hooks.slack.com/services/...
    }
  }
}

resource "aws_secretsmanager_secret" "service" {
  for_each = local.secrets

  name                    = "${local.secret_prefix}/${each.key}"
  recovery_window_in_days = local.is_prod ? 30 : 0

  # Multi-region: a read-only copy in the standby's region, kept in step by Secrets Manager. The standby's External
  # Secrets reads it under the same name. To write to it after the primary region is lost, promote it first
  # (docs/runbooks/regional-failover.md).
  dynamic "replica" {
    for_each = local.is_primary ? [var.peer_region] : []
    content {
      region = replica.value
    }
  }
}

resource "aws_secretsmanager_secret_version" "service" {
  for_each      = local.secrets
  secret_id     = aws_secretsmanager_secret.service[each.key].id
  secret_string = jsonencode(each.value)

  # Values entered by hand (the Rails master key, the Slack URL) and rotated values survive later applies.
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# One token shared by the API/worker (callers) and the AI service (verifier).
resource "aws_secretsmanager_secret" "ai_service_token" {
  count = local.create_secrets ? 1 : 0

  name                    = "${local.secret_prefix}/ai-service-token"
  recovery_window_in_days = local.is_prod ? 30 : 0

  dynamic "replica" {
    for_each = local.is_primary ? [var.peer_region] : []
    content {
      region = replica.value
    }
  }
}

resource "aws_secretsmanager_secret_version" "ai_service_token" {
  count = local.create_secrets ? 1 : 0

  secret_id     = aws_secretsmanager_secret.ai_service_token[0].id
  secret_string = random_password.ai_service_token[0].result

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# SMTP credentials for Amazon SES, derived from a dedicated IAM user that may only send mail.
resource "aws_iam_user" "ses_smtp" {
  count = local.create_secrets ? 1 : 0

  name = "${local.name}-ses-smtp"
}

data "aws_iam_policy_document" "ses_send" {
  statement {
    actions   = ["ses:SendRawEmail"]
    resources = ["*"]
  }
}

resource "aws_iam_user_policy" "ses_smtp" {
  count = local.create_secrets ? 1 : 0

  name   = "send-email"
  user   = aws_iam_user.ses_smtp[0].name
  policy = data.aws_iam_policy_document.ses_send.json
}

resource "aws_iam_access_key" "ses_smtp" {
  count = local.create_secrets ? 1 : 0

  user = aws_iam_user.ses_smtp[0].name
}
