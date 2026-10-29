# Active Storage (task attachments and avatars). Private, encrypted and versioned; served to clients through
# short-lived signed URLs the API generates.
resource "aws_s3_bucket" "storage" {
  bucket        = "${local.name}-storage-${local.account_id}"
  force_destroy = !local.is_prod
}

resource "aws_s3_bucket_public_access_block" "storage" {
  bucket                  = aws_s3_bucket.storage.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "storage" {
  bucket = aws_s3_bucket.storage.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "storage" {
  bucket = aws_s3_bucket.storage.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "storage" {
  bucket = aws_s3_bucket.storage.id
  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "storage_tls_only" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.storage.arn, "${aws_s3_bucket.storage.arn}/*"]
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

resource "aws_s3_bucket_policy" "storage" {
  bucket     = aws_s3_bucket.storage.id
  policy     = data.aws_iam_policy_document.storage_tls_only.json
  depends_on = [aws_s3_bucket_public_access_block.storage]
}

# --- Cross-region replication (docs/aws/multi-region.md) ---
# Each side of a pair replicates to the other, so after a failover new uploads flow back to the original region without
# a change. S3 does not replicate replicas onward, so the two directions do not loop. Only objects written after the
# configuration exists are replicated: backfill existing ones once with S3 Batch Replication (the runbook has the step).
data "aws_iam_policy_document" "replication_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "replication" {
  statement {
    sid       = "ReadReplicationConfiguration"
    actions   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
    resources = [aws_s3_bucket.storage.arn]
  }
  statement {
    sid       = "ReadSourceObjects"
    actions   = ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging"]
    resources = ["${aws_s3_bucket.storage.arn}/*"]
  }
  statement {
    sid       = "WriteToThePeerBucket"
    actions   = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${local.peer_name}-storage-${local.account_id}/*"]
  }
}

resource "aws_iam_role" "storage_replication" {
  count = local.replicate ? 1 : 0

  name               = "${local.name}-storage-replication"
  assume_role_policy = data.aws_iam_policy_document.replication_trust.json
}

resource "aws_iam_role_policy" "storage_replication" {
  count = local.replicate ? 1 : 0

  name   = "replicate-to-${local.peer_name}"
  role   = aws_iam_role.storage_replication[0].id
  policy = data.aws_iam_policy_document.replication.json
}

resource "aws_s3_bucket_replication_configuration" "storage" {
  count = local.replicate ? 1 : 0

  bucket = aws_s3_bucket.storage.id
  role   = aws_iam_role.storage_replication[0].arn

  rule {
    id     = "to-${local.peer_name}"
    status = "Enabled"

    filter {}

    # A deletion is not copied: a mistaken delete in one region leaves the object in the other.
    delete_marker_replication {
      status = "Disabled"
    }

    destination {
      bucket        = "arn:${data.aws_partition.current.partition}:s3:::${local.peer_name}-storage-${local.account_id}"
      storage_class = "STANDARD"

      dynamic "replication_time" {
        for_each = var.dr_s3_replication_time_control ? [1] : []
        content {
          status = "Enabled"
          time {
            minutes = 15
          }
        }
      }

      dynamic "metrics" {
        for_each = var.dr_s3_replication_time_control ? [1] : []
        content {
          status = "Enabled"
          event_threshold {
            minutes = 15
          }
        }
      }
    }
  }

  depends_on = [aws_s3_bucket_versioning.storage]
}
