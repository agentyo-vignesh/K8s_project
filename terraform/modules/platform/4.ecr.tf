# One repository per service, per environment.
#
# The prefix is "<project>-<env>-platform", not "<project>-<env>" - the cluster
# has the shorter name and a repository created under it is ImagePullBackOff and
# nothing else.
#
# Isolated per environment so a student can read one environment and see
# everything it owns. Production usually does the opposite: one shared registry,
# so the exact image tested in dev is the one promoted to prod.

resource "aws_ecr_repository" "app" {
  for_each = toset(var.services)

  name         = "${local.ecr_prefix}/${each.key}"
  force_delete = var.ecr_force_delete

  image_scanning_configuration {
    scan_on_push = true
  }
}

output "ecr_repository_urls" {
  value = { for name, repo in aws_ecr_repository.app : name => repo.repository_url }
}

output "image_registry" {
  value = "${aws_ecr_repository.app[var.services[0]].registry_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "docker_login" {
  value = "aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${aws_ecr_repository.app[var.services[0]].registry_id}.dkr.ecr.${var.region}.amazonaws.com"
}
