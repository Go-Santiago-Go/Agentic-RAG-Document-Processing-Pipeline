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

variable "github_org" {
  type        = string
  description = "Github username"
  default     = "Go-Santiago-Go"
}

variable "github_repo" {
  type        = string
  description = "Github repository name"
  default     = "Agentic-RAG-Document-Processing-Pipeline"
}
