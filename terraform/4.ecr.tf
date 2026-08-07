# =============================================================================
# ECR — one repository per service.
#
# Numbered 4 for consistency only — this depends on nothing and nothing depends
# on it, so it can apply at any point in the sequence.
#
# The elaborate version — lifecycle policies, pull policies, the resume bucket —
# is already written in parked/ecr.tf if you ever want it.
# =============================================================================

# The prefix is "ai-interview-platform", NOT "ai-interview" - the cluster is named
# ai-interview and the two are easy to confuse. Every chart builds its image as
# <imageRegistry>/ai-interview-platform/<service>:<tag>, so a repository created
# under the shorter name shows up as ImagePullBackOff and nothing else.
resource "aws_ecr_repository" "app" {
  for_each = toset(["middleware", "ai-service", "frontend"])

  name = "ai-interview-platform/${each.key}"

  # Demo project: without this, terraform destroy fails on any repository that
  # still holds an image.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "ecr_repository_urls" {
  value = { for name, repo in aws_ecr_repository.app : name => repo.repository_url }
}

output "docker_login" {
  value = "aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin ${aws_ecr_repository.app["middleware"].registry_id}.dkr.ecr.ap-south-1.amazonaws.com"
}
