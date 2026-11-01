module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.name
  kubernetes_version = var.kubernetes_version

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.api_public_access_cidrs
  endpoint_private_access      = true

  enable_cluster_creator_admin_permissions = true
  access_entries = {
    for index, arn in var.cluster_admin_arns : "admin-${index}" => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  # Envelope encryption of Kubernetes Secrets and control-plane audit logs.
  encryption_config = {
    resources = ["secrets"]
  }
  enabled_log_types                      = ["api", "audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = 30

  addons = {
    coredns                = {}
    kube-proxy             = {}
    metrics-server         = {} # HorizontalPodAutoscaler needs it
    eks-pod-identity-agent = { before_compute = true }
    vpc-cni = {
      before_compute = true
      # Cilium runs in chaining mode on top of the VPC CNI to enforce NetworkPolicy; see deploy/k8s/platform.
      configuration_values = jsonencode({ env = { ENABLE_PREFIX_DELEGATION = "true", WARM_PREFIX_TARGET = "1" } })
    }
    # Container Insights + Fluent Bit: pod logs go to CloudWatch Logs (and EMF lines become metrics).
    amazon-cloudwatch-observability = {
      pod_identity_association = [{
        role_arn        = aws_iam_role.cloudwatch_agent.arn
        service_account = "cloudwatch-agent"
      }]
    }
  }

  # A small on-demand group for what must not move (Karpenter itself, Argo CD, the add-ons). Application pods
  # run on nodes Karpenter provisions, on Spot where it is safe.
  eks_managed_node_groups = {
    system = {
      ami_type       = "AL2023_ARM_64_STANDARD"
      instance_types = var.system_node_instance_types
      min_size       = var.system_node_count
      max_size       = max(3, var.system_node_count)
      desired_size   = var.system_node_count
      labels         = { "node-role" = "system" }
      taints = {
        critical = { key = "CriticalAddonsOnly", value = "true", effect = "NO_SCHEDULE" }
      }
    }
  }

  node_security_group_tags = {
    "karpenter.sh/discovery" = local.name
  }
}

# Karpenter: IAM for the controller (Pod Identity), the node role, and the SQS queue that carries Spot
# interruption and rebalance notices. The controller itself and the NodePools are installed by Argo CD.
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.0"

  cluster_name = module.eks.cluster_name

  node_iam_role_use_name_prefix   = false
  node_iam_role_name              = "${local.name}-karpenter-node"
  create_pod_identity_association = true
  namespace                       = "kube-system"
  service_account                 = "karpenter"
}

data "aws_iam_policy_document" "cloudwatch_agent_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cloudwatch_agent" {
  name               = "${local.name}-cloudwatch-agent"
  assume_role_policy = data.aws_iam_policy_document.cloudwatch_agent_trust.json
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.cloudwatch_agent.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/CloudWatchAgentServerPolicy"
}
