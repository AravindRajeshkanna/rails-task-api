module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = local.name
  cidr = var.vpc_cidr
  azs  = local.azs

  # /20 private subnets for pods and nodes (4k addresses each), small public subnets for the ALB and NAT.
  private_subnets = [for index in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, index)]
  public_subnets  = [for index in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, 240 + index)]

  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Subnet tags the AWS Load Balancer Controller and Karpenter discover subnets by.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = local.name
  }

  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_max_aggregation_interval               = 60
  flow_log_cloudwatch_log_group_retention_in_days = 30
}

# Private connectivity to the AWS services the cluster talks to most, so that traffic (and the NAT bill) stays inside the VPC.
module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 6.0"

  vpc_id = module.vpc.vpc_id

  create_security_group      = true
  security_group_name_prefix = "${local.name}-vpce-"
  security_group_rules = {
    ingress_https = {
      description = "HTTPS from the VPC"
      cidr_blocks = [module.vpc.vpc_cidr_block]
    }
  }

  # The gateway endpoint for S3 is free and always there; the interface endpoints are billed per hour in each zone (var.vpc_interface_endpoints).
  endpoints = merge(
    {
      s3 = {
        service         = "s3"
        service_type    = "Gateway"
        route_table_ids = module.vpc.private_route_table_ids
      }
    },
    var.vpc_interface_endpoints ? {
      ecr_api         = { service = "ecr.api", subnet_ids = module.vpc.private_subnets, private_dns_enabled = true }
      ecr_dkr         = { service = "ecr.dkr", subnet_ids = module.vpc.private_subnets, private_dns_enabled = true }
      sts             = { service = "sts", subnet_ids = module.vpc.private_subnets, private_dns_enabled = true }
      kms             = { service = "kms", subnet_ids = module.vpc.private_subnets, private_dns_enabled = true }
      secretsmanager  = { service = "secretsmanager", subnet_ids = module.vpc.private_subnets, private_dns_enabled = true }
      sqs             = { service = "sqs", subnet_ids = module.vpc.private_subnets, private_dns_enabled = true }
      sns             = { service = "sns", subnet_ids = module.vpc.private_subnets, private_dns_enabled = true }
      logs            = { service = "logs", subnet_ids = module.vpc.private_subnets, private_dns_enabled = true }
      bedrock_runtime = { service = "bedrock-runtime", subnet_ids = module.vpc.private_subnets, private_dns_enabled = true }
      xray            = { service = "xray", subnet_ids = module.vpc.private_subnets, private_dns_enabled = true }
    } : {}
  )
}
