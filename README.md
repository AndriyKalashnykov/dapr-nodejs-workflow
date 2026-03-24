[![ci](https://github.com/AndriyKalashnykov/dapr-nodejs-workflow/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/AndriyKalashnykov/dapr-nodejs-workflow/actions/workflows/ci.yml)
[![Hits](https://hits.sh/github.com/AndriyKalashnykov/dapr-nodejs-workflow.svg?view=today-total&style=plastic)](https://hits.sh/github.com/AndriyKalashnykov/dapr-nodejs-workflow/)
[![License: MIT](https://img.shields.io/badge/License-MIT-brightgreen.svg)](https://opensource.org/licenses/MIT)
[![Renovate enabled](https://img.shields.io/badge/renovate-enabled-brightgreen.svg)](https://app.renovatebot.com/dashboard#github/AndriyKalashnykov/dapr-nodejs-workflow)

# dapr-nodejs-workflow

## Prerequisites

* Linux OS
* [Docker](https://www.docker.com/)
* [Git](https://git-scm.com/downloads)
* [Dapr CLI](https://docs.dapr.io/getting-started/install-dapr-cli/)
* [Node.js](https://nodejs.org/en/) v24+
* [pnpm](https://pnpm.io/)

## Clone the repository

```bash
mkdir ~/projects && cd ~/projects
git clone git@github.com:AndriyKalashnykov/dapr-nodejs-workflow.git && cd ~/projects/dapr-nodejs-workflow
```

## Setup

```bash
# Check and install required dependencies
make deps

# Install npm dependencies
make install

# Initialize Dapr in your local environment (one-time)
make dapr-init
```

## Running the example

**With Dapr** (required for workflow functionality):

```bash
# Terminal 1 — start PostgreSQL, then the API server with Dapr sidecar
make postgres-start
make start

# Terminal 2 — trigger a test workflow and poll the result
make check-workflow

# Check database connectivity via a short-lived workflow
make check-db

# Stop the server and PostgreSQL
make stop
make postgres-stop
```

**Without Dapr** (HTTP server only):

```bash
make start-no-dapr
curl http://localhost:3000/
```

## API

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/` | Health check |
| `POST` | `/process-payload` | Schedule a new workflow; returns `{ id }` immediately (202) |
| `GET` | `/workflow/:id/status` | Poll workflow state; `output` only present when complete |
| `GET` | `/db-health` | Schedule a workflow and wait up to 10s for DB result |

### Example: trigger a workflow

```bash
curl -X POST http://localhost:3000/process-payload \
  -H "Content-Type: application/json" \
  -d '{"name": "John Doe", "data": {"key1": "value1", "key2": "value2"}}'
# → {"message":"...","id":"82236756-4f38-4b5f-9796-a1268184561e"}
```

Poll status while the 30s delay activity is running (no `output` yet):

```bash
curl http://localhost:3000/workflow/82236756-4f38-4b5f-9796-a1268184561e/status | jq .
```
```json
{
  "id": "82236756-4f38-4b5f-9796-a1268184561e",
  "status": "0",
  "createdAt": "2025-09-16T16:34:44.118Z",
  "lastUpdatedAt": "2025-09-16T16:34:47.139Z"
}
```

After the workflow completes (`output` is present):

```json
{
  "id": "82236756-4f38-4b5f-9796-a1268184561e",
  "status": "1",
  "output": "{\"name\":\"John Doe\",\"processed\":true,...}",
  "createdAt": "2025-09-16T16:34:44.118Z",
  "lastUpdatedAt": "2025-09-16T16:35:21.199Z"
}
```

## Makefile Reference

Run `make help` to list all available targets. Summary:

| Target | Description |
|--------|-------------|
| `make deps` | Check and install required dependencies (node, pnpm, podman, dapr, act, git) |
| `make install` | Install npm dependencies (`pnpm install`) |
| `make build` | Compile TypeScript to `dist/` |
| `make lint` | Run ESLint on source files |
| `make test` | Run unit tests (lints first) |
| `make test-watch` | Run unit tests in watch mode |
| `make check` | Run full local verification (lint, build, test) |
| `make start` | Build and start the API server with Dapr sidecar |
| `make stop` | Stop the Dapr sidecar and API server |
| `make start-no-dapr` | Build and start the API server without Dapr (HTTP only) |
| `make postgres-start` | Start PostgreSQL in Podman |
| `make postgres-stop` | Stop PostgreSQL container |
| `make dapr-init` | Initialize Dapr in local environment (one-time) |
| `make check-workflow` | Trigger a test workflow and poll the result |
| `make check-db` | Run the database health check endpoint |
| `make clean` | Remove build artifacts and `node_modules` |
| `make update` | Update dependencies to latest allowed versions |
| `make upgrade` | Upgrade dependencies to latest versions (ignoring ranges) |
| `make ci-install` | Install dependencies with frozen lockfile (CI only, skips system deps) |
| `make ci-build` | Build TypeScript in CI (frozen lockfile, no system deps) |
| `make ci-lint` | Run ESLint in CI (frozen lockfile, no system deps) |
| `make ci-test` | Run unit tests in CI |
| `make ci-smoke` | Run HTTP smoke test against built server |
| `make audit` | Audit dependencies for known vulnerabilities |
| `make ci` | Run GitHub Actions CI pipeline locally via `act` (requires Docker) |
| `make release VERSION=vX.Y.Z` | Create and push a release tag |
| `make renovate` | Run Renovate locally in dry-run mode |

## CI

Run the GitHub Actions CI pipeline locally (requires Docker):

```bash
make ci
```

## References

* [Dapr Concepts](https://docs.dapr.io/concepts/)
* [Dapr Workflows](https://docs.dapr.io/developing-applications/building-blocks/workflow/)
* [Dapr SDK for JavaScript](https://github.com/dapr/js-sdk)
