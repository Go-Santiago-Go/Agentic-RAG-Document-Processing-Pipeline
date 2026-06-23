# Dev environment root module — wires all infrastructure modules together.
# For Phase 0 the modules are empty stubs; resources are added phase by phase.
# Each module maps to one AWS subsystem, keeping concerns separated and
# allowing each subsystem to be built, tested, and reviewed independently.

provider "aws" {
  region = var.aws_region
}

# Stores job metadata and status throughout the document processing lifecycle
module "data" {
  source = "../../modules/data"
}

# Static frontend — S3 website bucket served directly to the browser
module "frontend" {
  source = "../../modules/frontend"
}

# Upload and status API — Go Lambda behind API Gateway HTTP API
module "api" {
  source = "../../modules/api"
}

# Event trigger — S3 raw bucket + EventBridge rule that starts the pipeline
module "ingest" {
  source = "../../modules/ingest"
}

# Processing pipeline — Step Functions state machine + task Lambdas
module "pipeline" {
  source = "../../modules/pipeline"
}

# Vector store — S3 Vectors bucket and index for document embeddings
module "vectorstore" {
  source = "../../modules/vectorstore"
}

# Conversational agent — Strands agent on Bedrock AgentCore Runtime
module "agent" {
  source = "../../modules/agent"
}

# Observability — CloudWatch dashboard, alarms, and X-Ray tracing config
module "observability" {
  source = "../../modules/observability"
}
