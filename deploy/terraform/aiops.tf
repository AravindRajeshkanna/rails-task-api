# Phase 6: the AIOps loop.
#
#   metrics + logs + traces --> CloudWatch alarms --> SNS alerts topic --+--> PagerDuty / Slack / email  (humans)
#                                                                        +--> rca Lambda: gathers evidence, asks Bedrock,
#                                                                        |    posts a root-cause analysis next to the alarm
#                                                                        +--> remediate Lambda: a small playbook of safe,
#                                                                             reversible actions (dry run by default)
#
# Both Lambdas sit in the VPC so they reach the cluster's private API endpoint, and are mapped by EKS access
# entries to Kubernetes groups whose permissions are spelled out in deploy/k8s/platform/aiops-rbac.yaml.

locals {
  aiops_enabled = var.enable_aiops_automation
  aiops_dir     = "${path.module}/../lambda/aiops"
  ai_core_dir   = "${path.module}/../../gems/ai_core/lib"

  # The Lambda code plus the ai_core gem's source (pure Ruby; the runtime provides the AWS SDK), laid out so
  # `require "ai_core"` and `require "aiops/..."` resolve from lib/.
  aiops_sources = merge(
    { for file in fileset(local.aiops_dir, "*.rb") : file => "${local.aiops_dir}/${file}" },
    { for file in fileset(local.aiops_dir, "lib/**/*.rb") : file => "${local.aiops_dir}/${file}" },
    { for file in fileset(local.ai_core_dir, "**/*.rb") : "lib/${file}" => "${local.ai_core_dir}/${file}" }
  )
}

data "archive_file" "aiops" {
  count       = local.aiops_enabled ? 1 : 0
  type        = "zip"
  output_path = "${path.module}/.build/aiops.zip"

  dynamic "source" {
    for_each = local.aiops_sources
    content {
      filename = source.key
      content  = file(source.value)
    }
  }
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_security_group" "aiops" {
  count       = local.aiops_enabled ? 1 : 0
  name        = "${local.name}-aiops-lambda"
  description = "AIOps Lambdas: outbound HTTPS only"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_egress_rule" "aiops_https" {
  count             = local.aiops_enabled ? 1 : 0
  security_group_id = aws_security_group.aiops[0].id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
  description       = "AWS APIs, Bedrock and the cluster endpoint"
}

# Let the Lambdas reach the Kubernetes API (the cluster security group fronts the private endpoint).
resource "aws_vpc_security_group_ingress_rule" "cluster_from_aiops" {
  count                        = local.aiops_enabled ? 1 : 0
  security_group_id            = module.eks.cluster_security_group_id
  referenced_security_group_id = aws_security_group.aiops[0].id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "AIOps Lambdas to the Kubernetes API"
}

# --- Root-cause analysis ---
resource "aws_iam_role" "rca" {
  count              = local.aiops_enabled ? 1 : 0
  name               = "${local.name}-aiops-rca"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

data "aws_iam_policy_document" "rca" {
  statement {
    sid       = "ReadEvidence"
    actions   = ["cloudwatch:DescribeAlarms", "cloudwatch:DescribeAlarmHistory", "cloudwatch:GetMetricData", "xray:GetTraceSummaries", "xray:BatchGetTraces", "logs:GetQueryResults", "eks:DescribeCluster"]
    resources = ["*"]
  }
  statement {
    sid       = "QueryAppLogs"
    actions   = ["logs:StartQuery"]
    resources = ["arn:${data.aws_partition.current.partition}:logs:${var.region}:${local.account_id}:log-group:/aws/containerinsights/${local.name}/application:*"]
  }
  statement {
    sid     = "AskTheModel"
    actions = ["bedrock:InvokeModel"]
    resources = [
      "arn:${data.aws_partition.current.partition}:bedrock:*::foundation-model/*",
      "arn:${data.aws_partition.current.partition}:bedrock:*:${local.account_id}:inference-profile/*"
    ]
  }
  statement {
    sid       = "PostTheAnalysis"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }
  statement {
    sid       = "UseAlertsKey"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [aws_kms_key.alerts.arn]
  }
}

resource "aws_iam_role_policy" "rca" {
  count  = local.aiops_enabled ? 1 : 0
  name   = "rca"
  role   = aws_iam_role.rca[0].id
  policy = data.aws_iam_policy_document.rca.json
}

resource "aws_iam_role_policy_attachment" "rca_basic" {
  for_each   = local.aiops_enabled ? toset(["service-role/AWSLambdaVPCAccessExecutionRole", "AWSXRayDaemonWriteAccess"]) : toset([])
  role       = aws_iam_role.rca[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/${each.value}"
}

resource "aws_lambda_function" "rca" {
  count            = local.aiops_enabled ? 1 : 0
  function_name    = "${local.name}-aiops-rca"
  description      = "Explains firing alarms: evidence from CloudWatch, logs, traces and deploys, analysed by Bedrock"
  role             = aws_iam_role.rca[0].arn
  runtime          = "ruby3.4"
  handler          = "rca.handler"
  architectures    = ["arm64"]
  timeout          = 120
  memory_size      = 512
  filename         = data.archive_file.aiops[0].output_path
  source_code_hash = data.archive_file.aiops[0].output_base64sha256

  # Two analyses at a time is plenty, and it caps what a flapping alarm can spend on the model.
  reserved_concurrent_executions = 2

  environment {
    variables = {
      ENVIRONMENT          = var.environment
      CLUSTER_NAME         = module.eks.cluster_name
      APP_LOG_GROUP        = "/aws/containerinsights/${local.name}/application"
      ALERTS_TOPIC_ARN     = aws_sns_topic.alerts.arn
      K8S_ACCESS           = "true"
      AI_PROVIDER          = "bedrock"
      AI_MODEL_ID          = var.bedrock_model_id
      AI_TIMEOUT           = "90"
      AI_MAX_OUTPUT_TOKENS = "1200"
    }
  }

  vpc_config {
    subnet_ids         = module.vpc.private_subnets
    security_group_ids = [aws_security_group.aiops[0].id]
  }

  tracing_config {
    mode = "Active"
  }
}

# --- Auto-remediation ---
resource "aws_iam_role" "remediate" {
  count              = local.aiops_enabled ? 1 : 0
  name               = "${local.name}-aiops-remediate"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

data "aws_iam_policy_document" "remediate" {
  statement {
    sid       = "FindTheCluster"
    actions   = ["eks:DescribeCluster"]
    resources = [module.eks.cluster_arn]
  }
  statement {
    sid       = "ReportWhatItDid"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }
  statement {
    sid       = "UseAlertsKey"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [aws_kms_key.alerts.arn]
  }
}

resource "aws_iam_role_policy" "remediate" {
  count  = local.aiops_enabled ? 1 : 0
  name   = "remediate"
  role   = aws_iam_role.remediate[0].id
  policy = data.aws_iam_policy_document.remediate.json
}

resource "aws_iam_role_policy_attachment" "remediate_basic" {
  count      = local.aiops_enabled ? 1 : 0
  role       = aws_iam_role.remediate[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_lambda_function" "remediate" {
  count            = local.aiops_enabled ? 1 : 0
  function_name    = "${local.name}-aiops-remediate"
  description      = "Applies a small playbook of safe, reversible actions when specific alarms fire (dry run unless enabled)"
  role             = aws_iam_role.remediate[0].arn
  runtime          = "ruby3.4"
  handler          = "remediate.handler"
  architectures    = ["arm64"]
  timeout          = 60
  memory_size      = 256
  filename         = data.archive_file.aiops[0].output_path
  source_code_hash = data.archive_file.aiops[0].output_base64sha256

  reserved_concurrent_executions = 1 # one remediation at a time: actions must not race each other

  environment {
    variables = {
      ENVIRONMENT         = var.environment
      CLUSTER_NAME        = module.eks.cluster_name
      ALERTS_TOPIC_ARN    = aws_sns_topic.alerts.arn
      K8S_NAMESPACE       = local.namespace
      REMEDIATION_DRY_RUN = tostring(var.remediation_dry_run)
    }
  }

  vpc_config {
    subnet_ids         = module.vpc.private_subnets
    security_group_ids = [aws_security_group.aiops[0].id]
  }

  tracing_config {
    mode = "Active"
  }
}

# Kubernetes identity: the Lambda roles map to groups; aiops-rbac.yaml binds the groups to least-privilege Roles.
resource "aws_eks_access_entry" "rca" {
  count             = local.aiops_enabled ? 1 : 0
  cluster_name      = module.eks.cluster_name
  principal_arn     = aws_iam_role.rca[0].arn
  kubernetes_groups = ["aiops-viewer"]
  type              = "STANDARD"
}

resource "aws_eks_access_entry" "remediate" {
  count             = local.aiops_enabled ? 1 : 0
  cluster_name      = module.eks.cluster_name
  principal_arn     = aws_iam_role.remediate[0].arn
  kubernetes_groups = ["aiops-remediator"]
  type              = "STANDARD"
}

# Wire the alarms in. The message-body filter keeps unrelated notifications (budgets, ECR, health) from invoking them.
resource "aws_sns_topic_subscription" "rca" {
  count               = local.aiops_enabled ? 1 : 0
  topic_arn           = aws_sns_topic.alerts.arn
  protocol            = "lambda"
  endpoint            = aws_lambda_function.rca[0].arn
  filter_policy_scope = "MessageBody"
  filter_policy       = jsonencode({ AlarmName = [{ prefix = "${local.name}-" }], NewStateValue = ["ALARM"] })
}

resource "aws_sns_topic_subscription" "remediate" {
  count               = local.aiops_enabled ? 1 : 0
  topic_arn           = aws_sns_topic.alerts.arn
  protocol            = "lambda"
  endpoint            = aws_lambda_function.remediate[0].arn
  filter_policy_scope = "MessageBody"
  filter_policy       = jsonencode({ AlarmName = [{ prefix = "${local.name}-queue-" }] })
}

resource "aws_lambda_permission" "rca" {
  count         = local.aiops_enabled ? 1 : 0
  statement_id  = "AllowAlertsTopic"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rca[0].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts.arn
}

resource "aws_lambda_permission" "remediate" {
  count         = local.aiops_enabled ? 1 : 0
  statement_id  = "AllowAlertsTopic"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediate[0].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts.arn
}

# Alarms for the AIOps functions themselves: a silent remediator is worse than none.
resource "aws_cloudwatch_metric_alarm" "aiops_errors" {
  for_each = local.aiops_enabled ? { rca = aws_lambda_function.rca[0].function_name, remediate = aws_lambda_function.remediate[0].function_name } : {}

  alarm_name          = "${local.name}-aiops-${each.key}-errors"
  alarm_description   = "The ${each.key} AIOps Lambda is failing."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = each.value }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# --- Chaos engineering with AWS Fault Injection Service (off by default; nothing runs until you start one) ---
data "aws_iam_policy_document" "fis_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["fis.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fis" {
  count              = var.enable_fis ? 1 : 0
  name               = "${local.name}-fis"
  assume_role_policy = data.aws_iam_policy_document.fis_trust.json
}

resource "aws_iam_role_policy_attachment" "fis" {
  for_each   = var.enable_fis ? toset(["AWSFaultInjectionSimulatorEKSAccess", "AWSFaultInjectionSimulatorEC2Access"]) : toset([])
  role       = aws_iam_role.fis[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/${each.value}"
}

resource "aws_eks_access_entry" "fis" {
  count             = var.enable_fis ? 1 : 0
  cluster_name      = module.eks.cluster_name
  principal_arn     = aws_iam_role.fis[0].arn
  kubernetes_groups = ["fis-experiment"]
  type              = "STANDARD"
}

# Experiment 1: delete one API pod. Does the Service keep answering while Kubernetes replaces it?
resource "aws_fis_experiment_template" "api_pod_delete" {
  count       = var.enable_fis ? 1 : 0
  description = "Delete one API pod and watch the error rate"
  role_arn    = aws_iam_role.fis[0].arn

  # Stop at once if the API starts failing for real.
  stop_condition {
    source = var.alb_exists ? "aws:cloudwatch:alarm" : "none"
    value  = var.alb_exists ? aws_cloudwatch_metric_alarm.error_rate_high[0].arn : null
  }

  action {
    name      = "delete-api-pod"
    action_id = "aws:eks:pod-delete"
    parameter {
      key   = "kubernetesServiceAccount"
      value = "fis-experiment"
    }
    parameter {
      key   = "gracePeriodSeconds"
      value = "0"
    }
    target {
      key   = "Pods"
      value = "api-pods"
    }
  }

  target {
    name           = "api-pods"
    resource_type  = "aws:eks:pod"
    selection_mode = "COUNT(1)"
    parameters = {
      clusterIdentifier = module.eks.cluster_name
      namespace         = local.namespace
      selectorType      = "labelSelector"
      selectorValue     = "app.kubernetes.io/name=api"
    }
  }
}

# Experiment 2: terminate one Karpenter-managed node. Do pods reschedule and does Karpenter replace it?
resource "aws_fis_experiment_template" "node_terminate" {
  count       = var.enable_fis ? 1 : 0
  description = "Terminate one Karpenter node"
  role_arn    = aws_iam_role.fis[0].arn

  stop_condition {
    source = var.alb_exists ? "aws:cloudwatch:alarm" : "none"
    value  = var.alb_exists ? aws_cloudwatch_metric_alarm.error_rate_high[0].arn : null
  }

  action {
    name      = "terminate-node"
    action_id = "aws:ec2:terminate-instances"
    target {
      key   = "Instances"
      value = "karpenter-nodes"
    }
  }

  target {
    name           = "karpenter-nodes"
    resource_type  = "aws:ec2:instance"
    selection_mode = "COUNT(1)"
    resource_tag {
      key   = "karpenter.sh/nodepool"
      value = "default"
    }
    filter {
      path   = "State.Name"
      values = ["running"]
    }
  }
}

# --- Cost control ---
resource "aws_budgets_budget" "monthly" {
  count        = var.monthly_budget_usd > 0 ? 1 : 0
  name         = local.name
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Environment$${var.environment}"]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
  }
  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
  }
}

resource "aws_ce_anomaly_monitor" "services" {
  name              = "${local.name}-services"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

resource "aws_ce_anomaly_subscription" "alerts" {
  name             = "${local.name}-cost-anomalies"
  frequency        = "IMMEDIATE"
  monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]

  subscriber {
    type    = "SNS"
    address = aws_sns_topic.alerts.arn
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = ["50"]
    }
  }
}
