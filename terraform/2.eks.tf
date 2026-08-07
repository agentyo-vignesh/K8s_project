# =============================================================================
# EKS — raw resources, no module. Applies after 1.vpc.tf, before 3.rds.tf.
#
#   terraform apply
#   aws eks update-kubeconfig --region ap-south-1 --name ai-interview
# =============================================================================

locals {
  cluster_name = "ai-interview" # must match the kubernetes.io/cluster tags in 1.vpc.tf
  # Verify before changing: aws eks describe-addon-versions --query 'addons[0].addonVersions[0].compatibilities[].clusterVersion'
  cluster_version = "1.36"
}

# -----------------------------------------------------------------------------
# Control plane IAM
# -----------------------------------------------------------------------------

# Only the EKS service may assume this role.
data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${local.cluster_name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
}

# Lets the control plane manage ENIs, subnets and load balancers on your behalf.
resource "aws_iam_role_policy_attachment" "cluster_eks" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# -----------------------------------------------------------------------------
# Cluster
# -----------------------------------------------------------------------------

# All four subnets: private for node ENIs, public so an Ingress can place an ALB.
resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  version  = local.cluster_version
  role_arn = aws_iam_role.cluster.arn

  # false because every addon below is managed explicitly; true would install a
  # second, self-managed copy of coredns/kube-proxy/vpc-cni and they fight.
  bootstrap_self_managed_addons = false

  vpc_config {
    subnet_ids = [
      aws_subnet.Pvt-Subnet-1.id,
      aws_subnet.Pvt-Subnet-2.id,
      aws_subnet.Pub-Subnet.id,
      aws_subnet.Pub-Subnet-2.id,
    ]
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = ["0.0.0.0/0"] # narrow to your office CIDR for anything real
  }

  # bootstrap_... grants the identity running apply cluster-admin; without it the
  # first kubectl call returns "You must be logged in to the server".
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # Billed as CloudWatch ingestion — audit is the verbose one. Drop to [] to save.
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  # Without this the role can lose its policy before the cluster finishes deleting.
  depends_on = [aws_iam_role_policy_attachment.cluster_eks]

  tags = {
    Name       = local.cluster_name
    created_by = "vignesh"
  }
}

# -----------------------------------------------------------------------------
# OIDC provider — the thing that makes IRSA work at all
# -----------------------------------------------------------------------------

# EKS exposes an OIDC issuer URL; IAM needs it registered before it will trust it.
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "oidc" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
}

# -----------------------------------------------------------------------------
# Node IAM
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${local.cluster_name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

# All three are required. Miss the CNI one and nodes join but pods get no IP.
resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# -----------------------------------------------------------------------------
# Node group
# -----------------------------------------------------------------------------

# A launch template is the only way to set metadata_options on a managed node
# group. No image_id, so EKS still supplies the AMI and the nodeadm user data.
resource "aws_launch_template" "node" {
  name_prefix = "${local.cluster_name}-node-"

  block_device_mappings {
    device_name = "/dev/xvda" # AL2023 root device
    ebs {
      volume_size = 20
      volume_type = "gp3"
      encrypted   = true
    }
  }

  # hop_limit 1 stops a compromised pod reaching IMDS to steal the node role.
  # This is the control that makes IRSA meaningful rather than decorative.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name       = "${local.cluster_name}-node"
      created_by = "vignesh"
    }
  }
}

# Private subnets only — nodes reach ECR and STS through the NAT Gateway.
resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "default"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = [aws_subnet.Pvt-Subnet-1.id, aws_subnet.Pvt-Subnet-2.id]

  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = "ON_DEMAND"
  instance_types = ["t3.small"]

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 3
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  # vpc_cni first: a node that boots before the CNI exists sits NotReady.
  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_eks_addon.vpc_cni,
  ]

  lifecycle {
    # The cluster autoscaler owns desired_size once it is running.
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# -----------------------------------------------------------------------------
# Addons — vpc_cni and kube_proxy before nodes, coredns and ebs_csi after
# -----------------------------------------------------------------------------

# Prefix delegation lifts the pod ceiling on t3.small from 11 to ~110.
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    env = {
      ENABLE_PREFIX_DELEGATION = "true"
      WARM_PREFIX_TARGET       = "1"
    }
  })
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

# Needs a node to land on — its 2 replicas stay Pending on an empty cluster.
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.default]
}

# Without this addon a PVC stays Pending forever with no event explaining why.
resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = aws_iam_role.ebs_csi.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.default]
}

# -----------------------------------------------------------------------------
# EBS CSI IRSA role
# -----------------------------------------------------------------------------

# The sub condition is what stops ANY pod in the cluster assuming this role.
data "aws_iam_policy_document" "ebs_csi_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.oidc.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.oidc.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.oidc.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${local.cluster_name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}

# 3.rds.tf opens 5432 to this security group, not to a CIDR.
output "cluster_security_group_id" {
  value = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

# Needed for every IRSA trust policy you write by hand later.
output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.oidc.arn
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ap-south-1 --name ${aws_eks_cluster.main.name}"
}
