# =============================================================================
# PostgreSQL on RDS — demo database, not production.
#
# Private subnets, reachable only from the EKS nodes. No Secrets Manager, no
# parameter group, no Multi-AZ, no backups. Read the password with:
#   terraform output -raw db_password
#
# Applies after 2.eks.tf — the security group below references the cluster's SG.
# =============================================================================

# RDS needs two AZs even for a single-AZ instance.
resource "aws_db_subnet_group" "main" {
  name       = "ai-interview-db"
  subnet_ids = [aws_subnet.Pvt-Subnet-1.id, aws_subnet.Pvt-Subnet-2.id]
}

# 5432 from the EKS cluster security group only — a group reference, not a CIDR,
# because node IPs change every time the node group scales.
resource "aws_security_group" "rds" {
  name        = "ai-interview-rds"
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

# 16.14 is the newest 16.x orderable for db.t4g.micro in ap-south-1.
resource "aws_db_instance" "main" {
  identifier     = "ai-interview-postgres"
  instance_class = "db.t4g.micro"
  engine         = "postgres"
  engine_version = "16.14"

  allocated_storage = 20
  storage_encrypted = true

  # Must match middleware/.env.example — Flyway runs as this user on this database.
  db_name  = "ai_interview"
  username = "ai_interview_app"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # The line that keeps it off the internet.
  publicly_accessible = false

  # Demo database: no backups, no snapshot on delete, destroyable in one command.
  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "rds_endpoint" {
  value = aws_db_instance.main.address
}

# Read with: terraform output -raw db_password
output "db_password" {
  value     = random_password.db.result
  sensitive = true
}

# Must run from inside the cluster — the instance has no public address.
output "psql_check" {
  value = <<-EOT
    kubectl run pgcheck --rm -it --restart=Never --image=postgres:16-alpine \
      --env=PGPASSWORD="$(terraform output -raw db_password)" -- \
      psql -h ${aws_db_instance.main.address} -U ${aws_db_instance.main.username} \
           -d ${aws_db_instance.main.db_name} -c 'select version();'
  EOT
}
