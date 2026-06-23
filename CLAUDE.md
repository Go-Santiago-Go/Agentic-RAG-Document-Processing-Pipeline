# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Agentic-RAG Document Processing Pipeline** — Serverless document processing + agentic RAG on AWS. Upload a PDF → Step Functions pipeline extracts → chunks → embeds (Bedrock Titan v2) → stores in S3 Vectors. A Strands agent on Bedrock AgentCore Runtime answers questions with doc citations, web-search fact-checking, and a deterministic financial calculator tool.

Full architecture rationale: `DESIGN.md`. Phased build guide: `BUILD_PLAN.md` (gitignored; ask user for current phase before starting work).

---

## Commands

### Go (api/)
```bash
go build ./...                      # build all packages
go test ./...                       # run all tests
go test ./internal/handlers/...     # run a single package
go vet ./...                        # static analysis
go fmt ./...                        # format (run before every commit)
```

### Python (pipeline/, agent/, eval/)
```bash
python -m pytest                    # run all tests
python -m pytest pipeline/tests/test_chunk.py  # single test file
ruff check .                        # lint
ruff format .                       # format (run before every commit)
```

### Terraform (infra/)
```bash
cd infra/envs/dev
terraform init
terraform validate
terraform fmt -check -recursive     # CI check; run terraform fmt to fix
terraform plan -var-file=dev.tfvars
terraform apply -var-file=dev.tfvars
terraform destroy -var-file=dev.tfvars   # run after every session — keep cost ~$0
```

### CI (GitHub Actions)
Workflows in `.github/workflows/` authenticate via GitHub OIDC (no long-lived AWS keys). CI runs: `terraform fmt -check`, `terraform validate`, `go build ./...`, `pytest`, and the offline RAGAS eval harness.

---

## Architecture

### Data flow
```
Browser → POST /uploads (Go Lambda) → S3 presigned PUT URL
                                        ↓
                                    S3 raw bucket (ObjectCreated)
                                        ↓ EventBridge
                                    Step Functions: Extract → Chunk → Embed → Store
                                        ↓                               ↓
                                    DynamoDB (status: PROCESSING→READY) S3 Vectors index
                                        ↓ (poll via GET /jobs/:id)
Browser ← READY ← frontend polls until done, then opens chat
                                        ↓
                                    Strands agent on AgentCore Runtime
                                        ↓ tool calls
                              retrieve_chunks + web_search + rent_affordability
```

### Components and languages

| Directory | Language | Responsibility |
|---|---|---|
| `api/` | Go | `POST /uploads` (presigned URL + DynamoDB write), `GET /jobs/:id` (status poll). Lambda + API Gateway HTTP API. |
| `pipeline/` | Python | Step Functions task Lambdas: `extract/`, `chunk/`, `embed/`, `store/`, `shared/`. State machine in `statemachine.asl.json`. |
| `agent/` | Python | Strands agent with three tools; deployed to AgentCore Runtime via `.bedrock_agentcore.yaml`. |
| `eval/` | Python | Offline RAGAS harness + sample docs (`eval/sample-docs/`) + Q/A sets. |
| `frontend/` | Vanilla JS | Single `index.html` + `app.js`. No framework, no build step. PDF.js via CDN. Hosted on S3 static website. |
| `infra/` | Terraform | One module per AWS subsystem; `envs/dev` + `envs/prod`; remote state in S3 + DynamoDB lock. |

### Key constraints — get these wrong and you have to recreate resources

- **S3 Vectors index:** `dimension=1024`, `distance=cosine`. **Immutable after creation.** Must match the Titan v2 embedding output dimension used at both ingest and query time.
- **Embedding model:** `amazon.titan-embed-text-v2:0` with `dimensions=1024`. Query-time embedding *must* use the same model and dimension as ingest.
- **S3 Vectors batch limit:** ≤ 500 vectors per `PutVectors` request. Batch in the store task.
- **Vector key format:** `<jobId>#<chunkIndex>`. Each vector's metadata stores `{jobId, page, chunkIndex, text}` so retrieval returns enough to cite without a secondary lookup.
- **DynamoDB `jobs` PK:** `jobId` (UUID). Status lifecycle: `PENDING → PROCESSING → EMBEDDING → READY` (or `FAILED` via the state machine `Catch`).

### Agent tools (three, kept minimal)
1. **`retrieve_chunks(question, jobId)`** — embeds query with Titan v2, `QueryVectors` `topK≈5` with `jobId` metadata filter. Returns chunks + page numbers for citations.
2. **`web_search(query)`** — AgentCore Gateway built-in. Enables cross-referencing doc claims against current sources.
3. **`rent_affordability(annual_salary, monthly_debt=0)`** — deterministic math; exists because LLMs hallucinate arithmetic. Returns 30% rule + 28/36 DTI figures. Framed as rules of thumb, not financial advice.

### Terraform module layout
```
infra/modules/
  frontend/     # S3 static website bucket
  api/          # API Gateway HTTP API + Go Lambda
  ingest/       # raw S3 bucket + EventBridge rule → Step Functions
  pipeline/     # state machine + task Lambdas
  vectorstore/  # S3 Vectors bucket + index
  agent/        # AgentCore Runtime deploy + IAM
  data/         # DynamoDB table
  observability/ # CloudWatch dashboard, alarms, X-Ray
infra/envs/dev|prod/
infra/backend.tf  # S3 remote state + DynamoDB lock
```

---

## Conventions

- **One phase = one PR.** See `BUILD_PLAN.md` for the current phase. Don't start Phase N+1 until Phase N's "done when" passes.
- **Everything Terraform.** No console click-ops for infrastructure.
- **Nothing hardcoded.** Region, model IDs, bucket names, dimensions → Terraform variables.
- **Structured JSON logs everywhere** — include `jobId` and `requestId` in every log line.
- **Go:** follow [Go wiki Code Review Comments](https://go.dev/wiki/CodeReviewComments). Run `go fmt` before committing.
- **Python:** format with `ruff format`, lint with `ruff check` before committing.
- **Conventional Commits:** `feat:`, `chore:`, `ci:`, `docs:`, `fix:` — one commit per phase.
- **Chunking target:** ~500–800 tokens, ~10–15% overlap, with metadata `{jobId, page, chunkIndex, charStart, charEnd}` on every chunk. Page metadata is what makes citation page-jumping work in the frontend.
- **Presigned URLs:** the Go API never touches file bytes — returns a short-lived S3 `PUT` URL scoped to `raw/<jobId>/<filename>`. The browser uploads directly to S3.
- **Extract strategy for the SHED sample doc:** use `pdfplumber` (digital text PDF, free). Textract is the path for scanned docs — keep the task interface identical so swapping is a one-liner.
