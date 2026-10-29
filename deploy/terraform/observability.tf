# Phase 2: alerting and early AIOps on CloudWatch.
#   * One SNS topic carries every alert; PagerDuty, email, Slack (AWS Chatbot) and the AIOps Lambdas subscribe.
#   * Anomaly-detection alarms learn each metric's normal daily/weekly shape, so "latency is unusual for a
#     Tuesday morning" fires without hand-tuned thresholds. Static alarms back them up where a hard limit exists.
#   * Metrics come from the ALB, SQS and Aurora (AWS-native) and from the app's CloudWatch EMF log lines
#     (namespace TaskApi: QueueDepth, OldestJobAgeSeconds, FailedJobs, OutboxOldestAgeSeconds; see PublishQueueMetricsJob).
# Amazon Lookout for Metrics, which the roadmap names, was discontinued by AWS in October 2025;
# CloudWatch anomaly detection is its replacement here (docs/decisions.md).

data "aws_iam_policy_document" "alerts_key" {
  statement {
    sid       = "AccountAdministers"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${local.account_id}:root"]
    }
  }
  statement {
    sid       = "AlertSourcesPublish"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com", "events.amazonaws.com", "budgets.amazonaws.com", "costalerts.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "alerts" {
  description         = "${local.name} alerts topic"
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.alerts_key.json
}

resource "aws_kms_alias" "alerts" {
  name          = "alias/${local.name}-alerts"
  target_key_id = aws_kms_key.alerts.key_id
}

resource "aws_sns_topic" "alerts" {
  name              = "${local.name}-alerts"
  kms_master_key_id = aws_kms_key.alerts.id
}

data "aws_iam_policy_document" "alerts_topic" {
  statement {
    sid       = "AlertSourcesPublish"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com", "events.amazonaws.com", "budgets.amazonaws.com", "costalerts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}

resource "aws_sns_topic_subscription" "email" {
  for_each  = toset(var.alert_emails)
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_sns_topic_subscription" "pagerduty" {
  count = var.pagerduty_https_endpoint == "" ? 0 : 1

  topic_arn              = aws_sns_topic.alerts.arn
  protocol               = "https"
  endpoint               = var.pagerduty_https_endpoint
  endpoint_auto_confirms = true
}

# Slack through AWS Chatbot ("Amazon Q Developer in chat applications"). Authorize your Slack workspace once in
# the console (docs/aws/setup-guide.md), then set slack_workspace_id and slack_channel_id.
data "aws_iam_policy_document" "chatbot_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["chatbot.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "chatbot" {
  count              = var.slack_workspace_id == "" ? 0 : 1
  name               = "${local.name}-chatbot"
  assume_role_policy = data.aws_iam_policy_document.chatbot_trust.json
}

resource "aws_iam_role_policy_attachment" "chatbot" {
  count      = var.slack_workspace_id == "" ? 0 : 1
  role       = aws_iam_role.chatbot[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/CloudWatchReadOnlyAccess"
}

resource "aws_chatbot_slack_channel_configuration" "alerts" {
  count = var.slack_workspace_id == "" ? 0 : 1

  configuration_name = "${local.name}-alerts"
  iam_role_arn       = aws_iam_role.chatbot[0].arn
  slack_channel_id   = var.slack_channel_id
  slack_team_id      = var.slack_workspace_id
  sns_topic_arns     = [aws_sns_topic.alerts.arn]
}

# --- EventBridge: AWS-native findings join the same alert stream ---
resource "aws_cloudwatch_event_rule" "ecr_findings" {
  name        = "${local.name}-ecr-critical-findings"
  description = "A pushed image has critical or high vulnerabilities"
  event_pattern = jsonencode({
    source        = ["aws.ecr"]
    "detail-type" = ["ECR Image Scan"]
    detail        = { "finding-severity-counts" = { CRITICAL = [{ exists = true }] } }
  })
}

resource "aws_cloudwatch_event_target" "ecr_findings" {
  rule = aws_cloudwatch_event_rule.ecr_findings.name
  arn  = aws_sns_topic.alerts.arn
}

resource "aws_cloudwatch_event_rule" "health" {
  name        = "${local.name}-aws-health"
  description = "AWS Health events that affect this account"
  event_pattern = jsonencode({
    source        = ["aws.health"]
    "detail-type" = ["AWS Health Event"]
  })
}

resource "aws_cloudwatch_event_target" "health" {
  rule = aws_cloudwatch_event_rule.health.name
  arn  = aws_sns_topic.alerts.arn
}

# --- Alarms ---
locals {
  alarm_actions = [aws_sns_topic.alerts.arn]
  alb_dimension = var.alb_exists ? { LoadBalancer = data.aws_lb.api[0].arn_suffix } : {}
}

# Latency: p95 of target response time outside its learned band.
resource "aws_cloudwatch_metric_alarm" "latency_anomaly" {
  count = var.alb_exists ? 1 : 0

  alarm_name          = "${local.name}-latency-anomaly"
  alarm_description   = "API p95 latency is unusually high for this time of day. Runbook: docs/runbooks/high-latency.md"
  comparison_operator = "GreaterThanUpperThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold_metric_id = "band"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  metric_query {
    id          = "p95"
    return_data = true
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "TargetResponseTime"
      period      = 300
      stat        = "p95"
      dimensions  = local.alb_dimension
    }
  }
  metric_query {
    id          = "band"
    expression  = "ANOMALY_DETECTION_BAND(p95, 2)"
    label       = "expected latency"
    return_data = true
  }
}

# Error rate: 5xx responses as a percentage of requests, against its learned band.
resource "aws_cloudwatch_metric_alarm" "error_rate_anomaly" {
  count = var.alb_exists ? 1 : 0

  alarm_name          = "${local.name}-error-rate-anomaly"
  alarm_description   = "The API's 5xx rate is unusually high. Runbook: docs/runbooks/high-error-rate.md"
  comparison_operator = "GreaterThanUpperThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold_metric_id = "band"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  metric_query {
    id          = "errors"
    return_data = false
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      period      = 300
      stat        = "Sum"
      dimensions  = local.alb_dimension
    }
  }
  metric_query {
    id          = "requests"
    return_data = false
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      period      = 300
      stat        = "Sum"
      dimensions  = local.alb_dimension
    }
  }
  metric_query {
    id          = "rate"
    expression  = "IF(requests > 20, 100 * errors / requests, 0)"
    label       = "5xx %"
    return_data = true
  }
  metric_query {
    id          = "band"
    expression  = "ANOMALY_DETECTION_BAND(rate, 3)"
    label       = "expected 5xx %"
    return_data = true
  }
}

# Hard backstop: more than 5% errors is bad however "normal" it has become.
resource "aws_cloudwatch_metric_alarm" "error_rate_high" {
  count = var.alb_exists ? 1 : 0

  alarm_name          = "${local.name}-error-rate-over-5-percent"
  alarm_description   = "More than 5% of requests failed for 10 minutes. Runbook: docs/runbooks/high-error-rate.md"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 5
  evaluation_periods  = 2
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  metric_query {
    id          = "errors"
    return_data = false
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      period      = 300
      stat        = "Sum"
      dimensions  = local.alb_dimension
    }
  }
  metric_query {
    id          = "requests"
    return_data = false
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      period      = 300
      stat        = "Sum"
      dimensions  = local.alb_dimension
    }
  }
  metric_query {
    id          = "rate"
    expression  = "IF(requests > 20, 100 * errors / requests, 0)"
    label       = "5xx %"
    return_data = true
  }
}

# Queue depth from the app's EMF metrics: anomaly band, plus hard limits on backlog and queue latency.
resource "aws_cloudwatch_metric_alarm" "queue_depth_anomaly" {
  alarm_name          = "${local.name}-queue-depth-anomaly"
  alarm_description   = "The background job backlog is unusual for this time. KEDA should be adding workers. Runbook: docs/runbooks/queue-backlog.md"
  comparison_operator = "GreaterThanUpperThreshold"
  evaluation_periods  = 5
  datapoints_to_alarm = 4
  threshold_metric_id = "band"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  metric_query {
    id          = "depth"
    return_data = true
    metric {
      namespace   = "TaskApi"
      metric_name = "QueueDepth"
      period      = 60
      stat        = "Maximum"
      dimensions  = { Environment = var.environment }
    }
  }
  metric_query {
    id          = "band"
    expression  = "ANOMALY_DETECTION_BAND(depth, 3)"
    label       = "expected backlog"
    return_data = true
  }
}

resource "aws_cloudwatch_metric_alarm" "queue_backlog" {
  alarm_name          = "${local.name}-queue-backlog"
  alarm_description   = "More than ${var.queue_depth_alarm_threshold} jobs waiting. Runbook: docs/runbooks/queue-backlog.md"
  namespace           = "TaskApi"
  metric_name         = "QueueDepth"
  dimensions          = { Environment = var.environment }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 10
  datapoints_to_alarm = 8
  threshold           = var.queue_depth_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "queue_latency" {
  alarm_name          = "${local.name}-queue-latency"
  alarm_description   = "The oldest waiting job is over 5 minutes old: workers are not keeping up or are not running. Runbook: docs/runbooks/queue-backlog.md"
  namespace           = "TaskApi"
  metric_name         = "OldestJobAgeSeconds"
  dimensions          = { Environment = var.environment }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  threshold           = 300
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "outbox_stuck" {
  alarm_name          = "${local.name}-event-outbox-stuck"
  alarm_description   = "An event has waited over 5 minutes to be published to SNS: the other services are not hearing about changes. Nothing is lost (it is in the outbox). Runbook: docs/runbooks/event-outbox.md"
  namespace           = "TaskApi"
  metric_name         = "OutboxOldestAgeSeconds"
  dimensions          = { Environment = var.environment }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  threshold           = 300
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "failed_jobs" {
  alarm_name          = "${local.name}-failed-jobs"
  alarm_description   = "Jobs have exhausted their retries and need a human."
  namespace           = "TaskApi"
  metric_name         = "FailedJobs"
  dimensions          = { Environment = var.environment }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 6
  datapoints_to_alarm = 6
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "notifications_dlq" {
  alarm_name          = "${local.name}-notifications-dlq"
  alarm_description   = "Notification events could not be processed after 5 attempts and sit in the dead-letter queue."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.notifications_dlq.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "database_capacity" {
  alarm_name          = "${local.name}-database-near-max-capacity"
  alarm_description   = "Aurora is using over 90% of its maximum ACUs for 15 minutes: raise db_max_acu or find the load."
  namespace           = "AWS/RDS"
  metric_name         = "ServerlessDatabaseCapacity"
  dimensions          = { DBClusterIdentifier = module.db.cluster_id }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.db_max_acu * 0.9
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
}

resource "aws_cloudwatch_dashboard" "overview" {
  dashboard_name = local.name
  dashboard_body = jsonencode({
    widgets = concat(
      var.alb_exists ? [
        {
          type = "metric", x = 0, y = 0, width = 8, height = 6
          properties = {
            title   = "p95 latency (seconds)", region = var.region, stat = "p95", period = 300
            metrics = [["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", data.aws_lb.api[0].arn_suffix]]
          }
        },
        {
          type = "metric", x = 8, y = 0, width = 8, height = 6
          properties = {
            title = "Requests and 5xx", region = var.region, stat = "Sum", period = 300
            metrics = [
              ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", data.aws_lb.api[0].arn_suffix],
              ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", data.aws_lb.api[0].arn_suffix]
            ]
          }
        }
      ] : [],
      [
        {
          type = "metric", x = 16, y = 0, width = 8, height = 6
          properties = {
            title = "Job backlog and queue latency", region = var.region, period = 60, stat = "Maximum"
            metrics = [
              ["TaskApi", "QueueDepth", "Environment", var.environment],
              ["TaskApi", "OldestJobAgeSeconds", "Environment", var.environment, { yAxis = "right" }]
            ]
          }
        },
        {
          type = "metric", x = 0, y = 6, width = 8, height = 6
          properties = {
            title   = "Aurora capacity (ACU)", region = var.region, period = 300, stat = "Maximum"
            metrics = [["AWS/RDS", "ServerlessDatabaseCapacity", "DBClusterIdentifier", module.db.cluster_id]]
          }
        },
        {
          type = "metric", x = 8, y = 6, width = 8, height = 6
          properties = {
            title = "Notification queue", region = var.region, period = 60, stat = "Maximum"
            metrics = [
              ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.notifications.name],
              ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.notifications_dlq.name]
            ]
          }
        },
        {
          type = "alarm", x = 16, y = 6, width = 8, height = 6
          properties = {
            title = "Alarms"
            alarms = [
              aws_cloudwatch_metric_alarm.queue_depth_anomaly.arn, aws_cloudwatch_metric_alarm.queue_backlog.arn,
              aws_cloudwatch_metric_alarm.queue_latency.arn, aws_cloudwatch_metric_alarm.notifications_dlq.arn
            ]
          }
        }
      ]
    )
  })
}
