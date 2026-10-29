# EKS Pod Identity: each workload's ServiceAccount (the Helm release name, in the task-api namespace) assumes an
# IAM role that grants exactly what that workload needs. No node-wide permissions, no long-lived keys.
# https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html

locals {
  storage_statements = [
    {
      sid       = "StorageObjects"
      effect    = "Allow"
      actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
      resources = ["${aws_s3_bucket.storage.arn}/*"]
    },
    {
      sid       = "StorageBucket"
      effect    = "Allow"
      actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
      resources = [aws_s3_bucket.storage.arn]
    }
  ]

  publish_events = [
    {
      sid       = "PublishEvents"
      effect    = "Allow"
      actions   = ["sns:Publish"]
      resources = [aws_sns_topic.events.arn]
    }
  ]

  workload_statements = {
    # The Task API (web) and its jobs worker: files in S3, domain events to SNS.
    api    = concat(local.storage_statements, local.publish_events)
    worker = concat(local.storage_statements, local.publish_events)

    # The Auth service publishes password-reset events.
    auth = local.publish_events

    # The AI service calls Bedrock: generation through Converse (InvokeModel permission) and Titan embeddings.
    ai = [
      {
        sid     = "BedrockInvoke"
        effect  = "Allow"
        actions = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
        resources = [
          "arn:${data.aws_partition.current.partition}:bedrock:*::foundation-model/*",
          "arn:${data.aws_partition.current.partition}:bedrock:*:${local.account_id}:inference-profile/*"
        ]
      }
    ]

    # The Notification service reads its queue. (SES SMTP credentials come from Secrets Manager.)
    notifications = [
      {
        sid       = "ConsumeQueue"
        effect    = "Allow"
        actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        resources = [aws_sqs_queue.notifications.arn]
      }
    ]
  }
}

module "workload_identity" {
  source   = "terraform-aws-modules/eks-pod-identity/aws"
  version  = "~> 2.0"
  for_each = local.workload_statements

  name                 = "${local.name}-${each.key}"
  attach_custom_policy = true
  policy_statements    = each.value

  associations = {
    main = {
      cluster_name    = module.eks.cluster_name
      namespace       = local.namespace
      service_account = each.key
    }
  }
}

# --- Cluster add-ons ---

module "aws_lb_controller_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name                            = "${local.name}-aws-lb-controller"
  attach_aws_lb_controller_policy = true

  associations = {
    main = { cluster_name = module.eks.cluster_name, namespace = "kube-system", service_account = "aws-load-balancer-controller" }
  }
}

module "external_secrets_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name                                  = "${local.name}-external-secrets"
  attach_external_secrets_policy        = true
  external_secrets_secrets_manager_arns = ["arn:${data.aws_partition.current.partition}:secretsmanager:${var.region}:${local.account_id}:secret:${local.secret_prefix}/*"]

  associations = {
    main = { cluster_name = module.eks.cluster_name, namespace = "external-secrets", service_account = "external-secrets" }
  }
}

# The collector ships traces to X-Ray.
module "otel_collector_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name                 = "${local.name}-otel-collector"
  attach_custom_policy = true
  policy_statements = [
    {
      sid       = "XRay"
      effect    = "Allow"
      actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets", "xray:GetSamplingStatisticSummaries"]
      resources = ["*"]
    }
  ]

  associations = {
    main = { cluster_name = module.eks.cluster_name, namespace = "observability", service_account = "otel-collector" }
  }
}

# KEDA's operator reads the notification queue's length to scale the consumers.
module "keda_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name                 = "${local.name}-keda"
  attach_custom_policy = true
  policy_statements = [
    {
      sid       = "QueueLength"
      effect    = "Allow"
      actions   = ["sqs:GetQueueAttributes"]
      resources = [aws_sqs_queue.notifications.arn]
    }
  ]

  associations = {
    main = { cluster_name = module.eks.cluster_name, namespace = "keda", service_account = "keda-operator" }
  }
}
