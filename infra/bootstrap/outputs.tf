output "tf_state_bucket" {
  description = "S3 bucket name for Terraform remote state — copy into the backend block in infra/envs/dev/versions.tf"
  value       = aws_s3_bucket.tfstate.id
}

output "github_ci_role_arn" {
  description = "ARN of the IAM role assumed by GitHub Actions CI — add as AWS_ROLE_ARN secret in GitHub repository settings"
  value       = aws_iam_role.github_ci.arn
}