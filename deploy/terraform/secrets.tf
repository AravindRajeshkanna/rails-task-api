# Secrets Manager holds everything sensitive; External Secrets Operator syncs it into the cluster. Terraform
# generates the values nobody needs to choose (passwords, signing keys). Values you must supply are created as
# placeholders and ignored afterwards, so `terraform apply` never overwrites what you put there.

resource "random_password" "api_database" {
  length  = 32
  special = false
}

resource "random_password" "auth_database" {
  length  = 32
  special = false
}

resource "random_password" "notifications_database" {
  length  = 32
  special = false
}

resource "random_password" "metrics_token" {
  length  = 40
  special = false
}

resource "random_password" "ai_service_token" {
  length  = 48
  special = false
}

resource "random_password" "secret_key_base" {
  for_each = toset(["auth", "ai", "notifications"])
  length   = 128
  special  = false
}

# The Auth service's RS256 signing key. It lives in Terraform state (keep that bucket private and encrypted).
# Rotate by putting a new value in the secret and listing the old public key in AUTH_JWT_PREVIOUS_PUBLIC_KEYS.
resource "tls_private_key" "auth_jwt" {
  algorithm = "RSA"
  rsa_bits  = 3072
}

locals {
  secrets = {
    api = {
      rails_master_key  = "REPLACE_ME" # cat config/master.key; see docs/aws/setup-guide.md
      database_password = random_password.api_database.result
      metrics_token     = random_password.metrics_token.result
    }
    auth = {
      secret_key_base   = random_password.secret_key_base["auth"].result
      database_password = random_password.auth_database.result
      jwt_private_key   = base64encode(tls_private_key.auth_jwt.private_key_pem)
    }
    ai = {
      secret_key_base = random_password.secret_key_base["ai"].result
    }
    notifications = {
      secret_key_base   = random_password.secret_key_base["notifications"].result
      database_password = random_password.notifications_database.result
      smtp_username     = aws_iam_access_key.ses_smtp.id
      smtp_password     = aws_iam_access_key.ses_smtp.ses_smtp_password_v4
      slack_webhook_url = "" # optional: https://hooks.slack.com/services/...
    }
  }
}

resource "aws_secretsmanager_secret" "service" {
  for_each = local.secrets

  name                    = "${local.secret_prefix}/${each.key}"
  recovery_window_in_days = local.is_prod ? 30 : 0
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
  name                    = "${local.secret_prefix}/ai-service-token"
  recovery_window_in_days = local.is_prod ? 30 : 0
}

resource "aws_secretsmanager_secret_version" "ai_service_token" {
  secret_id     = aws_secretsmanager_secret.ai_service_token.id
  secret_string = random_password.ai_service_token.result

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# SMTP credentials for Amazon SES, derived from a dedicated IAM user that may only send mail.
resource "aws_iam_user" "ses_smtp" {
  name = "${local.name}-ses-smtp"
}

data "aws_iam_policy_document" "ses_send" {
  statement {
    actions   = ["ses:SendRawEmail"]
    resources = ["*"]
  }
}

resource "aws_iam_user_policy" "ses_smtp" {
  name   = "send-email"
  user   = aws_iam_user.ses_smtp.name
  policy = data.aws_iam_policy_document.ses_send.json
}

resource "aws_iam_access_key" "ses_smtp" {
  user = aws_iam_user.ses_smtp.name
}
