# Network. Applied through environments/<env>, never directly.
#
#   ${var.vpc_cidr}                  dev 10.0.0.0/16, prod 10.1.0.0/16
#   ├── public  x2   .1.0/24 .4.0/24   two AZs, Internet Gateway, NAT
#   └── private x2   .2.0/24 .3.0/24   nodes, pods, RDS
#
# The file numbers are for humans; Terraform derives the real order from the
# references between resources.

terraform {
  # 1.10 or newer: the environments use S3-native state locking, added there.
  required_version = ">= 1.10"

  # A module declares providers; it does not configure them. Region, credentials
  # and default tags belong to the environment that calls it.
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    # Used by 3.rds.tf to generate the master password.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    # Used by 2.eks.tf to read the OIDC issuer thumbprint.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# enable_dns_* are required by EKS. Without them nodes fail to join and the
# error does not mention DNS.
resource "aws_vpc" "my-vpc" {
  cidr_block           = var.vpc_cidr
  instance_tenancy     = "default"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${local.name}-vpc"
  }
}

# Two, in two AZs: EKS rejects a single-AZ cluster and the load balancer
# controller needs two public subnets before it will build an ALB.
#
# The kubernetes.io tags are how the controller finds them. Without them an
# Ingress creates no ALB and reports "unable to discover subnets", which reads
# like a permissions problem. The cluster tag interpolates local.cluster_name so
# it cannot drift from the name 2.eks.tf uses.
resource "aws_subnet" "Pub-Subnet" {
  vpc_id                  = aws_vpc.my-vpc.id
  cidr_block              = local.public_subnet_cidrs[0]
  availability_zone       = var.azs[0]
  map_public_ip_on_launch = true

  tags = {
    Name                                          = "${local.name}-public-1"
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "Pub-Subnet-2" {
  vpc_id                  = aws_vpc.my-vpc.id
  cidr_block              = local.public_subnet_cidrs[1]
  availability_zone       = var.azs[1]
  map_public_ip_on_launch = true

  tags = {
    Name                                          = "${local.name}-public-2"
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

# Nodes, pods and RDS. A /24 gives 251 addresses and the CNI gives every pod a
# real VPC IP, so that is the pod ceiling - but the account vCPU quota
# (L-1216C47A) runs out first, visible only in the ASG StatusMessage.
resource "aws_subnet" "Pvt-Subnet-1" {
  vpc_id            = aws_vpc.my-vpc.id
  cidr_block        = local.private_subnet_cidrs[0]
  availability_zone = var.azs[0]

  tags = {
    Name                                          = "${local.name}-private-1"
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "Pvt-Subnet-2" {
  vpc_id            = aws_vpc.my-vpc.id
  cidr_block        = local.private_subnet_cidrs[1]
  availability_zone = var.azs[1]

  tags = {
    Name                                          = "${local.name}-private-2"
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.my-vpc.id

  tags = {
    Name = "${local.name}-igw"
  }
}

# Private egress, for image pulls and AWS APIs. ~USD 32/month, and the resource
# people forget to delete.
#
# depends_on is deliberate: without it Terraform can start the NAT before the
# Internet Gateway is attached, and the apply fails only sometimes.
resource "aws_eip" "lb" {
  domain = "vpc"

  tags = {
    Name = "${local.name}-nat-eip"
  }

  depends_on = [aws_internet_gateway.gw]
}

resource "aws_nat_gateway" "ram" {
  allocation_id = aws_eip.lb.id
  subnet_id     = aws_subnet.Pub-Subnet.id

  tags = {
    Name = "${local.name}-nat"
  }

  depends_on = [aws_internet_gateway.gw]
}

resource "aws_route_table" "Pub-Route-Table" {
  vpc_id = aws_vpc.my-vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "${local.name}-public-rt"
  }
}

# Both private subnets share one table because they share one NAT Gateway. Split
# into a table each if you ever move to one NAT per AZ.
resource "aws_route_table" "Pvt-Route-Table" {
  vpc_id = aws_vpc.my-vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.ram.id
  }

  tags = {
    Name = "${local.name}-private-rt"
  }
}

resource "aws_route_table_association" "Pub-Route-Table-Association" {
  subnet_id      = aws_subnet.Pub-Subnet.id
  route_table_id = aws_route_table.Pub-Route-Table.id
}

resource "aws_route_table_association" "Pub-Route-Table-Association-2" {
  subnet_id      = aws_subnet.Pub-Subnet-2.id
  route_table_id = aws_route_table.Pub-Route-Table.id
}

resource "aws_route_table_association" "Pvt-Route-Table-Association-1" {
  subnet_id      = aws_subnet.Pvt-Subnet-1.id
  route_table_id = aws_route_table.Pvt-Route-Table.id
}

resource "aws_route_table_association" "Pvt-Route-Table-Association-2" {
  subnet_id      = aws_subnet.Pvt-Subnet-2.id
  route_table_id = aws_route_table.Pvt-Route-Table.id
}

output "vpc_id" {
  value = aws_vpc.my-vpc.id
}

output "public_subnet_ids" {
  value = [aws_subnet.Pub-Subnet.id, aws_subnet.Pub-Subnet-2.id]
}

output "private_subnet_ids" {
  value = [aws_subnet.Pvt-Subnet-1.id, aws_subnet.Pvt-Subnet-2.id]
}

output "nat_gateway_public_ip" {
  value = aws_eip.lb.public_ip
}

# Read by the scripts so they never restate a name.
output "project" {
  value = var.project
}

output "environment" {
  value = var.environment
}

output "region" {
  value = var.region
}

output "namespace" {
  value = local.namespace
}

output "ecr_prefix" {
  value = local.ecr_prefix
}
