# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Dapr Workflow demo using the Dapr JS SDK with an Express HTTP API frontend. A single Node.js/TypeScript service runs alongside a Dapr sidecar that orchestrates durable workflows with PostgreSQL and Redis backends. Container runtime is Podman (Docker-compatible).

## Quick Start

```bash
# One-time setup
make deps                # Install system dependencies (node, pnpm, podman, dapr, act, git)
make install             # Install npm dependencies
make dapr-init           # Initialize Dapr (starts Redis, placement, scheduler containers)

# Start infrastructure + server (two terminals)
make up                  # Terminal 1: start PostgreSQL via Podman Compose (Redis from dapr-init)
make start               # Terminal 1: build and start API server with Dapr sidecar (foreground)

# Verify (from another terminal)
make check-workflow      # Trigger a test workflow and poll the result
make check-db            # Run the database health check endpoint

# Run tests
make test                # Unit tests (Vitest)
make test-integration    # Integration tests (requires running Dapr stack)

# Stop everything
make stop                # Stop Dapr sidecar and API server
make down                # Stop PostgreSQL container
```

## Makefile Targets

Run `make help` for the full list. Key targets grouped by purpose:

### Setup
| Target | Description |
|--------|-------------|
| `make deps` | Install system dependencies (node, pnpm, podman, dapr, act, git) |
| `make install` | Install npm dependencies (`pnpm install`) |
| `make dapr-init` | Initialize Dapr runtime (one-time; starts Redis, placement, scheduler containers) |

### Build & Lint
| Target | Description |
|--------|-------------|
| `make build` | Compile TypeScript to `dist/` |
| `make lint` | Run ESLint on source files |
| `make check` | Run lint + build + test in sequence |

### Infrastructure
| Target | Description |
|--------|-------------|
| `make up` | Start PostgreSQL via Podman Compose (Redis provided by `dapr-init`) |
| `make down` | Stop and remove Podman Compose containers |
| `make postgres-start` | Start standalone PostgreSQL container (alternative to `make up`) |
| `make postgres-stop` | Stop standalone PostgreSQL container |

### Run
| Target | Description |
|--------|-------------|
| `make start` | Build and start API server with Dapr sidecar (foreground) |
| `make stop` | Stop the Dapr sidecar and API server |
| `make start-no-dapr` | Build and start API server without Dapr (HTTP health check only) |

### Test & Verify
| Target | Description |
|--------|-------------|
| `make test` | Run unit tests (lints first) |
| `make test-watch` | Run unit tests in watch mode |
| `make test-integration` | Run integration tests (requires running Dapr stack + PostgreSQL) |
| `make check-workflow` | Trigger a workflow via API and poll its status |
| `make check-db` | Hit the `/db-health` endpoint |

### CI & Release
| Target | Description |
|--------|-------------|
| `make ci` | Run build, lint, test, smoke jobs locally via `act` (requires Docker) |
| `make audit` | Audit dependencies for known vulnerabilities |
| `make release VERSION=vX.Y.Z` | Tag and push a release |

## Architecture

### Project Layout
```
src/
  api-server.ts              Express app, lazy-init WorkflowRuntime + DaprWorkflowClient
  data-request-workflow.ts   dataRequestWorkflow generator and all activities
  __tests__/
    *.test.ts                Unit tests (Vitest)
    *.integration.test.ts    Integration tests (require running Dapr stack)
components/
  postgres.yaml              bindings.postgres — local dev (password: daprrulz)
  redis.yaml                 state.redis — local dev (localhost:6379)
dapr/ci/
  postgres.yaml              bindings.postgres — CI (password: postgres)
  redis.yaml                 state.redis — CI (localhost:6379)
db/
  baseline_ddl.sql           Table schema (users table)
  baseline_dml.sql           Seed data
docker-compose.yaml          PostgreSQL + Redis for local development
```

### Request Flow
```
HTTP client → Express API (:3000)
                  ↓
          DaprWorkflowClient (gRPC :50001)
                  ↓
          Dapr sidecar (:3500 HTTP / :50001 gRPC)
                  ↓
          WorkflowRuntime executes dataRequestWorkflow
                  ↓
          Activities (in sequence):
            1. delayActivity            — async wait (30s default)
            2. modifyPayloadActivity    — enriches the input payload
            3. fetchPostgresDataActivity — Dapr binding HTTP API → PostgreSQL
```

### Dapr Sidecar Pattern
The app runs as two processes: Express API + Dapr sidecar. The sidecar manages:
- **State**: Redis via `state-redis` component — Dapr's actor/workflow state backend
- **Bindings**: PostgreSQL via `postgres-db` component — queried via HTTP POST to `http://localhost:{DAPR_HTTP_PORT}/v1.0/bindings/postgres-db`

The `WorkflowRuntime` and `DaprWorkflowClient` are lazy-initialized on the first API request. If the Dapr sidecar is unreachable on gRPC port 50001, the app returns an error directing the user to run `make start`.

### Workflow Pattern
`dataRequestWorkflow` is a `TWorkflow` async generator. Steps are composed with `yield ctx.callActivity(...)`. The workflow is **durable** — Dapr replays it from state on restart. Activities must be **deterministic** in their side effects.

### Service Ports

| Service | Port | Protocol | Purpose |
|---------|------|----------|---------|
| Express API | 3000 | HTTP | REST endpoints |
| Dapr sidecar | 3500 | HTTP | Binding calls from activities |
| Dapr sidecar | 50001 | gRPC | WorkflowClient / WorkflowRuntime |
| Dapr scheduler | 50006 | gRPC | Workflow scheduling (started by `dapr init`) |
| PostgreSQL | 5432 | TCP | `postgresql://postgres:daprrulz@localhost:5432/postgres` |
| Redis | 6379 | TCP | Dapr state store backend (started by `dapr init`) |

### API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/` | Health check — returns `{ message }` |
| `POST` | `/process-payload` | Schedules a new workflow; returns `{ id }` immediately (202) |
| `GET` | `/workflow/:id/status` | Polls workflow state; `output` only present when complete |
| `GET` | `/db-health` | Schedules a workflow and waits up to 10s for completion |

### CI Pipeline (`.github/workflows/ci.yml`)
The CI pipeline runs on pushes and PRs to `main` with these jobs:
- **build**: `make ci-build` + `make audit`
- **lint**: `make ci-lint`
- **test**: `make ci-test` (Vitest unit tests)
- **smoke**: `make ci-smoke` (starts Express without Dapr, verifies health endpoint)
- **integration**: `make ci-seed-db` + `make ci-dapr-start` + `make ci-test-integration` (PostgreSQL service container, Dapr CLI v1.17.0, full-stack Vitest integration tests)
- **ci-pass**: gate job — fails if any upstream job fails

Job dependencies: `lint` → `test` → `smoke` + `integration`, `build` → `smoke` + `integration`.

**Local CI**: `make ci` runs build, lint, test, smoke via `act`. The integration job requires service containers not supported by `act`; test integration locally with `make up` + `make start` + `make test-integration`.

## Key Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `PORT` | `3000` | Express listen port |
| `DAPR_HTTP_PORT` | `3500` | Dapr sidecar HTTP port (used in `fetchPostgresDataActivity`) |
| `DAPR_HOST` | `localhost` | Set by the `start` Makefile target |

## Workflow Rules

### Before Every Commit
```bash
make build              # compile TypeScript
make up                 # start PostgreSQL (Terminal 1)
make start              # start with Dapr sidecar (Terminal 1)
make check-workflow     # trigger a workflow (Terminal 2)
make check-db           # verify database health (Terminal 2)
make stop               # stop the stack
make down               # stop infrastructure
```

After pushing, watch the remote CI run:
```bash
gh run watch
```

### Keep Documentation Up to Date
After any code or configuration change, review and update `README.md`, `CLAUDE.md`, and Dapr component configs. Command references, architecture descriptions, port tables, and environment variable tables must stay in sync with the code.
