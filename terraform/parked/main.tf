# # =============================================================================
# # Locals, shared data sources, VPC and EKS.
# # =============================================================================

# data "aws_availability_zones" "available" {
#   state = "available"

#   filter {
#     name   = "opt-in-status"
#     values = ["opt-in-not-required"]
#   }
# }

# data "aws_caller_identity" "current" {}

# locals {
#   name_prefix = "${var.project_name}-${var.environment}"

#   azs = slice(data.aws_availability_zones.available.names, 0, var.availability_zone_count)

#   common_tags = {
#     Project     = var.project_name
#     Environment = var.environment
#     Owner       = var.owner
#     CostCentre  = var.cost_centre
#     ManagedBy   = "terraform"
#     Repository  = "ai-interview-platform"
#   }

#   # /20 private subnets (4094 usable) and /24 public subnets. Pods get VPC IPs
#   # from the private subnets via the VPC CNI, so the private ranges are sized far
#   # larger than the node count suggests: IP exhaustion is the most common way an
#   # EKS cluster stops being able to schedule pods.
#   private_subnets  = [for index in range(var.availability_zone_count) : cidrsubnet(var.vpc_cidr, 4, index)]
#   public_subnets   = [for index in range(var.availability_zone_count) : cidrsubnet(var.vpc_cidr, 8, index + 100)]
#   database_subnets = [for index in range(var.availability_zone_count) : cidrsubnet(var.vpc_cidr, 8, index + 200)]
# }

# # -----------------------------------------------------------------------------
# # VPC
# # -----------------------------------------------------------------------------
# module "vpc" {
#   source  = "terraform-aws-modules/vpc/aws"
#   version = "~> 5.13"

#   name = "${local.name_prefix}-vpc"
#   cidr = var.vpc_cidr
#   azs  = local.azs

#   private_subnets  = local.private_subnets
#   public_subnets   = local.public_subnets
#   database_subnets = local.database_subnets

#   # Private subnets need outbound internet for image pulls and for the AWS APIs
#   # that have no VPC endpoint here.
#   enable_nat_gateway     = true
#   single_nat_gateway     = var.single_nat_gateway
#   one_nat_gateway_per_az = !var.single_nat_gateway

#   enable_dns_hostnames = true
#   enable_dns_support   = true

#   # The database subnet group has no route to a NAT gateway at all: RDS never
#   # needs outbound internet, so it does not get any.
#   create_database_subnet_group       = true
#   create_database_subnet_route_table = true

#   # Flow logs are the only way to answer "why can't this pod reach that?" after
#   # the fact. Retained 30 days to keep CloudWatch costs bounded.
#   enable_flow_log                                 = true
#   create_flow_log_cloudwatch_log_group            = true
#   create_flow_log_cloudwatch_iam_role             = true
#   flow_log_max_aggregation_interval               = 60
#   flow_log_cloudwatch_log_group_retention_in_days = 30

#   # These tags are load-bearing, not decorative: the AWS Load Balancer Controller
#   # discovers subnets by them. Without them an Ingress provisions no ALB and
#   # fails with an unhelpful "unable to discover subnets" event.
#   public_subnet_tags = {
#     "kubernetes.io/role/elb"                         = "1"
#     "kubernetes.io/cluster/${local.name_prefix}-eks" = "shared"
#   }

#   private_subnet_tags = {
#     "kubernetes.io/role/internal-elb"                = "1"
#     "kubernetes.io/cluster/${local.name_prefix}-eks" = "shared"
#     # Lets Karpenter discover these subnets if it is added later.
#     "karpenter.sh/discovery" = "${local.name_prefix}-eks"
#   }

#   tags = local.common_tags
# }

# # -----------------------------------------------------------------------------
# # VPC endpoints.
# #
# # Traffic to S3 and Secrets Manager stays on the AWS network instead of going out
# # through the NAT gateway. This is both a cost decision (NAT data processing
# # charges add up quickly for image pulls and secret reads) and a security one:
# # the endpoint policy is another place to constrain access.
# # -----------------------------------------------------------------------------
# module "vpc_endpoints" {
#   source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
#   version = "~> 5.13"

#   vpc_id = module.vpc.vpc_id

#   endpoints = {
#     # Gateway endpoint: free, and covers ECR layer downloads which are S3-backed.
#     s3 = {
#       service      = "s3"
#       service_type = "Gateway"
#       route_table_ids = concat(
#         module.vpc.private_route_table_ids,
#         module.vpc.database_route_table_ids,
#       )
#       tags = { Name = "${local.name_prefix}-s3-endpoint" }
#     }

#     secretsmanager = {
#       service             = "secretsmanager"
#       private_dns_enabled = true
#       subnet_ids          = module.vpc.private_subnets
#       security_group_ids  = [aws_security_group.vpc_endpoints.id]
#       tags                = { Name = "${local.name_prefix}-secretsmanager-endpoint" }
#     }
#   }

#   tags = local.common_tags
# }

# resource "aws_security_group" "vpc_endpoints" {
#   name        = "${local.name_prefix}-vpc-endpoints"
#   description = "Allow HTTPS from within the VPC to interface endpoints"
#   vpc_id      = module.vpc.vpc_id

#   ingress {
#     description = "HTTPS from inside the VPC"
#     from_port   = 443
#     to_port     = 443
#     protocol    = "tcp"
#     cidr_blocks = [var.vpc_cidr]
#   }

#   tags = merge(local.common_tags, { Name = "${local.name_prefix}-vpc-endpoints" })
# }

# # -----------------------------------------------------------------------------
# # EKS
# # -----------------------------------------------------------------------------
# module "eks" {
#   source  = "terraform-aws-modules/eks/aws"
#   version = "~> 20.26"

#   cluster_name    = "${local.name_prefix}-eks"
#   cluster_version = var.kubernetes_version

#   vpc_id     = module.vpc.vpc_id
#   subnet_ids = module.vpc.private_subnets

#   # The OIDC provider is the foundation of IRSA. Without it, a ServiceAccount
#   # annotation is inert and pods fall back to the node role.
#   enable_irsa = true

#   cluster_endpoint_public_access       = true
#   cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
#   cluster_endpoint_private_access      = true

#   # Control plane logs. `audit` and `authenticator` are the two that matter when
#   # investigating "who changed this?" or "why was this request denied?".
#   cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

#   # Grants the identity running `terraform apply` cluster-admin, so the first
#   # kubectl call works without a manual aws-auth edit.
#   enable_cluster_creator_admin_permissions = true
#   authentication_mode                      = "API_AND_CONFIG_MAP"

#   cluster_addons = {
#     coredns = {
#       # Waits for a node to exist; CoreDNS cannot schedule on an empty cluster.
#       most_recent = true
#     }
#     kube-proxy = {
#       most_recent = true
#     }
#     vpc-cni = {
#       most_recent    = true
#       before_compute = true
#       configuration_values = jsonencode({
#         env = {
#           # Prefix delegation multiplies the IPs available per node, which is
#           # what prevents pod scheduling failures from ENI limits on smaller
#           # instance types.
#           ENABLE_PREFIX_DELEGATION = "true"
#           WARM_PREFIX_TARGET       = "1"
#         }
#       })
#     }
#     aws-ebs-csi-driver = {
#       most_recent              = true
#       service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
#     }
#   }

#   eks_managed_node_group_defaults = {
#     ami_type       = "AL2023_x86_64_STANDARD"
#     disk_size      = var.node_disk_size
#     instance_types = var.node_instance_types
#   }

#   eks_managed_node_groups = {
#     default = {
#       name = "${local.name_prefix}-ng"

#       min_size     = var.node_group_min_size
#       max_size     = var.node_group_max_size
#       desired_size = var.node_group_desired_size

#       instance_types = var.node_instance_types
#       capacity_type  = "ON_DEMAND"

#       # IMDSv2 required and hop limit 1: a compromised pod cannot reach the
#       # instance metadata service to steal the node role's credentials. This is
#       # the control that makes IRSA meaningful rather than decorative.
#       metadata_options = {
#         http_endpoint               = "enabled"
#         http_tokens                 = "required"
#         http_put_response_hop_limit = 1
#       }

#       labels = {
#         workload = "general"
#       }

#       tags = merge(local.common_tags, {
#         "k8s.io/cluster-autoscaler/enabled"                  = "true"
#         "k8s.io/cluster-autoscaler/${local.name_prefix}-eks" = "owned"
#       })
#     }
#   }

#   tags = local.common_tags
# }

# # EBS CSI driver needs its own IRSA role to create and attach volumes.
# module "ebs_csi_irsa" {
#   source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
#   version = "~> 5.47"

#   role_name             = "${local.name_prefix}-ebs-csi"
#   attach_ebs_csi_policy = true

#   oidc_providers = {
#     main = {
#       provider_arn               = module.eks.oidc_provider_arn
#       namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
#     }
#   }

#   tags = local.common_tags
# }
