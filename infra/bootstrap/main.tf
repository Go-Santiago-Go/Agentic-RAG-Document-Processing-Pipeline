# Bootstrap — run once from a local admin session before any other Terraform work.
#
# This config creates the foundational infrastructure that everything else depends on:
#   1. An S3 bucket to store Terraform remote state (so state is shared and durable)
#      State locking uses S3 native locking (use_lockfile = true, added in Terraform
#      1.10) — no DynamoDB table required. Versioning on the bucket is required for
#      this to work correctly.
#   2. A GitHub OIDC provider + IAM role so CI can authenticate to AWS without
#      storing long-lived access keys as GitHub secrets
#
# Run order:
#   terraform init
#   terraform apply -var="github_org=your-username" -var="github_repo=your-repo"
#
# After applying, copy the github_ci_role_arn output into GitHub → Settings →
# Secrets → AWS_ROLE_ARN, and the tf_state_bucket output into the backend block
# in infra/envs/dev/versions.tf, then run: terraform init in that directory.

terraform {
  # 1.10+ required for native S3 state locking (use_lockfile = true)
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    # The tls provider fetches the GitHub OIDC certificate thumbprint dynamically.
    # GitHub's thumbprint has rotated before — fetching it at apply time means
    # we never have a stale hardcoded value that silently breaks authentication.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Retrieves the AWS account ID of the currently authenticated session.
# Used to make the S3 bucket name unique per account.
data "aws_caller_identity" "current" {}

# ── Remote State Backend ──────────────────────────────────────────────────────

# S3 bucket that stores the Terraform state file for all other configs.
# State holds the mapping between your declarative Terraform code and real AWS resources —
# losing it means Terraform can no longer manage what it created.
resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.project}-tf-state-${data.aws_caller_identity.current.account_id}"

  # Prevents `terraform destroy` from deleting this bucket.
  # If this bucket is deleted while other configs use it as their backend,
  # those configs lose all state and cannot manage their resources.
  lifecycle {
    prevent_destroy = true
  }
}

# Enables versioning so every state file write is preserved.
# If Terraform writes corrupted state, you can roll back to a previous version
# rather than losing track of your entire infrastructure.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Expires noncurrent state file versions after 30 days.
# Versioning is required for state recovery, but without this rule old versions
# accumulate indefinitely — every terraform apply adds one.
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-noncurrent-state"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }
}

# Blocks all public access to the state bucket at the AWS level.
# State files can contain resource IDs and sensitive configuration — this ensures
# no bucket policy or ACL change can accidentally expose them publicly.
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── GitHub OIDC ───────────────────────────────────────────────────────────────

# Fetches the TLS certificate of GitHub's OIDC endpoint at apply time.
# The thumbprint of this certificate is what AWS uses to verify it is talking
# to the real GitHub server when fetching GitHub's public keys — not an impostor.
# We fetch it dynamically because GitHub has rotated this certificate before;
# a hardcoded thumbprint would silently break authentication after a rotation.
data "tls_certificate" "github_oidc" {
  url = "https://token.actions.githubusercontent.com"
}

# Registers GitHub as a trusted identity provider in this AWS account.
# This is the foundational trust relationship that makes OIDC possible —
# without it, AWS has no reason to trust tokens that claim to come from GitHub.
resource "aws_iam_openid_connect_provider" "github" {
  # The OIDC endpoint of the identity provider — GitHub in this case.
  url = "https://token.actions.githubusercontent.com"

  # Defines the expected audience (aud) claim in the JWT.
  # GitHub sets aud to "sts.amazonaws.com" when minting tokens for AWS,
  # telling AWS STS that this token was intended specifically for it.
  client_id_list = ["sts.amazonaws.com"]

  # The SHA1 fingerprint of GitHub's OIDC endpoint TLS certificate.
  # Fetched dynamically from the data source above rather than hardcoded.
  thumbprint_list = [data.tls_certificate.github_oidc.certificates[0].sha1_fingerprint]
}

# Builds the trust policy JSON that controls who can assume the GitHub CI role.
# A trust policy has two parts: the principal (who is trusted) and conditions
# (the constraints that must be met). Without the condition block, any GitHub
# Actions job from any repo on the platform could assume this role.
data "aws_iam_policy_document" "github_oidc_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    # The principal is the OIDC provider, not a specific user or service.
    # This tells AWS to trust identity assertions that come through GitHub's
    # OIDC provider — but only when the conditions below are also satisfied.
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    # Pins trust to the exact repo and branch using the JWT's sub claim.
    # StringEquals (not StringLike) prevents wildcard abuse — a typo like
    # "repo:org/*" with StringLike would let any repo in the org assume this role.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main",
        "repo:${var.github_org}/${var.github_repo}:pull_request",
      ]
    }
  }
}

# The IAM role that GitHub Actions CI assumes during a workflow run.
# The trust policy attached via assume_role_policy defines who can assume it —
# in this case, only GitHub Actions jobs from the specified repo and branch.
# Permission policies (what this role can actually do in AWS) are attached
# separately per workflow in later phases, following least-privilege principles.
resource "aws_iam_role" "github_ci" {
  name               = "${var.project}-github-ci"
  assume_role_policy = data.aws_iam_policy_document.github_oidc_trust.json
}

# Allows CI to initialize the Terraform S3 backend and read/write state.
# PutObject + DeleteObject are required for native S3 locking (use_lockfile = true):
# Terraform writes a .tflock file on lock and deletes it on release.
resource "aws_iam_role_policy" "github_ci_tfstate" {
  name = "${var.project}-github-ci-tfstate"
  role = aws_iam_role.github_ci.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Condition restricts listing to the dev/ prefix — prevents the role from
        # enumerating prod state or any other paths in the bucket.
        Sid      = "TerraformStateBucketList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [aws_s3_bucket.tfstate.arn]
        Condition = {
          StringLike = {
            "s3:prefix" = ["dev/*"]
          }
        }
      },
      {
        # GetObject + PutObject on both the state file and the .tflock file.
        Sid      = "TerraformStateReadWrite"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = ["${aws_s3_bucket.tfstate.arn}/dev/*"]
      },
      {
        # DeleteObject only on the lock file — Terraform never deletes the state file itself.
        Sid      = "TerraformStateLockDelete"
        Effect   = "Allow"
        Action   = ["s3:DeleteObject"]
        Resource = ["${aws_s3_bucket.tfstate.arn}/dev/*.tflock"]
      },
    ]
  })
}