# Who used the keys, and who changed them (docs/aws/kms.md, "Watching the keys"). CloudTrail records every KMS request as a management event; the account's
# event history keeps 90 days of them for free, but cannot be alarmed on or kept longer. This trail records KMS events only (a trail's advanced event
# selector can say so, which keeps the bill to the events that matter), keeps them in S3 and CloudWatch Logs, and the alarms below read the logs.
#
# Every request the application makes carries its encryption context (app = task-api), which CloudTrail records, so "the application's decrypts" is a
# query, not a guess. Left off (enable_kms_audit = false) where the account or organization already has a trail that records KMS events.

locals {
  kms_audit_name = "${local.name}-kms-audit"
  kms_audit_on   = var.enable_kms_audit
  kms_trail_arn  = "arn:${data.aws_partition.current.partition}:cloudtrail:${var.region}:${local.account_id}:trail/${local.kms_audit_name}"
}

resource "aws_s3_bucket" "kms_audit" {
  count = local.kms_audit_on ? 1 : 0

  bucket        = "${local.kms_audit_name}-${local.account_id}"
  force_destroy = !local.is_prod
}

resource "aws_s3_bucket_public_access_block" "kms_audit" {
  count = local.kms_audit_on ? 1 : 0

  bucket                  = aws_s3_bucket.kms_audit[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Not the data key and not a KMS key at all: logging a key's use into a bucket that uses that key would make every log file a KMS event.
resource "aws_s3_bucket_server_side_encryption_configuration" "kms_audit" {
  count = local.kms_audit_on ? 1 : 0

  bucket = aws_s3_bucket.kms_audit[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "kms_audit" {
  count = local.kms_audit_on ? 1 : 0

  bucket = aws_s3_bucket.kms_audit[0].id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = var.kms_audit_retention_days
    }
  }
}

data "aws_iam_policy_document" "kms_audit_bucket" {
  count = local.kms_audit_on ? 1 : 0

  statement {
    sid       = "CloudTrailChecksTheBucket"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.kms_audit[0].arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.kms_trail_arn]
    }
  }
  statement {
    sid       = "CloudTrailWritesItsFiles"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.kms_audit[0].arn}/AWSLogs/${local.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.kms_trail_arn]
    }
  }
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.kms_audit[0].arn, "${aws_s3_bucket.kms_audit[0].arn}/*"]
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

resource "aws_s3_bucket_policy" "kms_audit" {
  count = local.kms_audit_on ? 1 : 0

  bucket     = aws_s3_bucket.kms_audit[0].id
  policy     = data.aws_iam_policy_document.kms_audit_bucket[0].json
  depends_on = [aws_s3_bucket_public_access_block.kms_audit]
}

resource "aws_cloudwatch_log_group" "kms_audit" {
  count = local.kms_audit_on ? 1 : 0

  name              = "/task-api/${local.name}/kms-audit"
  retention_in_days = 90
}

data "aws_iam_policy_document" "kms_audit_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "kms_audit" {
  count = local.kms_audit_on ? 1 : 0

  name               = "${local.kms_audit_name}-logs"
  assume_role_policy = data.aws_iam_policy_document.kms_audit_trust.json
}

resource "aws_iam_role_policy" "kms_audit" {
  count = local.kms_audit_on ? 1 : 0

  name = "write-the-log-group"
  role = aws_iam_role.kms_audit[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.kms_audit[0].arn}:*"
    }]
  })
}

resource "aws_cloudtrail" "kms" {
  count = local.kms_audit_on ? 1 : 0

  name                       = local.kms_audit_name
  s3_bucket_name             = aws_s3_bucket.kms_audit[0].id
  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.kms_audit[0].arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.kms_audit[0].arn
  enable_log_file_validation = true # a digest file per hour, so a log file that was altered or removed can be detected
  is_multi_region_trail      = false

  # KMS management events and nothing else. (Encrypt, Decrypt and GenerateDataKey are management events; they are not S3-style data events.)
  advanced_event_selector {
    name = "KMS management events"
    field_selector {
      field  = "eventCategory"
      equals = ["Management"]
    }
    field_selector {
      field  = "eventSource"
      equals = ["kms.amazonaws.com"]
    }
  }

  depends_on = [aws_s3_bucket_policy.kms_audit]
}

# --- What to alarm on ---

locals {
  kms_metric_namespace = "TaskApi/KMS"
  kms_alarms = local.kms_audit_on ? {
    decrypt_volume = {
      metric      = "DecryptRequests"
      pattern     = "{ ($.eventSource = \"kms.amazonaws.com\") && ($.eventName = \"Decrypt\") && ($.requestParameters.encryptionContext.app = \"${local.kms_app_context}\") }"
      threshold   = var.kms_decrypt_alarm_threshold
      description = "The application's Decrypt requests to KMS are unusually many in five minutes. It caches unwrapped keys, so this is much more than its usual few; a loop, a cache that stopped working, or a copy of its credentials being used. Runbook: docs/runbooks/kms-key-rotation.md"
    }
    access_denied = {
      metric      = "AccessDenied"
      pattern     = "{ ($.eventSource = \"kms.amazonaws.com\") && ($.errorCode = \"AccessDenied*\") }"
      threshold   = 1
      description = "KMS refused a request: a role that lost its permission (the application then answers 503 encryption_unavailable), or someone trying a key they were not given. Look at the userIdentity in the log. Runbook: docs/runbooks/kms-key-rotation.md"
    }
    key_changes = {
      metric      = "KeyChanges"
      pattern     = "{ ($.eventSource = \"kms.amazonaws.com\") && (($.eventName = \"DisableKey\") || ($.eventName = \"ScheduleKeyDeletion\") || ($.eventName = \"PutKeyPolicy\") || ($.eventName = \"DisableKeyRotation\") || ($.eventName = \"UpdateAlias\") || ($.eventName = \"DeleteAlias\")) }"
      threshold   = 1
      description = "A KMS key or alias was disabled, scheduled for deletion, re-pointed, or had its policy or rotation changed. Expected during a planned rotation (docs/runbooks/kms-key-rotation.md); otherwise treat it as an incident."
    }
  } : {}
}

resource "aws_cloudwatch_log_metric_filter" "kms" {
  for_each = local.kms_alarms

  name           = "${local.kms_audit_name}-${each.key}"
  log_group_name = aws_cloudwatch_log_group.kms_audit[0].name
  pattern        = each.value.pattern

  metric_transformation {
    name          = each.value.metric
    namespace     = local.kms_metric_namespace
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "kms" {
  for_each = local.kms_alarms

  alarm_name          = "${local.name}-kms-${replace(each.key, "_", "-")}"
  alarm_description   = each.value.description
  namespace           = local.kms_metric_namespace
  metric_name         = each.value.metric
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  depends_on = [aws_cloudwatch_log_metric_filter.kms]
}

output "kms_audit_log_group" { value = try(aws_cloudwatch_log_group.kms_audit[0].name, null) }
