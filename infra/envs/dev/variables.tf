variable "aws_region" {
  type        = string
  description = "AWS region for all resources"
  default     = "us-east-1"
}

variable "project" {
  type        = string
  description = "Name of the project"
  default     = "agentic-rag"
}

variable "environment" {
  type        = string
  description = "Name of the environment"
  default     = "dev"
}