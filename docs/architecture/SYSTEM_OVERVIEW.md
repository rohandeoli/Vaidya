# System overview

## Technology stack

### Client layer

| Component | Technology | Notes |
|---|---|---|
| Mobile app | React Native or Flutter | Biometric auth, camera SDK, encrypted local storage |
| Web app | Next.js (PWA) | Drag-and-drop upload, IndexedDB offline cache, print CSS |

### Edge layer

| Component | Technology | Notes |
|---|---|---|
| API Gateway | AWS API Gateway or Kong | JWT validation (RS256), per-user rate limiting, TLS 1.3 |
| CDN | CloudFront or Cloudflare | Static assets only. Never cache PHI. |

### Service layer

| Service | Language | Responsibility |
|---|---|---|
| Doc ingestion | Python / FastAPI | File validation, virus scan, EXIF strip, OCR queue |
| AI orchestration | Python | Prompt assembly, PII masking, safety checks, output validation |
| User service | Node.js / Fastify | Auth, profiles, health context, consent records |
| Report manager | Node.js | FHIR normalisation, biomarker time-series, PDF generation |
| Notifications | Node.js | FCM/APNs push, SES email, Twilio SMS, disclaimer injection |

### AI / ML layer

| Component | Technology | Notes |
|---|---|---|
| Core LLM | Claude API (`claude-sonnet-4-20250514`) | Vision mode for scan images, streaming, structured JSON output |
| OCR | AWS Textract or Google Document AI | Table extraction, confidence scoring per field |
| Embeddings | Cohere `embed-multilingual-v3` | Supports English, Hindi, Tamil in one model |
| Reranker | Cohere `rerank-multilingual-v3` | Cross-encoder, ~150ms latency |
| RAG pipeline | Custom Python + pgvector | Hybrid dense+sparse search, RRF fusion |

### Data layer

| Store | Technology | What lives here |
|---|---|---|
| Primary DB | PostgreSQL 16+ | Users, reports, biomarkers, audit logs |
| Vector store | pgvector extension | User report embeddings + KB embeddings (namespaced) |
| Object storage | AWS S3 or GCS | Raw uploaded files (PDFs, images) — AES-256, pre-signed URLs |
| Cache | Redis / Upstash | Sessions, rate limit counters. **No PHI ever.** |

### Security layer (cross-cutting)

| Component | Technology |
|---|---|
| Transport | TLS 1.3, no fallback |
| At-rest encryption | AES-256 (DB + object storage) |
| Field-level encryption | pgcrypto + AWS KMS |
| PII detection | AWS Comprehend Medical or custom NER |
| Policy engine | Open Policy Agent (OPA) |
| Audit logging | Append-only PostgreSQL + CloudWatch/Datadog |

---

## Component responsibilities in detail

### Doc ingestion service

Receives uploaded files and prepares them for processing.

Steps:
1. Validate file type by magic bytes (not extension — prevents disguised malware)
2. Virus scan with ClamAV
3. Strip EXIF metadata (removes GPS, device identifiers from phone photos)
4. Route to OCR engine for scanned/image files
5. Queue for async processing via SQS or RabbitMQ
6. Store raw file in object storage with AES-256 SSE

Critical rule: Any OCR field extracted with < 85% confidence is flagged and shown to the user for manual confirmation before the AI processes it.

### AI orchestration service

The core of the application. See [`../safety/AI_ORCHESTRATION.md`](../safety/AI_ORCHESTRATION.md) for the full pipeline.

High-level responsibilities:
- Assemble the 6-block prompt from versioned components
- Strip and tokenize PII before any external API call
- Pull user health context and conversation history
- Trigger RAG retrieval pipeline
- Call Claude API with structured output schema
- Validate output for hallucinations, diagnostic language, schema compliance
- De-tokenize response and inject mandatory disclaimers
- Stream response to client

### Report manager service

Handles all report lifecycle management.

- FHIR R4 normalisation — reports from any lab land in the same schema
- Time-series aggregation computed on write (not read) for fast dashboard queries
- Multi-format parser: PDF (text + scanned), HL7 v2, FHIR JSON, CSV
- PDF generation for shareable doctor-visit summaries (WeasyPrint or Puppeteer)

### User service

- OAuth 2.0 + social login (Google, Apple)
- RBAC: user / admin / medical_reviewer / provider roles
- Health context store: age, sex, known conditions, medications, language preference
- Granular consent records (DPDP Act 2023 compliance — one record per processing purpose)

---

## Infrastructure decisions

### Cloud region
Primary: AWS Mumbai (`ap-south-1`) or GCP Mumbai (`asia-south1`).
Reason: Data residency for Indian users under DPDP Act 2023. All PHI must remain in India.

### Compute platform
The API runs on **ECS Fargate** behind an **Application Load Balancer** (the ALB idle timeout, configurable to ~66 min, accommodates long-lived SSE streams). The ingestion worker runs as an **SQS-triggered AWS Lambda** — the event-source mapping is the natural fit for queue-driven OCR work and scales to zero when idle. The worker uses Textract's **async** API so it stays well under Lambda's 15-minute execution limit. App Runner was rejected (weak SSE support, no native SQS-worker model); EKS/EC2 were rejected as overkill for the MVP.

### Networking (VPC)
All resources live in a single VPC (`10.0.0.0/16`) in `ap-south-1`, spanning 2 availability zones with three subnet tiers:
- **public** — only the ALB and the NAT gateway are internet-facing.
- **private (app)** — Fargate tasks and the Lambda worker; outbound-only internet via a single NAT gateway.
- **data** — RDS and Redis, with no internet route at all.

VPC endpoints (S3 gateway; interface endpoints for SQS, Secrets Manager, Textract, ECR, CloudWatch Logs) keep AWS-service traffic off the public internet — only the external Claude and Cohere APIs egress via NAT. A single NAT gateway is used for the MVP (cost tradeoff accepted over one-NAT-per-AZ high availability).

### Async processing
All file processing and AI calls are async. The client receives a job ID immediately and polls (or receives a push notification) when processing is complete. This prevents timeout issues on large scans and slow OCR jobs.

### pgvector vs dedicated vector DB
Start with pgvector inside PostgreSQL. It supports:
- Dense vector search (ANN via IVFFlat or HNSW index)
- Sparse search via PostgreSQL tsvector (BM25)
- Row-level security — same security model as the rest of your data
- No additional infrastructure

Migrate to Pinecone or Weaviate only if you exceed ~10M vectors or need sub-10ms ANN latency at high QPS.

### Streaming
All Claude API calls use streaming (`stream: true`). The client renders tokens as they arrive — explanation first, then biomarker cards, then doctor questions. This makes the app feel fast even when the underlying LLM call takes 3-5 seconds.
