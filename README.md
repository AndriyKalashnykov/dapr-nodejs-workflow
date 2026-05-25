[![CI](https://github.com/AndriyKalashnykov/dapr-nodejs-workflow/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/AndriyKalashnykov/dapr-nodejs-workflow/actions/workflows/ci.yml)
[![Hits](https://hits.sh/github.com/AndriyKalashnykov/dapr-nodejs-workflow.svg?view=today-total&style=plastic)](https://hits.sh/github.com/AndriyKalashnykov/dapr-nodejs-workflow/)
[![License: MIT](https://img.shields.io/badge/License-MIT-brightgreen.svg)](https://opensource.org/licenses/MIT)
[![Renovate enabled](https://img.shields.io/badge/renovate-enabled-brightgreen.svg)](https://app.renovatebot.com/dashboard#github/AndriyKalashnykov/dapr-nodejs-workflow)

# Dapr Node.js Workflow

A Dapr Workflow demo using the [Dapr JS SDK](https://github.com/dapr/js-sdk) with an Express HTTP API. The app schedules durable workflows that query PostgreSQL through Dapr bindings, with Redis as the workflow state backend.

```mermaid
C4Context
  title System Context — Dapr Node.js Workflow

  Person(user, "API Consumer", "HTTP client calling REST endpoints")
  System(sys, "Dapr Node.js Workflow", "Durable workflow service: schedules workflows that query Postgres via Dapr binding, with Redis-backed state for crash-safe replay")

  Rel(user, sys, "Schedules and polls workflows", "HTTPS / JSON")

  UpdateLayoutConfig($c4ShapeInRow="2")
```

| Component       | Technology                                                                        |
| --------------- | --------------------------------------------------------------------------------- |
| Language        | TypeScript (pinned in `package.json`)                                             |
| Runtime         | Node.js (LTS major pinned in `.nvmrc`)                                            |
| Web framework   | Express                                                                           |
| Workflow engine | Dapr Workflow via `@dapr/dapr` (pinned in `package.json`)                         |
| State store     | Redis (via Dapr state component, image pinned by digest in `docker-compose.yaml`) |
| Data binding    | PostgreSQL (via Dapr binding component, image pinned by digest)                   |
| Container CLI   | Docker or Podman (auto-detected by the Makefile)                                  |
| Testing         | Vitest (unit + integration), shell-driven e2e against the production image        |
| Linting         | ESLint + typescript-eslint, hadolint for Dockerfile, mermaid-cli for diagrams     |
| Formatting      | Prettier                                                                          |
| Security        | gitleaks, Trivy filesystem + image scan, `pnpm audit`, OWASP ZAP DAST             |
| CI/CD           | GitHub Actions, Renovate, act (local CI), cosign keyless image signing            |

## Quick Start

```bash
make deps          # bootstrap mise + install every pinned tool (node, pnpm, act, dapr, gitleaks, hadolint, trivy); check podman + git
make dapr-init     # initialize Dapr (one-time; starts Redis, placement, scheduler)
make up            # start PostgreSQL + Redis via Podman Compose
make start         # build and start API server with Dapr sidecar (foreground)
# -> http://localhost:3000
```

## Prerequisites

Every tool below (except `make`, `podman`, `git`) is pinned in `.mise.toml` / `.nvmrc` and installed in one step by `make deps` (which bootstraps [mise](https://mise.jdx.dev/) if missing).

| Tool                                                               | Pinned in    | Purpose                                              |
| ------------------------------------------------------------------ | ------------ | ---------------------------------------------------- |
| [GNU Make](https://www.gnu.org/software/make/)                     | system       | Build orchestration                                  |
| [mise](https://mise.jdx.dev/)                                      | bootstrapped | Tool version manager — reads `.nvmrc` + `.mise.toml` |
| [Node.js](https://nodejs.org/)                                     | `.nvmrc`     | JavaScript runtime                                   |
| [pnpm](https://pnpm.io/)                                           | `.mise.toml` | Package manager                                      |
| [Dapr CLI](https://docs.dapr.io/getting-started/install-dapr-cli/) | `.mise.toml` | Dapr sidecar management                              |
| [Renovate](https://docs.renovatebot.com/)                          | `.mise.toml` | Local Renovate dry-run via `make renovate`           |
| [act](https://github.com/nektos/act)                               | `.mise.toml` | Run GitHub Actions locally                           |
| [Trivy](https://trivy.dev/)                                        | `.mise.toml` | Filesystem CVE / secret / misconfig scanner          |
| [gitleaks](https://github.com/gitleaks/gitleaks)                   | `.mise.toml` | Secret scanner                                       |
| [hadolint](https://github.com/hadolint/hadolint)                   | `.mise.toml` | Dockerfile linter, invoked by `make lint`            |
| [Podman](https://podman.io/)                                       | system       | Container runtime for PostgreSQL/Redis               |
| [Git](https://git-scm.com/)                                        | system       | Version control                                      |

> Exact pinned versions live in the source-of-truth files (`.nvmrc`, `.mise.toml`, `package.json`, `docker-compose.yaml`, `Dockerfile`). Renovate keeps them up to date automatically.

Install all required dependencies:

```bash
make deps
```

## Architecture

### Container View

```mermaid
C4Container
  title Container View — Dapr Node.js Workflow

  Person(user, "API Consumer")

  System_Boundary(sys, "Dapr Node.js Workflow") {
    Container(api, "Express API", "Node.js, TypeScript, Express", "REST endpoints; hosts the WorkflowRuntime and activity handlers")
    Container(sidecar, "Dapr Sidecar", "daprd", "Workflow engine, component bindings, state store client")
    ContainerDb(redis, "Redis", "Redis", "Dapr state store — durable workflow state for replay on restart")
    ContainerDb(postgres, "PostgreSQL", "PostgreSQL", "Queried by fetchPostgresDataActivity via Dapr binding")
  }

  Rel(user, api, "Schedule / poll workflow", "HTTPS / JSON")
  Rel(api, sidecar, "Workflow client + runtime (gRPC :50001)<br/>Binding invocation from activities (HTTP :3500)", "")
  Rel(sidecar, redis, "Persist workflow state", "TCP :6379")
  Rel(sidecar, postgres, "bindings.postgres", "TCP :5432")

  UpdateLayoutConfig($c4ShapeInRow="3")
```

- **Express API** + **WorkflowRuntime** run in the same Node process. The API handlers are thin — they schedule workflows via `DaprWorkflowClient` over gRPC, and the sidecar's scheduler streams activity work items back to the runtime over the same gRPC connection.
- **Dapr Sidecar** (`daprd`) is the orchestrator. The runtime version is pinned via `DAPR_RUNTIME_VERSION` in the `Makefile` (Renovate-tracked). All state persistence, activity dispatch, and component I/O go through it.
- **Redis** stores durable workflow state. Killing the app container mid-run and restarting it replays the workflow from Redis-persisted state — verified end-to-end by `make e2e-durability`.
- **PostgreSQL** is _not_ used directly by the app. The `fetchPostgresDataActivity` POSTs a SQL query to the sidecar's binding HTTP API; the sidecar resolves it via the `bindings.postgres` component and returns rows. See [ADR-0001: Query PostgreSQL via Dapr binding](docs/adr/0001-postgres-via-dapr-binding.md) for the rationale.

### Workflow Sequence — `POST /process-payload` through `GET /workflow/:id/status`

```mermaid
sequenceDiagram
  autonumber
  participant U as API Consumer
  participant A as Express API<br/>(+ WorkflowRuntime)
  participant D as Dapr Sidecar
  participant P as PostgreSQL

  U->>+A: POST /process-payload
  A->>+D: scheduleNewWorkflow (gRPC)
  D-->>-A: workflow id
  A-->>-U: 202 { id }

  rect rgb(245,245,245)
    Note over D,A: Async activity dispatch via gRPC streaming
    D->>A: delayActivity(ms)
    A-->>D: ok
    D->>A: modifyPayloadActivity(payload)
    A-->>D: enriched payload
    D->>A: fetchPostgresDataActivity
    A->>D: POST /v1.0/bindings/postgres-db
    D->>+P: SELECT * FROM users
    P-->>-D: rows
    D-->>A: rows
    A-->>D: dbData
  end

  Note over D: Workflow state persisted to Redis after each activity

  U->>+A: GET /workflow/:id/status
  A->>+D: getWorkflowState (gRPC)
  D-->>-A: runtime status + output
  A-->>-U: 200 { status, output }
```

The `delayActivity` step defaults to 30 s (simulating a long-running request); tests and `e2e-dapr` override it to 0 via the request body. While a workflow is mid-flight, `GET /workflow/:id/status` returns `RUNNING`; once all activities complete, the same endpoint returns `COMPLETED` with the enriched JSON payload.

### Workflow Durability — Replay After Crash

Validated end-to-end by `make e2e-durability`: the workflow is scheduled with a 15 s delay, the app container is killed mid-flight, restarted, and the workflow still completes with the full enriched payload (including the Postgres binding result) — replayed from Redis-persisted state.

```mermaid
sequenceDiagram
  autonumber
  participant U as Test Driver
  participant A as Express API<br/>(killed, then restarted)
  participant D as Dapr Sidecar<br/>(survives restart)
  participant R as Redis

  U->>A: POST /process-payload { delayMs: 15000 }
  A->>D: scheduleNewWorkflow
  D->>R: persist workflow state
  D-->>A: workflow id
  A-->>U: 202 { id }

  D->>A: delayActivity(15000)
  Note over A: ⏱  activity in flight

  rect rgb(255,235,235)
    Note over U,A: Test kills the app container at t≈5s
    U-x A: docker kill
  end

  rect rgb(235,250,235)
    Note over U,A: Test restarts the app container — sidecar untouched
    U->>A: docker run (same image)
    A->>D: re-register WorkflowRuntime (gRPC)
  end

  Note over D,R: Sidecar resumes from Redis state, replays remaining activities
  D->>A: delayActivity (resumed)
  A-->>D: ok
  D->>A: modifyPayloadActivity
  A-->>D: enriched payload
  D->>A: fetchPostgresDataActivity
  A->>D: POST /v1.0/bindings/postgres-db
  D-->>A: dbData
  A-->>D: dbData
  D->>R: persist final state

  U->>A: GET /workflow/:id/status
  A->>D: getWorkflowState
  D-->>A: COMPLETED + output (processed:true, dbData)
  A-->>U: 200 { status: "COMPLETED", output }
```

The Dapr sidecar is left running across the kill — only the app container is replaced. This mirrors the production failure mode where an app pod crashes and is rescheduled while the sidecar (or its replacement) keeps Redis state durable.

### Service Ports

All ports are exposed as Makefile variables (`make var=value` overrides for non-default deployments) and matching `*_PORT` env vars.

| Service        | Default | Variable              | Protocol | Purpose                                           |
| -------------- | ------- | --------------------- | -------- | ------------------------------------------------- |
| Express API    | 3000    | `PORT`                | HTTP     | REST endpoints                                    |
| Dapr sidecar   | 3500    | `DAPR_HTTP_PORT`      | HTTP     | Binding calls from activities                     |
| Dapr sidecar   | 50001   | `DAPR_GRPC_PORT`      | gRPC     | WorkflowClient / WorkflowRuntime                  |
| Dapr scheduler | 50006   | `DAPR_SCHEDULER_PORT` | gRPC     | Workflow scheduling                               |
| PostgreSQL     | 5432    | `POSTGRES_PORT`       | TCP      | Database backend                                  |
| Redis          | 6379    | `REDIS_PORT`          | TCP      | Dapr state store                                  |
| Test image     | 3100    | `TEST_HOST_PORT`      | HTTP     | Host port the prod image binds for `e2e` / `dast` |

The host portion of every URL is `$(HOST)` (default `localhost`), also overridable. The e2e shell scripts (`e2e/e2e-dapr.sh`, `e2e/e2e-durability.sh`) pick free ports from the kernel's ephemeral range when `APP_PORT`/`DAPR_*_PORT` aren't already set, so parallel runs don't collide.

### Project Layout

```text
src/
  api-server.ts              Entrypoint: imports app, calls listen, wires SIGINT
  app.ts                     Express app, lazy-init Dapr workflow client (exported for tests)
  data-request-workflow.ts   Workflow definition and activities
  __tests__/
    *.test.ts                Unit tests (Vitest + supertest)
    *.integration.test.ts    Integration tests (require running Dapr stack)
e2e/
  e2e-dapr.sh                Full-stack e2e: production image + Dapr sidecar
  e2e-durability.sh          Durability e2e: kill app mid-flight, assert resume
components/                  Dapr component configs (local dev)
dapr/ci/                     Dapr component configs (CI)
db/                          SQL schema and seed data
docker-compose.yaml          PostgreSQL + Redis for local development
```

## Usage

### Run with Dapr

```bash
# Terminal 1 -- start infrastructure and server
make up            # start PostgreSQL + Redis via Podman Compose
make start         # build and start API server with Dapr sidecar (foreground)

# Terminal 2 -- verify
make check-db      # run database health check workflow
make check-workflow # trigger a test workflow and poll the result
```

### Run without Dapr (HTTP health check only)

```bash
make start-no-dapr
curl http://localhost:3000/
```

### Stop

```bash
make stop          # stop Dapr sidecar and API server
make down          # stop PostgreSQL + Redis containers
```

## API

| Method | Path                   | Description                                                                                          |
| ------ | ---------------------- | ---------------------------------------------------------------------------------------------------- |
| `GET`  | `/`                    | Health check                                                                                         |
| `POST` | `/process-payload`     | Schedule a new workflow; returns `{ id }` (202). Empty body returns 400. Optional `delayMs` in body. |
| `GET`  | `/workflow/:id/status` | Poll workflow state; `output` present when `status == "COMPLETED"`. Unknown id returns 404.          |
| `GET`  | `/db-health`           | Schedule a workflow and wait up to 10s for DB result                                                 |

### Example: trigger a workflow

Capture the generated workflow id into a shell variable so every subsequent poll reuses it:

```bash
# Schedule and capture the id in one shot
WF_ID=$(curl -s -X POST http://localhost:3000/process-payload \
  -H "Content-Type: application/json" \
  -d '{"name": "John Doe", "data": {"key1": "value1"}}' \
  | jq -r .id)

echo "$WF_ID"
# -> 82236756-4f38-4b5f-9796-a1268184561e

# Poll (while the 30s delay activity is running)
curl -s "http://localhost:3000/workflow/$WF_ID/status" | jq .
```

While running:

```json
{
  "id": "82236756-4f38-4b5f-9796-a1268184561e",
  "status": "RUNNING",
  "createdAt": "2026-04-16T16:34:44.118Z",
  "lastUpdatedAt": "2026-04-16T16:34:47.139Z"
}
```

After completion (`output` is present):

```json
{
  "id": "82236756-4f38-4b5f-9796-a1268184561e",
  "status": "COMPLETED",
  "output": "{\"name\":\"John Doe\",\"processed\":true,...}",
  "createdAt": "2026-04-16T16:34:44.118Z",
  "lastUpdatedAt": "2026-04-16T16:35:21.199Z"
}
```

Poll until done using the same variable:

```bash
until curl -s "http://localhost:3000/workflow/$WF_ID/status" | jq -e '.status == "COMPLETED"' > /dev/null; do
  sleep 2
done
curl -s "http://localhost:3000/workflow/$WF_ID/status" | jq .
```

## Build & Package

| Stage               | Command            | Output                                                                    | Notes                                                                                    |
| ------------------- | ------------------ | ------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Compile TS          | `make build`       | `dist/*.js` + sourcemaps                                                  | Invoked by `make smoke`, `make image-build`, and the CI `build` job                      |
| Container           | `make image-build` | Local Docker image `dapr-nodejs-workflow:<tag>` (multi-stage, distroless) | Stage 1 deps → Stage 2 build → Stage 2b prod-deps → Stage 3 distroless `nonroot` runtime |
| Filesystem CVE scan | `make trivy-fs`    | Trivy report (CRITICAL/HIGH blocking)                                     | Part of `make static-check`; CI runs the same in the `static-check` job                  |
| Image CVE scan      | (CI only)          | Trivy `aquasecurity/trivy-action` report                                  | Runs in the `docker` job before any push, blocks on CRITICAL/HIGH                        |

The image is signed with [cosign](https://github.com/sigstore/cosign) keyless OIDC by digest at tag-push time only — see [CI/CD § Pre-push image hardening](#pre-push-image-hardening) below.

### Testing

#### Unit Tests

```bash
make test          # run Vitest unit tests (activity logic + supertest HTTP)
make test-watch    # run unit tests in watch mode
```

#### Integration Tests

Integration tests require the full Dapr stack (PostgreSQL + Redis + Dapr sidecar):

```bash
# Terminal 1
make up            # start PostgreSQL + Redis
make start         # start API server with Dapr

# Terminal 2
make integration-test
```

#### End-to-end Tests

`make e2e` runs the production Docker image standalone and verifies the Dapr-unreachable error path (shallow e2e, no sidecar). `make e2e-dapr` builds the image and runs it alongside a real Dapr sidecar to assert a workflow COMPLETES end-to-end. `make e2e-durability` additionally kills the app container mid-flight and asserts the workflow resumes from Redis-persisted state.

#### Run CI Locally

```bash
make ci            # run static-check, test, build locally
make ci-run        # run GitHub Actions workflow locally via act (requires Docker)
```

> The `integration-test` GitHub Actions job uses service containers not supported by `act`. Test integration locally with the steps above.

## Available Make Targets

Run `make help` to see all targets in one list.

### Setup & Dependencies

| Target         | Description                                                                                                                                                |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `make help`    | List all available tasks                                                                                                                                   |
| `make deps`    | Bootstrap mise (once) and install every pinned tool (node from `.nvmrc`; pnpm, act, dapr, gitleaks, hadolint, trivy from `.mise.toml`); check podman + git |
| `make install` | Install npm dependencies (uses `--frozen-lockfile` when `CI=true`)                                                                                         |
| `make clean`   | Remove build artifacts and node_modules                                                                                                                    |

### Build & Quality

| Target                  | Description                                                                                                         |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `make build`            | Build TypeScript to `dist/`                                                                                         |
| `make format`           | Auto-fix formatting with Prettier                                                                                   |
| `make format-check`     | Check formatting without modifying files                                                                            |
| `make lint`             | Run Prettier check, ESLint, TypeScript noEmit, and hadolint                                                         |
| `make vulncheck`        | Audit dependencies for known vulnerabilities                                                                        |
| `make secrets`          | Scan for hardcoded secrets with gitleaks                                                                            |
| `make trivy-fs`         | Scan filesystem for vulnerabilities, secrets, and misconfigurations                                                 |
| `make deps-prune`       | Show unused/redundant Node.js dependencies                                                                          |
| `make deps-prune-check` | Verify no prunable dependencies (CI gate)                                                                           |
| `make components-check` | Drift gate: fails if `components/*.yaml` and `dapr/ci/*.yaml` differ beyond password/comments                       |
| `make mermaid-lint`     | Validate Mermaid diagrams in `README.md` + `CLAUDE.md` via pinned `minlag/mermaid-cli`                              |
| `make static-check`     | Composite quality gate (lint + vulncheck + secrets + trivy-fs + deps-prune-check + components-check + mermaid-lint) |

### Test

| Target                  | Description                                         |
| ----------------------- | --------------------------------------------------- |
| `make test`             | Run unit tests                                      |
| `make test-watch`       | Run unit tests in watch mode                        |
| `make integration-test` | Run integration tests (requires running Dapr stack) |
| `make smoke`            | HTTP smoke test against built server (no Dapr)      |

### Infrastructure

| Target                | Description                                                              |
| --------------------- | ------------------------------------------------------------------------ |
| `make dapr-init`      | Initialize Dapr in local environment (stops conflicting Redis if needed) |
| `make up`             | Start PostgreSQL and Redis via Podman Compose                            |
| `make down`           | Stop infrastructure services and remove containers                       |
| `make postgres-start` | Start PostgreSQL in Podman                                               |
| `make postgres-stop`  | Stop PostgreSQL Podman container                                         |

### Run & Verify

| Target                | Description                                         |
| --------------------- | --------------------------------------------------- |
| `make start`          | Build and start the API server with Dapr sidecar    |
| `make stop`           | Stop the Dapr sidecar and API server                |
| `make start-no-dapr`  | Build and start the API server without Dapr sidecar |
| `make run`            | Alias for `start-no-dapr`                           |
| `make check-workflow` | Trigger a test workflow and print the result        |
| `make check-db`       | Run the database health check endpoint              |

### CI & Release

| Target                        | Description                                                                                                 |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `make check`                  | Run full local verification (static-check, test, build; static-check runs lint which runs prettier --check) |
| `make ci`                     | Run local CI pipeline (static-check, test, build; static-check runs lint which runs prettier --check)       |
| `make ci-run`                 | Run GitHub Actions workflow locally via [act](https://github.com/nektos/act)                                |
| `make ci-run-tag`             | Run GitHub Actions workflow locally with a tag event (exercises docker job)                                 |
| `make release VERSION=vX.Y.Z` | Validate VERSION format, then run `tag-release` to commit, tag, and push                                    |

> The `ci-seed-db`, `ci-dapr-start`, `docker-smoke-test`, `dast-scan`, `docker-verify-manifest`, `check-version`, and `tag-release` targets are internal helpers — `tag-release` and `check-version` are invoked transitively via `make release`; the `ci-*` and `docker-*` targets are called exclusively from CI (service-container provisioning, pre-push image gating, and multi-arch manifest verification). They are not intended for direct local use — use `make up` + `make start` locally and `make release VERSION=vX.Y.Z` for tagging.

### Docker & Image

| Target                | Description                                                                                            |
| --------------------- | ------------------------------------------------------------------------------------------------------ |
| `make image-build`    | Build the production Docker image (multi-stage)                                                        |
| `make image-run`      | Run the Docker image standalone (no Dapr)                                                              |
| `make image-stop`     | Stop the running image container                                                                       |
| `make e2e`            | Shallow e2e: production image standalone, verifies the Dapr-unreachable error path                     |
| `make e2e-dapr`       | Full-stack e2e: production image + Dapr sidecar, asserts a workflow COMPLETES end-to-end               |
| `make e2e-durability` | Workflow replay e2e: kills the app mid-flight, asserts the workflow resumes from Redis-persisted state |
| `make dast`           | ZAP baseline DAST scan against the built image                                                         |

### Utilities

| Target                   | Description                                               |
| ------------------------ | --------------------------------------------------------- |
| `make update`            | Update dependencies to latest allowed versions            |
| `make upgrade`           | Upgrade dependencies to latest versions (ignoring ranges) |
| `make renovate`          | Run Renovate locally in dry-run mode                      |
| `make renovate-validate` | Validate Renovate configuration                           |

## CI/CD

GitHub Actions runs on every push to `main`, version tags (`v*`), and pull requests. The workflow is reusable via `workflow_call`.

| Job                  | Depends on                         | Steps                                                                                                                                                                                                                                                                                                                                                     |
| -------------------- | ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **changes**          | —                                  | `dorny/paths-filter` detector — emits `code=true` for code changes, `code=false` for doc-only (`*.md`, `docs/**`, image assets; `CLAUDE.md` is re-included as project config). All heavy jobs gate on this output, so doc-only PRs skip them and `ci-pass` reports green via skipped-jobs. Replaces trigger-level `paths-ignore` (Rulesets-incompatible). |
| **static-check**     | changes                            | `make static-check` (Prettier check, ESLint, `tsc --noEmit`, hadolint, `pnpm audit`, gitleaks, Trivy fs scan, depcheck, components-check, mermaid-lint)                                                                                                                                                                                                   |
| **build**            | changes, static-check              | `make build` + `make smoke` (HTTP smoke test against the built server)                                                                                                                                                                                                                                                                                    |
| **test**             | changes, static-check              | `make test` (Vitest unit tests — activity logic, `checkPort`, supertest HTTP)                                                                                                                                                                                                                                                                             |
| **e2e**              | changes, build, test               | `make e2e` (shallow: standalone image, validates health endpoint + Dapr-unreachable error path)                                                                                                                                                                                                                                                           |
| **e2e-dapr**         | changes, build, test               | `make ci-seed-db` + build image + `./e2e/e2e-dapr.sh` (production image alongside `dapr run` sidecar, asserts workflow COMPLETES). Skipped under act.                                                                                                                                                                                                     |
| **integration-test** | changes, build, test               | `make ci-seed-db`, `make build`, `make ci-dapr-start`, `make integration-test` (PostgreSQL service container + Dapr CLI pinned via `.mise.toml`). Skipped under act.                                                                                                                                                                                      |
| **e2e-durability**   | changes, build, test               | `make ci-seed-db` + build image + `./e2e/e2e-durability.sh` (schedules a workflow with a 15s delay, kills the app container mid-flight, restarts it, asserts COMPLETED from Redis-persisted state). Skipped under act.                                                                                                                                    |
| **dast**             | changes, build, test               | Build image via `cache-from: type=gha`, `make docker-smoke-test`, cached ZAP image, `make dast-scan`, upload report artifact. Skipped under act.                                                                                                                                                                                                          |
| **docker**           | changes, static-check, build, test | Runs every push in parallel with `e2e`/`dast`; gates 1–4 (build + Trivy + smoke + multi-arch build) always run, registry push + cosign signing are tag-gated (`v*`) at step level                                                                                                                                                                         |
| **ci-pass**          | all of the above                   | Gate job: fails if any upstream job failed                                                                                                                                                                                                                                                                                                                |

### Pre-push image hardening

The `docker` job runs the following gates **before** any image is pushed to GHCR. Any gate failure blocks the release.

| #   | Gate                                          | Catches                                                                                     | Tool                                          |
| --- | --------------------------------------------- | ------------------------------------------------------------------------------------------- | --------------------------------------------- |
| 1   | Build local single-arch image                 | Build regressions on the runner architecture                                                | `docker/build-push-action` with `load: true`  |
| 2   | **Trivy image scan** (CRITICAL/HIGH blocking) | CVEs in the base image, OS packages, build layers                                           | `aquasecurity/trivy-action` with `image-ref:` |
| 3   | **Smoke test**                                | Image boots correctly on its own (Node.js boot-marker grep)                                 | `make docker-smoke-test`                      |
| 4   | Multi-arch build + push                       | Publishes for `linux/amd64` and `linux/arm64`                                               | `docker/build-push-action`                    |
| 5   | **Multi-arch manifest verification**          | Asserts image index has both platforms and no `unknown/unknown` (catches attestation leaks) | `make docker-verify-manifest`                 |
| 6   | **Cosign keyless OIDC signing**               | Sigstore signature on the manifest digest                                                   | `sigstore/cosign-installer` + `cosign sign`   |

The `dast` job runs in parallel with the `docker` job and performs an additional security scan:

| Gate                        | Catches                                          | Tool                                                                                                   |
| --------------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------ |
| **OWASP ZAP baseline scan** | Missing security headers, misconfigs, info leaks | `make dast-scan` ([OWASP ZAP](https://www.zaproxy.org/) `-I` = warn only, report uploaded as artifact) |

Buildkit in-manifest attestations (`provenance` + `sbom`) are disabled so the image index stays free of `unknown/unknown` platform entries, which lets GHCR's Packages UI render the "OS / Arch" tab for the multi-arch manifest. Cosign keyless signing still provides the Sigstore signature for supply-chain verification.

Verify a published image's signature:

```bash
cosign verify ghcr.io/andriykalashnykov/dapr-nodejs-workflow:<tag> \
  --certificate-identity-regexp 'https://github\.com/AndriyKalashnykov/dapr-nodejs-workflow/\.github/workflows/ci\.yml@refs/tags/v.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

The `cleanup-runs.yml` workflow runs weekly to delete old workflow runs and stale caches via the native `gh` CLI.

[Renovate](https://docs.renovatebot.com/) keeps dependencies up to date with platform automerge enabled. Tool versions pinned in the `Makefile` are tracked via inline `# renovate:` comments.

### Required Secrets and Variables

| Name  | Type     | Used by                                     | How to set                                                                                                                                                                                                                                                                            |
| ----- | -------- | ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ACT` | Variable | `integration-test`, `e2e-dapr`, `dast` jobs | Set to `true` under [nektos/act](https://github.com/nektos/act) to skip jobs that need service containers or docker-in-docker bind mounts (`integration-test`, `e2e-dapr`, `dast`). Set via **Settings > Secrets and variables > Actions > Variables tab > New repository variable**. |

`GITHUB_TOKEN` is provisioned automatically by GitHub Actions; no manual setup is needed.

## Contributing

Contributions welcome — open a PR.

## References

- [Dapr Concepts](https://docs.dapr.io/concepts/)
- [Dapr Workflows](https://docs.dapr.io/developing-applications/building-blocks/workflow/)
- [Dapr SDK for JavaScript](https://github.com/dapr/js-sdk)

## License

This project is licensed under the MIT License — see [LICENSE](LICENSE) for details.
