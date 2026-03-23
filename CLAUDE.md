# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
make deps           # Check/install node, pnpm, docker, dapr, git
make install        # Install npm dependencies (pnpm install)
make build          # Compile TypeScript to dist/
make start          # Build and start API server with Dapr sidecar
make stop           # Stop the Dapr sidecar and API server
make start-no-dapr  # Build and start API server without Dapr (HTTP only)
make postgres-start # Start PostgreSQL in Docker
make postgres-stop  # Stop PostgreSQL Docker container
make dapr-init      # Initialize Dapr (one-time; stops conflicting Redis first)
make check-workflow # Trigger a test workflow and poll the result
make check-db       # Run the database health check endpoint
make ci             # Run GitHub Actions CI pipeline locally via act (requires Docker)
```

The full test sequence with Dapr:
1. `make dapr-init` (one-time setup)
2. `docker start redis-container` (if redis-container exists but is stopped)
3. `make postgres-start`
4. `make start` (Terminal 1 — stays in foreground)
5. `make check-workflow` or `make check-db` (Terminal 2)
6. `make stop` → `make postgres-stop`

The CI pipeline (`.github/workflows/ci.yml`) runs `pnpm install` and `pnpm build` only — there are no automated tests.

## Architecture

This is a **Dapr Workflow** demo using the Dapr JS SDK with an Express HTTP API frontend.

### Request flow

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

### Key files

- `src/api-server.ts` — Express app, lazy-initializes `WorkflowRuntime` and `DaprWorkflowClient` on first request, exposes three endpoints
- `src/data-request-workflow.ts` — defines the `dataRequestWorkflow` generator and all four activities

### Dapr components (`components/`)

- `postgres.yaml` — `bindings.postgres` binding named `postgres-db`; the workflow queries it via direct HTTP POST to `http://localhost:{DAPR_HTTP_PORT}/v1.0/bindings/postgres-db`
- `redis.yaml` — `state.redis` state store named `state-redis`; used as Dapr's actor/workflow state backend (required by the runtime even if not queried directly)

### Workflow pattern

`dataRequestWorkflow` is a `TWorkflow` async generator. Steps are composed with `yield ctx.callActivity(...)`. The workflow is **durable** — Dapr replays it from state on restart. Activities must be **deterministic** in their side effects.

### API endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/` | Health check |
| `POST` | `/process-payload` | Schedules a new workflow; returns `{ id }` immediately (202) |
| `GET` | `/workflow/:id/status` | Polls workflow state; `output` only present when complete |
| `GET` | `/db-health` | Schedules a workflow and waits up to 10s for completion |

### Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `PORT` | `3000` | Express listen port |
| `DAPR_HTTP_PORT` | `3500` | Dapr sidecar HTTP port (used in `fetchPostgresDataActivity`) |
| `DAPR_HOST` | `localhost` | Set by the `start` Makefile target |
