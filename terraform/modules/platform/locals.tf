locals {
  name = "${var.project}-${var.environment}"

  # One value, not two matching strings. The cluster name and the
  # kubernetes.io/cluster subnet tags must agree and nothing checks that they do.
  cluster_name = local.name
  namespace    = local.name

  database_secret_name    = "${var.project}/${var.environment}/database"
  application_secret_name = "${var.project}/${var.environment}/application"

  ecr_prefix = "${local.name}-platform"

  # Derived so changing vpc_cidr moves all four rather than needing eight edits.
  public_subnet_cidrs  = [cidrsubnet(var.vpc_cidr, 8, 1), cidrsubnet(var.vpc_cidr, 8, 4)]
  private_subnet_cidrs = [cidrsubnet(var.vpc_cidr, 8, 2), cidrsubnet(var.vpc_cidr, 8, 3)]
}
