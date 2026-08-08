# =============================================================================
# VPC — network only.
#
#   cd terraform
#   terraform init
#   terraform plan
#   terraform apply
#
# This file creates the COMPLETE network and nothing else:
#
#   VPC 10.0.0.0/16
#   ├── Pub-Subnet    10.0.1.0/24   ap-south-1a  → Internet Gateway
#   │     └── NAT Gateway
#   ├── Pvt-Subnet-1  10.0.2.0/24   ap-south-1a  → NAT
#   └── Pvt-Subnet-2  10.0.3.0/24   ap-south-1b  → NAT
#
# This file is the network only. 2.eks.tf through 7.github.tf build the rest, and
# all of it applies together — the numbers are for humans, Terraform derives the
# real order from the references between resources.
#
# This file also carries the terraform{} and provider{} blocks for the whole
# directory, because they have to live somewhere and this is what gets read first.
# =============================================================================

terraform {
  required_version = "~> 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    # Used by 3.rds.tf to generate the master password. A module can only declare
    # required_providers once, so it lives here even though nothing in this file
    # uses it.
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

provider "aws" {
  region = "ap-south-1"
}

# -----------------------------------------------------------------------------
# VPC
#
# enable_dns_hostnames / enable_dns_support are required by EKS later. Without
# them nodes fail to join the cluster, and the error does not mention DNS.
# -----------------------------------------------------------------------------
resource "aws_vpc" "my-vpc" {
  cidr_block           = "10.0.0.0/16"
  instance_tenancy     = "default"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "VPC-A"
    Environment = "Dev"
    Project     = "Terraform"
    created_by  = "vignesh"
  }
}

# -----------------------------------------------------------------------------
# Public subnet — holds the NAT Gateway and, later, the load balancer.
#
# The kubernetes.io tags are not decorative: the AWS Load Balancer Controller
# finds subnets by them. Without them an Ingress creates no ALB and reports
# "unable to discover subnets", which reads like a permissions problem.
# -----------------------------------------------------------------------------
resource "aws_subnet" "Pub-Subnet" {
  vpc_id                  = aws_vpc.my-vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-south-1a"
  map_public_ip_on_launch = true

  tags = {
    Name                                 = "App-Subnet"
    Environment                          = "Dev"
    Project                              = "Terraform"
    created_by                           = "vignesh"
    "kubernetes.io/role/elb"             = "1"
    "kubernetes.io/cluster/ai-interview" = "shared"
  }
}

# Second public subnet, second AZ. Two reasons, both hard requirements:
#
#   1. eksctl refuses a cluster with one public subnet — "insufficient number of
#      subnets, at least 2x public and/or 2x private subnets are required".
#   2. The AWS Load Balancer Controller needs two public subnets in two AZs
#      before it will create an internet-facing ALB for the Ingress.
#
# Subnets themselves cost nothing, so there is no reason to run without it.
resource "aws_subnet" "Pub-Subnet-2" {
  vpc_id                  = aws_vpc.my-vpc.id
  cidr_block              = "10.0.4.0/24"
  availability_zone       = "ap-south-1b"
  map_public_ip_on_launch = true

  tags = {
    Name                                 = "App-Subnet-2"
    Environment                          = "Dev"
    Project                              = "Terraform"
    created_by                           = "vignesh"
    "kubernetes.io/role/elb"             = "1"
    "kubernetes.io/cluster/ai-interview" = "shared"
  }
}

# -----------------------------------------------------------------------------
# Private subnets — nodes, pods and RDS go here later.
#
# TWO of them, in TWO different AZs. EKS rejects a single-AZ cluster at creation
# time, and an RDS subnet group also needs two. This is the one thing here that
# cannot be simplified further.
#
# /24 gives 251 usable IPs per subnet. The VPC CNI assigns every pod a real VPC
# IP, so that is the pod ceiling per subnet. Nowhere near binding here: t3.small
# nodes cap out at 11 pods each. The binding limit is the account vCPU quota
# (L-1216C47A), not addresses - a node group that will not scale is usually that,
# and it surfaces only in the ASG StatusMessage.
# -----------------------------------------------------------------------------
resource "aws_subnet" "Pvt-Subnet-1" {
  vpc_id            = aws_vpc.my-vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "ap-south-1a"

  tags = {
    Name                                 = "DB-Subnet-1"
    Environment                          = "Dev"
    Project                              = "Terraform"
    created_by                           = "vignesh"
    "kubernetes.io/role/internal-elb"    = "1"
    "kubernetes.io/cluster/ai-interview" = "shared"
  }
}

resource "aws_subnet" "Pvt-Subnet-2" {
  vpc_id            = aws_vpc.my-vpc.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "ap-south-1b"

  tags = {
    Name                                 = "DB-Subnet-2"
    Environment                          = "Dev"
    Project                              = "Terraform"
    created_by                           = "vignesh"
    "kubernetes.io/role/internal-elb"    = "1"
    "kubernetes.io/cluster/ai-interview" = "shared"
  }
}

# -----------------------------------------------------------------------------
# Internet Gateway — public egress.
# -----------------------------------------------------------------------------
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.my-vpc.id

  tags = {
    Name = "main"
  }
}

# -----------------------------------------------------------------------------
# NAT Gateway — private egress, for image pulls and AWS APIs.
#
# depends_on is deliberate. Without it Terraform can try to create the NAT before
# the Internet Gateway is attached, and the apply fails with a dependency error
# that only appears sometimes.
#
# Costs ~USD 32/month. This is the resource people forget to delete.
# -----------------------------------------------------------------------------
resource "aws_eip" "lb" {
  domain = "vpc"

  tags = {
    Name = "nat-eip"
  }

  depends_on = [aws_internet_gateway.gw]
}

resource "aws_nat_gateway" "ram" {
  allocation_id = aws_eip.lb.id
  subnet_id     = aws_subnet.Pub-Subnet.id

  tags = {
    Name = "gw NAT"
  }

  depends_on = [aws_internet_gateway.gw]
}

# -----------------------------------------------------------------------------
# Route tables
# -----------------------------------------------------------------------------
resource "aws_route_table" "Pub-Route-Table" {
  vpc_id = aws_vpc.my-vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "App-Route-Table"
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
    Name = "DB-Route-Table"
  }
}

# -----------------------------------------------------------------------------
# Associations
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# Outputs — consumed by scripts/bootstrap.sh
#
# There is no eksctl_command output any more. 2.eks.tf creates the cluster, so
# running eksctl would collide on the name or build a second one.
# -----------------------------------------------------------------------------
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

