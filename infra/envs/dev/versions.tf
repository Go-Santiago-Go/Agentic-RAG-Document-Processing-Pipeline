# Dev environment root module — provider and backend configuration.
# This file is evaluated first by Terraform before any other files in this directory.

terraform {
  # 1.10+ required for native S3 state locking (use_lockfile = true)
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state backend — stores the Terraform state file in S3 so it is
  # shared across machines and persisted between sessions

  # Note: backend blocks cannot reference variables — Terraform initializes
  # the backend before variables are evaluated, so the region must be hardcoded.
  backend "s3" {
    bucket       = "agentic-rag-tf-state-646278323015"
    key          = "dev/terraform.tfstate"
    region       = "us-east-1" # hardcoded — variables not allowed in backend blocks
    use_lockfile = true        # native S3 locking, no DynamoDB required (Terraform 1.10+)
  }
}
