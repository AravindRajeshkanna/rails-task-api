# A copy of the data in another region (docs/runbooks/backup-and-restore.md), for the day the whole region is the problem.
# Off unless backup_copy_region is set, and independent of the multi-region pair (dr_role): it is the cheap alternative to a warm
# standby, and the first step towards one.
#
#   * The database: AWS Backup takes a snapshot of the Aurora cluster every day and copies it to a vault in the other region.
#     (Aurora's own automated backups stay as they are: they give point-in-time recovery inside this region; they cannot be copied.)
#   * pg_dump files: a bucket the dumps are uploaded to, replicated to a bucket in the other region. The Kamal host has no other
#     off-machine copy; Aurora users can ignore this half.
#
# A standby stack does not create any of this: the primary's cluster is what is backed up.
locals {
  backup_copy = var.backup_copy_region != "" && !local.is_secondary
}

# --- The database: AWS Backup, local vault plus a vault in the other region ---
resource "aws_kms_key" "backup" {
  count = local.backup_copy ? 1 : 0

  description             = "${local.name}: backup vault"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_key" "backup_copy" {
  count    = local.backup_copy ? 1 : 0
  provider = aws.backup_copy

  description             = "${local.name}: backup vault in ${var.backup_copy_region}"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_backup_vault" "local" {
  count = local.backup_copy ? 1 : 0

  name        = "${local.name}-backups"
  kms_key_arn = aws_kms_key.backup[0].arn
}

resource "aws_backup_vault" "copy" {
  count    = local.backup_copy ? 1 : 0
  provider = aws.backup_copy

  name        = "${local.name}-backups"
  kms_key_arn = aws_kms_key.backup_copy[0].arn
}

data "aws_iam_policy_document" "backup_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  count = local.backup_copy ? 1 : 0

  name               = "${local.name}-backup"
  assume_role_policy = data.aws_iam_policy_document.backup_trust.json
}

resource "aws_iam_role_policy_attachment" "backup" {
  count = local.backup_copy ? 1 : 0

  role       = aws_iam_role.backup[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "backup_restore" {
  count = local.backup_copy ? 1 : 0

  role       = aws_iam_role.backup[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

resource "aws_backup_plan" "database" {
  count = local.backup_copy ? 1 : 0

  name = "${local.name}-database"

  rule {
    rule_name         = "daily-with-copy"
    target_vault_name = aws_backup_vault.local[0].name
    schedule          = var.backup_schedule
    start_window      = 60  # minutes it may wait to start
    completion_window = 360 # minutes it has to finish, copy included

    lifecycle {
      delete_after = var.backup_retention_days
    }

    copy_action {
      destination_vault_arn = aws_backup_vault.copy[0].arn

      lifecycle {
        delete_after = var.backup_retention_days
      }
    }
  }
}

resource "aws_backup_selection" "database" {
  count = local.backup_copy ? 1 : 0

  name         = "${local.name}-database"
  plan_id      = aws_backup_plan.database[0].id
  iam_role_arn = aws_iam_role.backup[0].arn
  resources    = [module.db.cluster_arn]
}

# A backup that quietly stopped is the failure that matters: tell the alerts topic when a job fails.
resource "aws_backup_vault_notifications" "local" {
  count = local.backup_copy ? 1 : 0

  backup_vault_name   = aws_backup_vault.local[0].name
  sns_topic_arn       = aws_sns_topic.alerts.arn
  backup_vault_events = ["BACKUP_JOB_FAILED", "COPY_JOB_FAILED", "RESTORE_JOB_FAILED"]
}

# --- pg_dump files: a bucket, and its copy in the other region ---
# Private, versioned and expiring. The dumps should be encrypted before they are uploaded (the runbook uses age): this is
# a second layer, not the first.
resource "aws_s3_bucket" "dumps" {
  count = local.backup_copy ? 1 : 0

  bucket        = "${local.name}-dumps-${local.account_id}"
  force_destroy = !local.is_prod
}

resource "aws_s3_bucket" "dumps_copy" {
  count    = local.backup_copy ? 1 : 0
  provider = aws.backup_copy

  bucket        = "${local.name}-dumps-copy-${local.account_id}"
  force_destroy = !local.is_prod
}

resource "aws_s3_bucket_public_access_block" "dumps" {
  count = local.backup_copy ? 1 : 0

  bucket                  = aws_s3_bucket.dumps[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "dumps_copy" {
  count    = local.backup_copy ? 1 : 0
  provider = aws.backup_copy

  bucket                  = aws_s3_bucket.dumps_copy[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "dumps" {
  count = local.backup_copy ? 1 : 0

  bucket = aws_s3_bucket.dumps[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "dumps_copy" {
  count    = local.backup_copy ? 1 : 0
  provider = aws.backup_copy

  bucket = aws_s3_bucket.dumps_copy[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "dumps" {
  count = local.backup_copy ? 1 : 0

  bucket = aws_s3_bucket.dumps[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_versioning" "dumps_copy" {
  count    = local.backup_copy ? 1 : 0
  provider = aws.backup_copy

  bucket = aws_s3_bucket.dumps_copy[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "dumps" {
  count = local.backup_copy ? 1 : 0

  bucket = aws_s3_bucket.dumps[0].id
  rule {
    id     = "expire-dumps"
    status = "Enabled"
    filter {}
    expiration {
      days = var.dump_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.dumps]
}

resource "aws_s3_bucket_lifecycle_configuration" "dumps_copy" {
  count    = local.backup_copy ? 1 : 0
  provider = aws.backup_copy

  bucket = aws_s3_bucket.dumps_copy[0].id
  rule {
    id     = "expire-dumps"
    status = "Enabled"
    filter {}
    expiration {
      days = var.dump_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.dumps_copy]
}

data "aws_iam_policy_document" "dumps_tls_only" {
  count = local.backup_copy ? 1 : 0

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.dumps[0].arn, "${aws_s3_bucket.dumps[0].arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "dumps" {
  count = local.backup_copy ? 1 : 0

  bucket     = aws_s3_bucket.dumps[0].id
  policy     = data.aws_iam_policy_document.dumps_tls_only[0].json
  depends_on = [aws_s3_bucket_public_access_block.dumps]
}

data "aws_iam_policy_document" "dumps_replication" {
  count = local.backup_copy ? 1 : 0

  statement {
    sid       = "ReadReplicationConfiguration"
    actions   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
    resources = [aws_s3_bucket.dumps[0].arn]
  }
  statement {
    sid       = "ReadSourceObjects"
    actions   = ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging"]
    resources = ["${aws_s3_bucket.dumps[0].arn}/*"]
  }
  statement {
    sid       = "WriteToTheCopy"
    actions   = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"]
    resources = ["${aws_s3_bucket.dumps_copy[0].arn}/*"]
  }
}

resource "aws_iam_role" "dumps_replication" {
  count = local.backup_copy ? 1 : 0

  name               = "${local.name}-dumps-replication"
  assume_role_policy = data.aws_iam_policy_document.replication_trust.json
}

resource "aws_iam_role_policy" "dumps_replication" {
  count = local.backup_copy ? 1 : 0

  name   = "replicate-dumps"
  role   = aws_iam_role.dumps_replication[0].id
  policy = data.aws_iam_policy_document.dumps_replication[0].json
}

resource "aws_s3_bucket_replication_configuration" "dumps" {
  count = local.backup_copy ? 1 : 0

  bucket = aws_s3_bucket.dumps[0].id
  role   = aws_iam_role.dumps_replication[0].arn

  rule {
    id     = "to-${var.backup_copy_region}"
    status = "Enabled"

    filter {}

    # A deletion is not copied: a dump removed by mistake (or by an attacker with the writer's credentials) survives in the other region.
    delete_marker_replication {
      status = "Disabled"
    }

    destination {
      bucket        = aws_s3_bucket.dumps_copy[0].arn
      storage_class = "STANDARD"
    }
  }

  depends_on = [aws_s3_bucket_versioning.dumps, aws_s3_bucket_versioning.dumps_copy]
}

# What a dump writer needs and nothing else: it can add objects under dumps/, and cannot read, list or delete any. A host that is
# compromised can then not read or destroy the history. Attach it to whatever identity the backup job runs as.
data "aws_iam_policy_document" "dump_upload" {
  count = local.backup_copy ? 1 : 0

  statement {
    sid       = "WriteDumps"
    actions   = ["s3:PutObject", "s3:AbortMultipartUpload"]
    resources = ["${aws_s3_bucket.dumps[0].arn}/dumps/*"]
  }
}

resource "aws_iam_policy" "dump_upload" {
  count = local.backup_copy ? 1 : 0

  name        = "${local.name}-dump-upload"
  description = "Upload pg_dump files to ${local.name}'s dump bucket; no read, list or delete"
  policy      = data.aws_iam_policy_document.dump_upload[0].json
}
