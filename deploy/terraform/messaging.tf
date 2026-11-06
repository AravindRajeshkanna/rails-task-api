# The event backbone: services publish CloudEvents to one SNS topic; each consumer owns an SQS queue (with a
# dead-letter queue) subscribed with a filter on the event type. A new consumer is a new queue and a new
# subscription; no publisher changes.

resource "aws_sns_topic" "events" {
  name              = "${local.name}-events"
  kms_master_key_id = "alias/aws/sns"
}

# --- Notification service queue ---
resource "aws_sqs_queue" "notifications_dlq" {
  name                      = "${local.name}-notifications-dlq"
  message_retention_seconds = 1209600 # 14 days to look at what failed
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "notifications" {
  name                       = "${local.name}-notifications"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 345600
  receive_wait_time_seconds  = 20
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.notifications_dlq.arn
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "notifications_dlq" {
  queue_url = aws_sqs_queue.notifications_dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.notifications.arn]
  })
}

data "aws_iam_policy_document" "notifications_queue" {
  statement {
    sid       = "AllowEventsTopic"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.notifications.arn]
    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.events.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "notifications" {
  queue_url = aws_sqs_queue.notifications.id
  policy    = data.aws_iam_policy_document.notifications_queue.json
}

resource "aws_sns_topic_subscription" "notifications" {
  topic_arn            = aws_sns_topic.events.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.notifications.arn
  raw_message_delivery = true

  filter_policy = jsonencode({
    type = ["task.assigned", "task.due_soon", "task.completed", "user.password_reset_requested", "user.erased"]
  })
  depends_on = [aws_sqs_queue_policy.notifications]
}

# --- Auth service queue: the Task API erased a person, so the identity goes (ADR 79) ---
# Only `user.erased` arrives here, and it must not be lost to a quiet week: a message that outlives the retention is dropped without a trace, so the queue
# keeps messages the longest SQS allows (14 days) and an alarm fires long before that (observability.tf: the age of the oldest message, and the DLQ).
resource "aws_sqs_queue" "auth_erasure_dlq" {
  name                      = "${local.name}-auth-erasure-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "auth_erasure" {
  name                       = "${local.name}-auth-erasure"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 1209600
  receive_wait_time_seconds  = 20
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.auth_erasure_dlq.arn
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "auth_erasure_dlq" {
  queue_url = aws_sqs_queue.auth_erasure_dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.auth_erasure.arn]
  })
}

data "aws_iam_policy_document" "auth_erasure_queue" {
  statement {
    sid       = "AllowEventsTopic"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.auth_erasure.arn]
    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.events.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "auth_erasure" {
  queue_url = aws_sqs_queue.auth_erasure.id
  policy    = data.aws_iam_policy_document.auth_erasure_queue.json
}

resource "aws_sns_topic_subscription" "auth_erasure" {
  topic_arn            = aws_sns_topic.events.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.auth_erasure.arn
  raw_message_delivery = true

  filter_policy = jsonencode({
    type = ["user.erased"]
  })
  depends_on = [aws_sqs_queue_policy.auth_erasure]
}

# --- EventBridge: a bus for AWS-native events and for future cross-account/SaaS integrations ---
resource "aws_cloudwatch_event_bus" "domain" {
  name = local.name
}

resource "aws_cloudwatch_event_archive" "domain" {
  name             = "${local.name}-archive"
  event_source_arn = aws_cloudwatch_event_bus.domain.arn
  retention_days   = 14 # replayable
}
