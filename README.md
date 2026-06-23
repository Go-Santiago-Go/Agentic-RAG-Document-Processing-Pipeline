# DocRAG — Serverless Document Processing + Agentic RAG on AWS

[![CI](https://github.com/go-santiago-go/Agentic-RAG-Document-Processing-Pipeline/actions/workflows/ci.yml/badge.svg)](https://github.com/go-santiago-go/Agentic-RAG-Document-Processing-Pipeline/actions/workflows/ci.yml)

> Upload a PDF → grounded answers with page citations in under 60 seconds.
> Built end-to-end on AWS: event-driven ingestion pipeline, S3 vector search,
> and a tool-using Strands agent that fact-checks documents against the live web.

**What this proves:** IaC-provisioned agentic RAG — ingestion pipeline, vector search,
tool-use composition, RAGAS evaluation, and full observability — in Go + Python + Terraform.
No click-ops. No hardcoded keys. Eval metrics in CI.

---

## Why each technical decision was made

| Decision | Choice | Why |
|---|---|---|
| Vector store | S3 Vectors | Eliminates the $350+/mo OpenSearch Serverless floor; cosine search at S3 scale with no cluster to manage |
| Pipeline orchestration | Step Functions Standard | Per-step retries, full execution history, no Lambda 15-min timeout risk on large PDFs |
| Agent framework | Strands SDK on AgentCore Runtime | Native Bedrock tool use; managed runtime with built-in tracing and memory |
| Embedding model | Titan Text Embeddings V2 (1024-dim) | In-region — no data egress; dimension matches the immutable S3 Vectors index |
| Upload path | Presigned S3 `PUT` URL | API never handles file bytes; scales to any file size without Lambda memory pressure |
| Auth (CI) | GitHub OIDC → IAM role | No long-lived keys stored as secrets; role permissions scoped to exactly what CI needs |
| Evaluation | RAGAS (faithfulness + relevancy + precision) | Quantified answer quality — the metric that separates a demo from a production system |

---

## Architecture

```
Browser
  │
  ├─ POST /uploads (Go Lambda) ──► S3 raw bucket
  │                                      │ ObjectCreated → EventBridge
  │                                      ▼
  │                              Step Functions
  │                         Extract → Chunk → Embed → Store
  │                              │                    │
  │                         DynamoDB              S3 Vectors
  │                      (PENDING→READY)       (1024-dim cosine)
  │
  ├─ static frontend (S3 website)
  │    PDF.js viewer + chat UI, no build step
  │
  └─ chat ──► Strands agent (AgentCore Runtime)
                    │
                    ├─ retrieve_chunks     — embed query → QueryVectors topK=5 → page citations
                    ├─ web_search          — AgentCore built-in, cross-references live sources
                    └─ rent_affordability  — deterministic calculator; avoids LLM arithmetic errors
```

The Go API never touches file bytes — it returns a short-lived S3 presigned `PUT` URL
and the browser uploads directly to S3.

---

## Stack

**Languages:** Go (upload/status API) · Python (pipeline + agent + eval)

**AWS:** Bedrock (Titan embeddings + Claude generation) · S3 Vectors · Step Functions · Lambda ·
AgentCore Runtime · DynamoDB · API Gateway · EventBridge · CloudWatch · X-Ray

**IaC & CI:** Terraform · GitHub Actions (OIDC — no long-lived keys)

---

## Getting started

### Prerequisites

- Terraform ≥ 1.10, Go ≥ 1.22, Python 3.12, AWS CLI v2
- Bedrock model access enabled for `amazon.titan-embed-text-v2:0` and a Claude model in `us-east-1`

### Bootstrap (one-time, local)

```bash
cd infra/bootstrap
terraform init
terraform apply
# Copy the output role ARN → GitHub repo secret: AWS_ROLE_ARN
```

### Deploy dev environment

```bash
cd infra/envs/dev
terraform init
terraform apply
```

### Tear down after each session

```bash
cd infra/envs/dev && terraform destroy   # keeps cost ~$0
```

---

## Repository layout

```
api/          Go Lambda handlers — POST /uploads, GET /jobs/:id
pipeline/     Python Step Functions tasks — extract, chunk, embed, store
agent/        Strands agent with three tools
eval/         RAGAS offline evaluation harness + sample Q&A set
frontend/     Vanilla JS — PDF.js viewer + chat UI (no build step)
infra/
  bootstrap/  One-time setup: S3 remote state + GitHub OIDC IAM role
  modules/    One Terraform module per AWS subsystem
  envs/dev/   Dev environment root — wires all modules together
```

---

## Build phases

| Phase | Description | Status |
|---|---|---|
| 0 | Repo scaffold · Terraform remote state · GitHub OIDC CI | ✅ |
| 1 | Upload path — presigned URL API · DynamoDB job tracking | |
| 2 | Processing pipeline — Step Functions · extract/chunk/embed/store | |
| 3 | Strands agent with retrieval and page citations | |
| 4 | Agent tools — web search + deterministic calculator | |
| 5 | RAGAS evaluation harness + CI metrics | |
| 6 | Observability · demo polish | |
