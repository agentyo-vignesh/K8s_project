# PostgreSQL, private subnets, reachable only from the EKS nodes.
# Applies after 2.eks.tf - the security group references the cluster's SG.

# RDS needs two AZs even for a single-AZ instance.
resource "aws_db_subnet_group" "main" {
  name       = "${local.name}-db"
  subnet_ids = [aws_subnet.Pvt-Subnet-1.id, aws_subnet.Pvt-Subnet-2.id]
}

# A group reference, not a CIDR: node IPs change every time the group scales.
resource "aws_security_group" "rds" {
  name        = "${local.name}-rds"
  description = "PostgreSQL from EKS nodes only"
  vpc_id      = aws_vpc.my-vpc.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.main.vpc_config[0].cluster_security_group_id]
  }

  # No egress: a database has no reason to originate connections.
}

# special = false because RDS rejects / " @ and spaces in a master password.
resource "random_password" "db" {
  length  = 32
  special = false
}

resource "aws_db_instance" "main" {
  identifier     = "${local.name}-postgres"
  instance_class = var.db_instance_class
  engine         = "postgres"
  engine_version = var.db_engine_version

  allocated_storage = var.db_allocated_storage
  storage_encrypted = true

  # Underscores, not hyphens: PostgreSQL rejects a hyphen in an unquoted database
  # or role name.
  db_name  = replace(var.project, "-", "_")
  username = "${replace(var.project, "-", "_")}_app"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # The line that keeps it off the internet.
  publicly_accessible = false

  # All three off in dev, all three on in prod.
  backup_retention_period = var.db_backup_retention_days
  skip_final_snapshot     = var.db_skip_final_snapshot
  deletion_protection     = var.db_deletion_protection

  # Timestamped: AWS keeps final snapshots and rejects a duplicate name, so a
  # second destroy would fail on the name the first one used.
  final_snapshot_identifier = var.db_skip_final_snapshot ? null : "${local.name}-final-${formatdate("YYYYMMDDhhmmss", timestamp())}"

  lifecycle {
    # timestamp() changes every plan; without this every plan shows a diff.
    ignore_changes = [final_snapshot_identifier]
  }
}

output "rds_endpoint" {
  value = aws_db_instance.main.address
}

output "db_password" {
  value     = random_password.db.result
  sensitive = true
}

# Must run inside the cluster - the instance has no public address.
output "psql_check" {
  value = <<-EOT
    kubectl run pgcheck --rm -it --restart=Never --image=postgres:16-alpine \
      --env=PGPASSWORD="$(terraform output -raw db_password)" -- \
      psql -h ${aws_db_instance.main.address} -U ${aws_db_instance.main.username} \
           -d ${aws_db_instance.main.db_name} -c 'select version();'
  EOT
}
