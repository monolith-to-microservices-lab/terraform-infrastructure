variable "name_prefix" {
  description = "Repository namespace, e.g. mtm."
  type        = string
}

variable "repositories" {
  description = "Repository names (one per built image, not per workload: an API and its CDC consumer share an image)."
  type        = set(string)
}

variable "keep_tagged_images" {
  description = "How many tagged images to keep per repository."
  type        = number
  default     = 15
}

variable "force_delete" {
  description = "Allow destroying repositories that still contain images."
  type        = bool
  default     = false
}

resource "aws_ecr_repository" "this" {
  for_each = var.repositories

  name                 = "${var.name_prefix}/${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the last ${var.keep_tagged_images} tagged images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = var.keep_tagged_images
        }
        action = { type = "expire" }
      },
    ]
  })
}

output "repository_urls" {
  description = "Repository URL per logical name."
  value       = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

output "repository_arns" {
  description = "Repository ARN per logical name."
  value       = { for k, r in aws_ecr_repository.this : k => r.arn }
}
