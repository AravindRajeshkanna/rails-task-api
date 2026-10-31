# Customer-managed KMS keys (docs/aws/kms.md, ADR 69 and 70). One key per purpose, so that what may use one cannot use another:
#
#   data      protects the data keys of encrypted database columns (gems/kms_encryption). Used by the api and worker. A multi-Region key: the standby
#             reads the same database, so it must be able to unwrap what the primary wrapped.
#   storage   Active Storage's bucket (SSE-KMS). Used by S3 on behalf of the api and worker.
#   secrets   Secrets Manager. Used by External Secrets.
#
# Every key rotates its material yearly (AWS does it; wrapped data keys made earlier still unwrap). The key policies delegate to IAM, so access is
# granted in IAM and visible there (pod_identity.tf), and the data key adds a guard no IAM policy can lift: a request without the application's
# encryption context is refused, for everyone.

locals {
  kms_app_context    = "task-api" # the encryption context of every request the application makes: KmsEncryption::Configuration#base_context
  data_generations   = toset([for generation in var.data_key_generations : tostring(generation)])
  current_generation = tostring(max(var.data_key_generations...))
  data_alias         = "alias/task-api-${var.environment}-data" # the same name in both regions of a pair: it is what the application is configured with
  key_deletion_days  = local.is_prod ? 30 : 7
}

data "aws_iam_policy_document" "kms_account" {
  statement {
    sid       = "AccountAdministers"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${local.account_id}:root"]
    }
  }
}

data "aws_iam_policy_document" "data_key" {
  source_policy_documents = [data.aws_iam_policy_document.kms_account.json]

  # Cryptographic use needs the application's encryption context, from anyone: a role that can reach the key but does not say who it is calling for
  # (a stolen credential trying the key, a console session) is refused, and every allowed request is attributable in CloudTrail. The context is not a
  # secret; it is the label. An administrator who must decrypt something by hand supplies it too (the runbook says how).
  statement {
    sid       = "RequireTheApplicationContext"
    effect    = "Deny"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "kms:GenerateDataKeyWithoutPlaintext", "kms:ReEncryptFrom", "kms:ReEncryptTo"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "kms:EncryptionContext:app"
      values   = [local.kms_app_context]
    }
  }
}

# --- data: the application's field encryption ---

resource "aws_kms_key" "data" {
  for_each = local.is_secondary ? toset([]) : local.data_generations

  description             = "${local.name}: protects the data keys of encrypted database columns (generation ${each.key})"
  multi_region            = true # cannot be changed later: a key made single-Region has to be replaced to be replicated
  enable_key_rotation     = true
  rotation_period_in_days = 365
  deletion_window_in_days = local.key_deletion_days
  policy                  = data.aws_iam_policy_document.data_key.json
}

# One alias per generation (so that a standby, and an operator, can name an older key) and one stable alias for the newest, which is what the application uses.
resource "aws_kms_alias" "data_generation" {
  for_each = aws_kms_key.data

  name          = "${local.data_alias}-g${each.key}"
  target_key_id = each.value.key_id
}

resource "aws_kms_alias" "data" {
  count = local.is_secondary ? 0 : 1

  name          = local.data_alias
  target_key_id = aws_kms_key.data[local.current_generation].key_id
}

# The copy of each key in the standby's region, made by the primary's stack (as it makes the secrets' replicas): it needs only the standby's region, not
# the standby. Same key material and key id, its own ARN. The standby's stack finds them by alias.
resource "aws_kms_replica_key" "data_peer" {
  provider = aws.peer
  for_each = local.is_primary ? aws_kms_key.data : {}

  description             = "${local.name}: replica of the data key, generation ${each.key}"
  primary_key_arn         = each.value.arn
  deletion_window_in_days = local.key_deletion_days
  policy                  = data.aws_iam_policy_document.data_key.json
}

resource "aws_kms_alias" "data_peer_generation" {
  provider = aws.peer
  for_each = aws_kms_replica_key.data_peer

  name          = "${local.data_alias}-g${each.key}"
  target_key_id = each.value.key_id
}

resource "aws_kms_alias" "data_peer" {
  provider = aws.peer
  count    = local.is_primary ? 1 : 0

  name          = local.data_alias
  target_key_id = aws_kms_replica_key.data_peer[local.current_generation].key_id
}

data "aws_kms_alias" "data_generation" {
  for_each = local.is_secondary ? local.data_generations : toset([])

  name = "${local.data_alias}-g${each.key}"
}

locals {
  data_key_arns = local.is_secondary ? [for generation in data.aws_kms_alias.data_generation : generation.target_key_arn] : [for key in aws_kms_key.data : key.arn]
}

# The secret that deterministic encryption derives its keys from (the addresses people sign in with must always encrypt to the same bytes, so they cannot
# have a data key each). It is made here, wrapped by the data key, and only the wrapped form goes to Secrets Manager: useless without kms:Decrypt on the
# key, and bound to the application and its purpose by the same context the application uses (KmsEncryption::MASTER_PURPOSE; spec/deploy/kms_spec.rb
# keeps the two equal). The plaintext exists in this state, as the passwords and the signing key do (keep the state bucket private). Wrapped again under the
# newest generation whenever a rotation changes it, so a retired key never holds the only copy.
resource "random_bytes" "deterministic_master" {
  count = local.create_secrets ? 1 : 0

  length = 32
}

resource "aws_kms_ciphertext" "deterministic_master" {
  count = local.create_secrets ? 1 : 0

  key_id    = aws_kms_key.data[local.current_generation].key_id
  plaintext = random_bytes.deterministic_master[0].base64
  context = {
    app     = local.kms_app_context
    purpose = "deterministic-master"
  }
}

# --- storage: the Active Storage bucket ---

resource "aws_kms_key" "storage" {
  count = var.storage_kms_encryption ? 1 : 0

  description             = "${local.name}: Active Storage bucket (SSE-KMS)"
  enable_key_rotation     = true
  rotation_period_in_days = 365
  deletion_window_in_days = local.key_deletion_days
  policy                  = data.aws_iam_policy_document.kms_account.json
}

resource "aws_kms_alias" "storage" {
  count = var.storage_kms_encryption ? 1 : 0

  name          = "alias/${local.name}-storage"
  target_key_id = aws_kms_key.storage[0].key_id
}

# --- secrets: Secrets Manager ---

resource "aws_kms_key" "secrets" {
  count = local.create_secrets && var.secrets_kms_encryption ? 1 : 0

  description             = "${local.name}: Secrets Manager"
  enable_key_rotation     = true
  rotation_period_in_days = 365
  deletion_window_in_days = local.key_deletion_days
  policy                  = data.aws_iam_policy_document.kms_account.json
}

resource "aws_kms_alias" "secrets" {
  count = local.create_secrets && var.secrets_kms_encryption ? 1 : 0

  name          = "alias/${local.name}-secrets"
  target_key_id = aws_kms_key.secrets[0].key_id
}

locals {
  secrets_key_arn = try(aws_kms_key.secrets[0].arn, null)
}
