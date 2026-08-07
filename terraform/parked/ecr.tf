# # =============================================================================
# # ECR repositories and the S3 bucket for resume storage.
# # =============================================================================

# locals {
#   ecr_repositories = ["middleware", "ai-service", "frontend"]
# }

# resource "aws_ecr_repository" "this" {
#   for_each = toset(local.ecr_repositories)

#   name = "${var.project_name}/${each.value}"

#   # IMMUTABLE in production: a tag can never be repointed at different bytes, so
#   # "which build is running?" always has one answer and a rollback to a known tag
#   # is genuinely a rollback. Mutable in dev, where overwriting a tag during
#   # iteration is convenient.
#   image_tag_mutability = var.environment == "prod" ? "IMMUTABLE" : "MUTABLE"

#   image_scanning_configuration {
#     # Scans on every push; findings surface in ECR and in Security Hub.
#     scan_on_push = true
#   }

#   encryption_configuration {
#     encryption_type = "AES256"
#   }

#   # Only allow deletion of a repository with images in it outside production.
#   force_delete = var.environment != "prod"

#   tags = merge(local.common_tags, { Component = each.value })
# }

# # -----------------------------------------------------------------------------
# # Lifecycle policy.
# #
# # Without one, every image ever built is retained and the bill grows forever.
# # Untagged layers go quickly; tagged images are kept to a fixed depth so a
# # rollback target still exists.
# # -----------------------------------------------------------------------------
# resource "aws_ecr_lifecycle_policy" "this" {
#   for_each = aws_ecr_repository.this

#   repository = each.value.name

#   policy = jsonencode({
#     rules = [
#       {
#         rulePriority = 1
#         description  = "Expire untagged images after 3 days"
#         selection = {
#           tagStatus   = "untagged"
#           countType   = "sinceImagePushed"
#           countUnit   = "days"
#           countNumber = 3
#         }
#         action = { type = "expire" }
#       },
#       {
#         rulePriority = 2
#         description  = "Keep the most recent ${var.ecr_image_retention_count} tagged images"
#         selection = {
#           tagStatus = "tagged"
#           # Matches the CD workflow's date-run-sha tags and its semver tags.
#           tagPrefixList = ["v", "20"]
#           countType     = "imageCountMoreThan"
#           countNumber   = var.ecr_image_retention_count
#         }
#         action = { type = "expire" }
#       },
#     ]
#   })
# }

# # -----------------------------------------------------------------------------
# # Repository policy: only this cluster's node role may pull.
# # -----------------------------------------------------------------------------
# data "aws_iam_policy_document" "ecr_pull" {
#   statement {
#     sid    = "AllowClusterPull"
#     effect = "Allow"

#     principals {
#       type        = "AWS"
#       identifiers = [for group in module.eks.eks_managed_node_groups : group.iam_role_arn]
#     }

#     actions = [
#       "ecr:BatchGetImage",
#       "ecr:GetDownloadUrlForLayer",
#       "ecr:BatchCheckLayerAvailability",
#     ]
#   }
# }

# resource "aws_ecr_repository_policy" "this" {
#   for_each = aws_ecr_repository.this

#   repository = each.value.name
#   policy     = data.aws_iam_policy_document.ecr_pull.json
# }

# # =============================================================================
# # S3: resume storage.
# #
# # This bucket holds candidate CVs, which are personal data. Everything below
# # follows from that: encrypted, versioned, fully private, and access-logged.
# # =============================================================================

# resource "random_id" "bucket_suffix" {
#   # S3 bucket names are globally unique across all AWS accounts, so a
#   # project-environment name alone will eventually collide.
#   byte_length = 4
# }

# resource "aws_s3_bucket" "resumes" {
#   bucket = "${local.name_prefix}-resumes-${random_id.bucket_suffix.hex}"

#   force_destroy = var.environment != "prod"

#   tags = merge(local.common_tags, {
#     Name        = "${local.name_prefix}-resumes"
#     DataClass   = "confidential"
#     ContainsPII = "true"
#   })
# }

# # Blocks every form of public access, including a future bucket policy or ACL
# # that tries to grant it. This is the control that prevents an accidental
# # "public read" from exposing every candidate's CV.
# resource "aws_s3_bucket_public_access_block" "resumes" {
#   bucket = aws_s3_bucket.resumes.id

#   block_public_acls       = true
#   block_public_policy     = true
#   ignore_public_acls      = true
#   restrict_public_buckets = true
# }

# resource "aws_s3_bucket_server_side_encryption_configuration" "resumes" {
#   bucket = aws_s3_bucket.resumes.id

#   rule {
#     apply_server_side_encryption_by_default {
#       sse_algorithm = "AES256"
#     }
#     # Uses the bucket key rather than a per-object KMS call; irrelevant for
#     # SSE-S3 but set explicitly so switching to SSE-KMS later does not multiply
#     # KMS request costs.
#     bucket_key_enabled = true
#   }
# }

# # Versioning turns an accidental delete or overwrite into a recoverable event.
# resource "aws_s3_bucket_versioning" "resumes" {
#   bucket = aws_s3_bucket.resumes.id

#   versioning_configuration {
#     status = "Enabled"
#   }
# }

# resource "aws_s3_bucket_lifecycle_configuration" "resumes" {
#   bucket = aws_s3_bucket.resumes.id

#   depends_on = [aws_s3_bucket_versioning.resumes]

#   rule {
#     id     = "expire-noncurrent-versions"
#     status = "Enabled"

#     filter {}

#     # Versioning without expiry means storage grows without bound.
#     noncurrent_version_expiration {
#       noncurrent_days = 90
#     }

#     abort_incomplete_multipart_upload {
#       days_after_initiation = 7
#     }
#   }
# }

# # Ownership enforced so ACLs are irrelevant and the bucket owner always owns
# # every object.
# resource "aws_s3_bucket_ownership_controls" "resumes" {
#   bucket = aws_s3_bucket.resumes.id

#   rule {
#     object_ownership = "BucketOwnerEnforced"
#   }
# }

# # Deny any request that is not over TLS. Without this, a misconfigured client
# # could transmit a CV in plaintext.
# data "aws_iam_policy_document" "resumes_bucket" {
#   statement {
#     sid    = "DenyInsecureTransport"
#     effect = "Deny"

#     principals {
#       type        = "*"
#       identifiers = ["*"]
#     }

#     actions = ["s3:*"]
#     resources = [
#       aws_s3_bucket.resumes.arn,
#       "${aws_s3_bucket.resumes.arn}/*",
#     ]

#     condition {
#       test     = "Bool"
#       variable = "aws:SecureTransport"
#       values   = ["false"]
#     }
#   }
# }

# resource "aws_s3_bucket_policy" "resumes" {
#   bucket = aws_s3_bucket.resumes.id
#   policy = data.aws_iam_policy_document.resumes_bucket.json

#   # The public access block must exist first, or applying a policy can transiently
#   # widen access.
#   depends_on = [aws_s3_bucket_public_access_block.resumes]
# }
