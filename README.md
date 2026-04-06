[![CI](https://github.com/AndriyKalashnykov/dapr-nodejs-workflow/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/AndriyKalashnykov/dapr-nodejs-workflow/actions/workflows/ci.yml)
[![Hits](https://hits.sh/github.com/AndriyKalashnykov/dapr-nodejs-workflow.svg?view=today-total&style=plastic)](https://hits.sh/github.com/AndriyKalashnykov/dapr-nodejs-workflow/)
[![License: MIT](https://img.shields.io/badge/License-MIT-brightgreen.svg)](https://opensource.org/licenses/MIT)
[![Renovate enabled](https://img.shields.io/badge/renovate-enabled-brightgreen.svg)](https://app.renovatebot.com/dashboard#github/AndriyKalashnykov/dapr-nodejs-workflow)

# Dapr Node.js Workflow

A Dapr Workflow demo using the [Dapr JS SDK](https://github.com/dapr/js-sdk) with an Express HTTP API. The app schedules durable workflows that query PostgreSQL through Dapr bindings, with Redis as the workflow state backend.

## Quick Start

```bash
make deps          # install system dependencies (node, pnpm, podman, dapr, git)
make install       # install npm packages
make dapr-init     # initialize Dapr (starts Redis, placement, scheduler containers)
make up            # start PostgreSQL via Podman Compose
make start         # build and start API server with Dapr sidecar (foreground)
```

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| [GNU Make](https://www.gnu.org/software/make/) | 3.81+ | Build orchestration |
| [Node.js](https://nodejs.org/) | 24.14.1+ | JavaScript runtime (installed by `make deps`) |
| [pnpm](https://pnpm.io/) | 10+ | Package manager (installed by `make deps`) |
| [Docker](https://www.docker.com/) or [Podman](https://podman.io/) | latest | Container runtime |
| [Dapr CLI](https://docs.dapr.io/getting-started/install-dapr-cli/) | 1.17+ | Dapr sidecar management (installed by `make deps`) |
| [Git](https://git-scm.com/) | latest | Version control |
| [act](https://github.com/nektos/act) | 0.2.87+ | Run GitHub Actions locally (optional, installed by `make deps-act`) |

Install all required dependencies:

```bash
make deps
```

## Usage

### Run with Dapr

```bash
# Terminal 1 -- start infrastructure and server
make up            # start PostgreSQL via Docker Compose
make start         # build and start API server with Dapr sidecar (foreground)

# Terminal 2 -- verify
make check-db      # run database health check workflow
make check-workflow # trigger a test workflow and poll the result
```

### Run without Dapr (health check only)

```bash
make start-no-dapr
curl http://localhost:3000/
```

### Stop

```bash
make stop          # stop Dapr sidecar and API server
make down          # stop PostgreSQL container
```

## Testing

### Unit Tests

```bash
make test          # run Vitest unit tests
make test-watch    # run unit tests in watch mode
```

### Integration Tests

Integration tests require the full Dapr stack (PostgreSQL + Redis + Dapr sidecar):

```bash
# Terminal 1
make up            # start PostgreSQL
make start         # start API server with Dapr

# Terminal 2
make test-integration
```

### Run CI Locally

```bash
make ci            # run lint, build, test locally
make ci-run        # run GitHub Actions workflow locally via act (requires Docker)
```

> The integration job uses GitHub Actions service containers not supported by `act`. Test integration locally with the steps above.

## API

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/` | Health check |
| `POST` | `/process-payload` | Schedule a new workflow; returns `{ id }` immediately (202) |
| `GET` | `/workflow/:id/status` | Poll workflow state; `output` only present when complete |
| `GET` | `/db-health` | Schedule a workflow and wait up to 10s for DB result |

### Example: trigger a workflow

```bash
# Schedule
curl -X POST http://localhost:3000/process-payload \
  -H "Content-Type: application/json" \
  -d '{"name": "John Doe", "data": {"key1": "value1"}}'
# -> {"message":"...","id":"82236756-4f38-4b5f-9796-a1268184561e"}

# Poll (while 30s delay activity is running)
curl http://localhost:3000/workflow/82236756-4f38-4b5f-9796-a1268184561e/status | jq .
```

While running:
```json
{
  "id": "82236756-4f38-4b5f-9796-a1268184561e",
  "status": "0",
  "createdAt": "2025-09-16T16:34:44.118Z",
  "lastUpdatedAt": "2025-09-16T16:34:47.139Z"
}
```

After completion (`output` is present):
```json
{
  "id": "82236756-4f38-4b5f-9796-a1268184561e",
  "status": "1",
  "output": "{\"name\":\"John Doe\",\"processed\":true,...}",
  "createdAt": "2025-09-16T16:34:44.118Z",
  "lastUpdatedAt": "2025-09-16T16:35:21.199Z"
}
```

## Architecture

```
HTTP client -> Express API (:3000)
                  |
          DaprWorkflowClient (gRPC :50001)
                  |
          Dapr sidecar (:3500 HTTP / :50001 gRPC)
                  |
          WorkflowRuntime -> dataRequestWorkflow
                  |
          Activities:
            1. delayActivity            -- async wait (30s)
            2. modifyPayloadActivity    -- enrich payload
            3. fetchPostgresDataActivity -- Dapr binding -> PostgreSQL
```

### Service Ports

| Service | Port | Protocol | Purpose |
|---------|------|----------|---------|
| Express API | 3000 | HTTP | REST endpoints |
| Dapr sidecar | 3500 | HTTP | Binding calls from activities |
| Dapr sidecar | 50001 | gRPC | WorkflowClient / WorkflowRuntime |
| Dapr scheduler | 50006 | gRPC | Workflow scheduling |
| PostgreSQL | 5432 | TCP | Database backend |
| Redis | 6379 | TCP | Dapr state store |

### Project Layout

```
src/
  api-server.ts              Express app with lazy-init Dapr workflow client
  data-request-workflow.ts   Workflow definition and all activities
  __tests__/
    *.test.ts                Unit tests
    *.integration.test.ts    Integration tests (require Dapr stack)
components/                  Dapr component configs (local dev)
dapr/ci/                     Dapr component configs (CI)
db/                          SQL schema and seed data
docker-compose.yaml          PostgreSQL + Redis for local development
```

## Available Make Targets

Run `make help` to see all available targets.

### Development

| Target | Description |
|--------|-------------|
| `make deps` | Install system dependencies (node, pnpm, podman, dapr, git) |
| `make deps-act` | Install act for local CI (GitHub Actions runner) |
| `make install` | Install npm dependencies |
| `make build` | Compile TypeScript to `dist/` |
| `make lint` | Run ESLint (zero warnings enforced) |
| `make format` | Auto-fix formatting with Prettier |
| `make vulncheck` | Audit dependencies for known vulnerabilities |
| `make clean` | Remove `dist/` and `node_modules/` |

### Infrastructure

| Target | Description |
|--------|-------------|
| `make dapr-init` | Initialize Dapr runtime (one-time) |
| `make up` | Start PostgreSQL via Docker/Podman Compose |
| `make down` | Stop and remove infrastructure containers |
| `make postgres-start` | Start standalone PostgreSQL (alternative to `make up`) |
| `make postgres-stop` | Stop standalone PostgreSQL |

### Run & Verify

| Target | Description |
|--------|-------------|
| `make start` | Build and run API server with Dapr sidecar (foreground) |
| `make stop` | Stop Dapr sidecar and API server |
| `make start-no-dapr` | Run API server without Dapr (HTTP only) |
| `make run` | Alias for `start-no-dapr` |
| `make check-workflow` | Trigger a test workflow and poll result |
| `make check-db` | Run database health check endpoint |

### Test

| Target | Description |
|--------|-------------|
| `make test` | Run unit tests |
| `make test-watch` | Run unit tests in watch mode |
| `make test-integration` | Run integration tests (requires running Dapr stack) |
| `make check` | Run lint + build + test |

### CI & Release

| Target | Description |
|--------|-------------|
| `make ci` | Run local CI pipeline (lint, vulncheck, build, test) |
| `make ci-run` | Run GitHub Actions workflow locally via [act](https://github.com/nektos/act) |
| `make audit` | Audit dependencies for vulnerabilities |
| `make release VERSION=vX.Y.Z` | Tag and push a release |

### Utilities

| Target | Description |
|--------|-------------|
| `make update` | Update dependencies to latest allowed versions |
| `make upgrade` | Upgrade dependencies to latest versions (ignoring ranges) |
| `make renovate-validate` | Validate Renovate configuration |

## CI/CD

GitHub Actions runs on every push to `main`, tags `v*`, pull requests, and is reusable via `workflow_call`.

| Job | Triggers | Steps |
|-----|----------|-------|
| **build** | push, PR, tags | `make ci-build`, `make audit` |
| **lint** | push, PR, tags | `make ci-lint` |
| **test** | push, PR, tags | `make ci-test` (after lint) |
| **smoke** | push, PR, tags | `make ci-smoke` (after build + test) |
| **integration** | push, PR, tags | `make ci-seed-db`, `make ci-dapr-start`, `make ci-test-integration` (after build + test) |
| **ci-pass** | always | Gate job: fails if any upstream job fails |

[Renovate](https://docs.renovatebot.com/) keeps dependencies up to date with platform automerge enabled.

## References

- [Dapr Concepts](https://docs.dapr.io/concepts/)
- [Dapr Workflows](https://docs.dapr.io/developing-applications/building-blocks/workflow/)
- [Dapr SDK for JavaScript](https://github.com/dapr/js-sdk)
