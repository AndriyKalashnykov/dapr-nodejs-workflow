# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Install dependencies
pnpm install

# Build (compiles TypeScript to dist/)
pnpm build

# Start the API server directly (no Dapr sidecar)
pnpm run start:api-server

# Start with Dapr sidecar (required for workflow functionality)
pnpm run start:dapr:api-server

# Start PostgreSQL via Docker
./run-postgres.sh
```

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
              1. delayActivity       — simulates async wait (30s default)
              2. modifyPayloadActivity — enriches the input payload
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
| `DAPR_HOST` | `localhost` | Set by the `start:dapr:api-server` script |
