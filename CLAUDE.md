# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Dapr Workflow demo using the Dapr JS SDK with an Express HTTP API frontend. A single Node.js/TypeScript service runs alongside a Dapr sidecar that orchestrates durable workflows with PostgreSQL and Redis backends. Container runtime is Podman (Docker-compatible).

## Common Commands

### Makefile (run `make help` for full list)
```bash
# Setup (first time)
make deps && make install && make dapr-init

# Build
make build              # Compile TypeScript to dist/

# Start / stop
make start              # Build and start API server with Dapr sidecar (foreground)
make stop               # Stop the Dapr sidecar and API server
make start-no-dapr      # Build and start API server without Dapr (HTTP only)

# Infrastructure (Podman Compose)
make up                 # Start Redis + PostgreSQL via Podman Compose
make down               # Stop and remove infrastructure containers

# Database (standalone, alternative to `make up`)
make postgres-start     # Start PostgreSQL in Podman
make postgres-stop      # Stop PostgreSQL container

# Verify
make check-workflow     # Trigger a test workflow and poll the result
make check-db           # Run the database health check endpoint

# Integration tests
make test-integration   # Run Dapr integration tests (requires running stack)

# Maintenance
make clean              # Remove build artifacts and node_modules
make ci                 # Run GitHub Actions CI pipeline locally via act
make release VERSION=v1.0.0  # Tag and push a release
```

### Full Test Sequence with Dapr (docker-compose)
1. `make dapr-init` (one-time setup)
2. `make up` (starts Redis + PostgreSQL via Podman Compose)
3. `make start` (Terminal 1 — stays in foreground)
4. `make test-integration` (Terminal 2 — runs Vitest integration suite)
5. `make check-workflow` or `make check-db` (Terminal 2 — manual verification)
6. `make stop` → `make down`

### Full Test Sequence with Dapr (standalone)
1. `make dapr-init` (one-time setup)
2. `docker start redis-container` (if redis-container exists but is stopped)
3. `make postgres-start`
4. `make start` (Terminal 1 — stays in foreground)
5. `make check-workflow` or `make check-db` (Terminal 2)
6. `make stop` → `make postgres-stop`

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
  postgres.yaml              bindings.postgres binding named postgres-db (local dev)
  redis.yaml                 state.redis state store named state-redis (local dev)
dapr/ci/
  postgres.yaml              CI-specific postgres binding (password: postgres)
  redis.yaml                 CI-specific redis state store
docker-compose.yaml          Podman/Docker Compose — Redis + PostgreSQL for local development
```

### Request Flow
```
HTTP client → Express API (port 3000)
                    ↓
            DaprWorkflowClient (gRPC :50001)
                    ↓
            Dapr sidecar (:3500 HTTP / :50001 gRPC)
                    ↓
            WorkflowRuntime executes dataRequestWorkflow
                    ↓
            Activities (in sequence):
              1. delayActivity            — simulates async wait (30s default)
              2. modifyPayloadActivity    — enriches the input payload
              3. fetchPostgresDataActivity — calls Dapr binding HTTP API → PostgreSQL
```

### Dapr Sidecar Pattern
The app runs as two processes: Express API + Dapr sidecar. The sidecar manages:
- **State**: Redis via `state-redis` component — used as Dapr's actor/workflow state backend (required by the runtime even if not queried directly)
- **Bindings**: PostgreSQL via `postgres-db` component — the workflow queries it via direct HTTP POST to `http://localhost:{DAPR_HTTP_PORT}/v1.0/bindings/postgres-db`

The `WorkflowRuntime` and `DaprWorkflowClient` are lazy-initialized on the first API request. If the Dapr sidecar is unreachable on gRPC port 50001, the app returns an error directing the user to run `make start`.

### Workflow Pattern
`dataRequestWorkflow` is a `TWorkflow` async generator. Steps are composed with `yield ctx.callActivity(...)`. The workflow is **durable** — Dapr replays it from state on restart. Activities must be **deterministic** in their side effects.

### Service Ports

| Service | Port | Protocol | Access |
|---------|------|----------|--------|
| Express API | 3000 | HTTP | `http://localhost:3000` |
| Dapr sidecar | 3500 | HTTP | Used by `fetchPostgresDataActivity` for binding calls |
| Dapr sidecar | 50001 | gRPC | Used by `DaprWorkflowClient` / `WorkflowRuntime` |
| PostgreSQL | 5432 | TCP | `postgresql://postgres:daprrulz@localhost:5432/postgres` |
| Redis | 6379 | TCP | Dapr state store backend |

### API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/` | Health check — returns `{ message }` |
| `POST` | `/process-payload` | Schedules a new workflow; returns `{ id }` immediately (202) |
| `GET` | `/workflow/:id/status` | Polls workflow state; `output` only present when complete |
| `GET` | `/db-health` | Schedules a workflow and waits up to 10s for completion |

### CI Pipeline (`.github/workflows/ci.yml`)
The CI pipeline runs on pushes and PRs to `main` with these jobs:
- **build**: `make ci-build` (frozen lockfile install + TypeScript compile) + `make audit` (dependency vulnerability scan)
- **lint**: `make ci-lint` (ESLint with typescript-eslint strict rules)
- **test**: `make ci-test` (Vitest unit tests for activities and utilities)
- **smoke**: `make ci-smoke` (builds, starts the Express server without Dapr, verifies health endpoint)
- **integration**: `make ci-test-integration` (PostgreSQL + Redis service containers, Dapr sidecar via `dapr init --slim`, full-stack Vitest integration tests)
- **ci-pass**: gate job — fails if any upstream job fails

Job dependencies: `lint` → `test` → `smoke` + `integration`, `build` → `smoke` + `integration`.

Concurrency control cancels redundant runs for the same ref. To run CI locally: `make ci` (requires `act` and Docker).

## Key Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `PORT` | `3000` | Express listen port |
| `DAPR_HTTP_PORT` | `3500` | Dapr sidecar HTTP port (used in `fetchPostgresDataActivity`) |
| `DAPR_HOST` | `localhost` | Set by the `start` Makefile target |

## Workflow Rules

### Before Every Commit
Verify locally before committing and pushing:
```bash
make build              # compile TypeScript
make start              # start with Dapr sidecar (Terminal 1)
make check-workflow     # trigger a workflow (Terminal 2)
make check-db           # verify database health (Terminal 2)
make stop               # stop the stack
```

Verify these URLs are reachable when the stack is running:
- `http://localhost:3000` — health check returns JSON
- `http://localhost:3000/db-health` — database health returns JSON with `status: "success"`

After pushing, watch the remote CI run to confirm it passes:
```bash
gh run watch            # watch the latest CI run
```

### Keep Documentation Up to Date
After any code or configuration change, review and update the project's `*.md` files if affected. This includes `README.md`, `CLAUDE.md`, and Dapr component configs. Command references, architecture descriptions, port tables, and environment variable tables must stay in sync with the code.
