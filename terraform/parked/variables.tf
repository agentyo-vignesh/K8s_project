# # =============================================================================
# # Input variables.
# #
# # Every variable is either validated or has a safe default. A typo in an
# # environment name should fail at plan time, not produce a resource named
# # "ai-interview-prodd" that nothing references.
# # =============================================================================

# variable "project_name" {
#   description = "Name prefix for every resource"
#   type        = string
#   default     = "ai-interview"

#   validation {
#     # Lowercase alphanumeric with hyphens: the intersection of what S3 bucket
#     # names, IAM role names and Kubernetes labels all accept.
#     condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project_name))
#     error_message = "project_name must be 3-21 characters, lowercase alphanumeric or hyphen, starting with a letter."
#   }
# }

# variable "environment" {
#   description = "Deployment environment"
#   type        = string
#   default     = "dev"

#   validation {
#     condition     = contains(["dev", "staging", "prod"], var.environment)
#     error_message = "environment must be one of: dev, staging, prod."
#   }
# }

# variable "aws_region" {
#   description = "AWS region"
#   type        = string
#   default     = "ap-south-1"
# }

# variable "owner" {
#   description = "Team accountable for these resources; applied as a tag"
#   type        = string
#   default     = "platform-engineering"
# }

# variable "cost_centre" {
#   description = "Cost allocation tag"
#   type        = string
#   default     = "engineering"
# }

# # -----------------------------------------------------------------------------
# # Networking
# # -----------------------------------------------------------------------------
# variable "vpc_cidr" {
#   description = "CIDR block for the VPC"
#   type        = string
#   default     = "10.20.0.0/16"

#   validation {
#     condition     = can(cidrhost(var.vpc_cidr, 0))
#     error_message = "vpc_cidr must be a valid IPv4 CIDR block."
#   }
# }

# variable "availability_zone_count" {
#   description = "Number of AZs to spread subnets across"
#   type        = number
#   default     = 2

#   validation {
#     # Two is the minimum for RDS multi-AZ and for an ALB. Three is the practical
#     # maximum before subnet maths gets wasteful at this VPC size.
#     condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 3
#     error_message = "availability_zone_count must be 2 or 3."
#   }
# }

# variable "single_nat_gateway" {
#   description = <<-EOT
#     Use one NAT Gateway for all private subnets instead of one per AZ.

#     True saves roughly USD 32/month per AZ avoided and is right for dev. It also
#     makes the NAT a single point of failure and an AZ-crossing data charge, so
#     production sets this to false.
#   EOT
#   type        = bool
#   default     = true
# }

# # -----------------------------------------------------------------------------
# # EKS
# # -----------------------------------------------------------------------------
# variable "kubernetes_version" {
#   description = "EKS control plane version"
#   type        = string
#   default     = "1.31"
# }

# variable "node_instance_types" {
#   description = "Instance types for the managed node group"
#   type        = list(string)
#   default     = ["t3.large"]
# }

# variable "node_group_min_size" {
#   description = "Minimum nodes"
#   type        = number
#   default     = 2
# }

# variable "node_group_max_size" {
#   description = "Maximum nodes"
#   type        = number
#   default     = 6
# }

# variable "node_group_desired_size" {
#   description = "Initial node count"
#   type        = number
#   default     = 2
# }

# variable "node_disk_size" {
#   description = "Node root volume size in GiB"
#   type        = number
#   default     = 50
# }

# variable "cluster_endpoint_public_access_cidrs" {
#   description = <<-EOT
#     CIDRs allowed to reach the public Kubernetes API endpoint.

#     Defaults to 0.0.0.0/0 so a training cluster is reachable without a bastion.
#     Narrow this to your office or VPN range for anything real; the API server is
#     the cluster's control plane and does not belong on the open internet.
#   EOT
#   type        = list(string)
#   default     = ["0.0.0.0/0"]
# }

# # -----------------------------------------------------------------------------
# # RDS
# # -----------------------------------------------------------------------------
# variable "db_name" {
#   description = "Initial database name"
#   type        = string
#   default     = "ai_interview"
# }

# variable "db_username" {
#   description = "Master username. The password is generated and stored in Secrets Manager; it is never a variable."
#   type        = string
#   default     = "ai_interview_app"
# }

# variable "db_instance_class" {
#   description = "RDS instance class"
#   type        = string
#   default     = "db.t4g.micro"
# }

# variable "db_allocated_storage" {
#   description = "Initial storage in GiB"
#   type        = number
#   default     = 20
# }

# variable "db_max_allocated_storage" {
#   description = "Upper bound for storage autoscaling in GiB"
#   type        = number
#   default     = 100
# }

# variable "db_engine_version" {
#   description = "PostgreSQL major version"
#   type        = string
#   default     = "16.4"
# }

# variable "db_multi_az" {
#   description = "Synchronous standby in a second AZ. Roughly doubles cost; required for any production database."
#   type        = bool
#   default     = false
# }

# variable "db_backup_retention_days" {
#   description = "Automated backup retention in days. Zero disables backups entirely."
#   type        = number
#   default     = 7

#   validation {
#     condition     = var.db_backup_retention_days >= 1 && var.db_backup_retention_days <= 35
#     error_message = "db_backup_retention_days must be between 1 and 35; disabling backups is not supported by this configuration."
#   }
# }

# variable "db_deletion_protection" {
#   description = "Block `terraform destroy` from deleting the database"
#   type        = bool
#   default     = false
# }

# # -----------------------------------------------------------------------------
# # Application
# # -----------------------------------------------------------------------------
# variable "kubernetes_namespace" {
#   description = "Namespace the application is deployed into; scopes the IRSA trust policy"
#   type        = string
#   default     = "ai-interview-dev"
# }

# variable "ecr_image_retention_count" {
#   description = "Untagged/old images to keep per repository before lifecycle expiry"
#   type        = number
#   default     = 20
# }
