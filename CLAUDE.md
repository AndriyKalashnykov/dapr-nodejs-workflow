# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Dapr Workflow demo using the Dapr JS SDK with an Express HTTP API frontend. A single Node.js/TypeScript service runs alongside a Dapr sidecar that orchestrates durable workflows with PostgreSQL and Redis backends. Container runtime is Podman (Docker-compatible).

## Quick Start

```bash
# One-time setup
make deps                # Check and install system dependencies (node, pnpm, podman, dapr, git)
make dapr-init           # Initialize Dapr (starts Redis, placement, scheduler containers)

# Start infrastructure + server (two terminals)
make up                  # Terminal 1: start PostgreSQL + Redis via Podman Compose
make start               # Terminal 2: build and start API server with Dapr sidecar (foreground)

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

### Setup & Dependencies

| Target               | Description                                                              |
| -------------------- | ------------------------------------------------------------------------ |
| `make deps`          | Check and install system dependencies (node, pnpm, podman, dapr, git)    |
| `make deps-act`      | Install act for local CI (GitHub Actions runner)                         |
| `make deps-trivy`    | Install Trivy for filesystem security scanning                           |
| `make deps-gitleaks` | Install gitleaks for secret scanning                                     |
| `make install`       | Install npm dependencies (uses `--frozen-lockfile` when `CI=true`)       |
| `make dapr-init`     | Initialize Dapr in local environment (stops conflicting Redis if needed) |

### Build & Quality

| Target                  | Description                                                                                                            |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `make build`            | Compile TypeScript to `dist/`                                                                                          |
| `make format`           | Auto-fix formatting with Prettier                                                                                      |
| `make format-check`     | Check formatting without modifying files                                                                               |
| `make lint`             | Run Prettier check, ESLint (zero warnings), and `tsc --noEmit`                                                         |
| `make vulncheck`        | Audit dependencies for known vulnerabilities (`pnpm audit --audit-level=moderate`)                                     |
| `make secrets`          | Scan for hardcoded secrets with gitleaks                                                                               |
| `make trivy-fs`         | Scan filesystem for vulnerabilities, secrets, and misconfigurations                                                    |
| `make deps-prune`       | Show unused/redundant Node.js dependencies                                                                             |
| `make deps-prune-check` | Verify no prunable dependencies (CI gate)                                                                              |
| `make static-check`     | Composite quality gate: `lint` + `vulncheck` + `secrets` + `trivy-fs` + `deps-prune-check`. CI calls this single step. |
| `make check`            | Full local verification: `format-check` + `static-check` + `test` + `build`                                            |

### Infrastructure

| Target                | Description                                                      |
| --------------------- | ---------------------------------------------------------------- |
| `make up`             | Start PostgreSQL + Redis via Podman Compose                      |
| `make down`           | Stop and remove Podman Compose containers                        |
| `make postgres-start` | Start standalone PostgreSQL container (alternative to `make up`) |
| `make postgres-stop`  | Stop standalone PostgreSQL container                             |

### Run

| Target               | Description                                                      |
| -------------------- | ---------------------------------------------------------------- |
| `make start`         | Build and start API server with Dapr sidecar (foreground)        |
| `make stop`          | Stop the Dapr sidecar and API server                             |
| `make start-no-dapr` | Build and start API server without Dapr (HTTP health check only) |
| `make run`           | Alias for `start-no-dapr`                                        |

### Test & Verify

| Target                  | Description                                                      |
| ----------------------- | ---------------------------------------------------------------- |
| `make test`             | Run unit tests                                                   |
| `make test-watch`       | Run unit tests in watch mode                                     |
| `make test-integration` | Run integration tests (requires running Dapr stack + PostgreSQL) |
| `make smoke`            | HTTP smoke test against built server (no Dapr)                   |
| `make check-workflow`   | Trigger a workflow via API and poll its status                   |
| `make check-db`         | Hit the `/db-health` endpoint                                    |

### CI & Release

| Target                        | Description                                                             |
| ----------------------------- | ----------------------------------------------------------------------- |
| `make ci`                     | Run local CI pipeline (`format-check`, `static-check`, `test`, `build`) |
| `make ci-run`                 | Run GitHub Actions workflow locally via `act` (requires Docker)         |
| `make release VERSION=vX.Y.Z` | Tag and push a release                                                  |

The `ci-seed-db` and `ci-dapr-start` Makefile targets exist exclusively for the GitHub Actions `integration` job and are not intended for local use — use `make up` + `make start` locally instead.

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
  postgres.yaml              bindings.postgres -- local dev (password: daprrulz)
  redis.yaml                 state.redis -- local dev (localhost:6379)
dapr/ci/
  postgres.yaml              bindings.postgres -- CI (password: postgres)
  redis.yaml                 state.redis -- CI (localhost:6379)
db/
  baseline_ddl.sql           Table schema (users table)
  baseline_dml.sql           Seed data
docker-compose.yaml          PostgreSQL + Redis for local development
Dockerfile                   Multi-stage production image (distroless, non-root)
.dockerignore                Excludes non-runtime files from build context
```

### Request Flow

```
HTTP client -> Express API (:3000)
                  |
          DaprWorkflowClient (gRPC :50001)
                  |
          Dapr sidecar (:3500 HTTP / :50001 gRPC)
                  |
          WorkflowRuntime executes dataRequestWorkflow
                  |
          Activities (in sequence):
            1. delayActivity            -- async wait (30s default)
            2. modifyPayloadActivity    -- enriches the input payload
            3. fetchPostgresDataActivity -- Dapr binding HTTP API -> PostgreSQL
```

### Dapr Sidecar Pattern

The app runs as two processes: Express API + Dapr sidecar. The sidecar manages:

- **State**: Redis via `state-redis` component -- Dapr's actor/workflow state backend
- **Bindings**: PostgreSQL via `postgres-db` component -- queried via HTTP POST to `http://localhost:{DAPR_HTTP_PORT}/v1.0/bindings/postgres-db`

The `WorkflowRuntime` and `DaprWorkflowClient` are lazy-initialized on the first API request. If the Dapr sidecar is unreachable on gRPC port 50001, the app returns an error directing the user to run `make start`.

### Workflow Pattern

`dataRequestWorkflow` is a `TWorkflow` async generator. Steps are composed with `yield ctx.callActivity(...)`. The workflow is **durable** -- Dapr replays it from state on restart. Activities must be **deterministic** in their side effects.

### Service Ports

| Service        | Port  | Protocol | Purpose                                                  |
| -------------- | ----- | -------- | -------------------------------------------------------- |
| Express API    | 3000  | HTTP     | REST endpoints                                           |
| Dapr sidecar   | 3500  | HTTP     | Binding calls from activities                            |
| Dapr sidecar   | 50001 | gRPC     | WorkflowClient / WorkflowRuntime                         |
| Dapr scheduler | 50006 | gRPC     | Workflow scheduling (started by `dapr init`)             |
| PostgreSQL     | 5432  | TCP      | `postgresql://postgres:daprrulz@localhost:5432/postgres` |
| Redis          | 6379  | TCP      | Dapr state store backend (started by `dapr init`)        |

### API Endpoints

| Method | Path                   | Description                                                  |
| ------ | ---------------------- | ------------------------------------------------------------ |
| `GET`  | `/`                    | Health check -- returns `{ message }`                        |
| `POST` | `/process-payload`     | Schedules a new workflow; returns `{ id }` immediately (202) |
| `GET`  | `/workflow/:id/status` | Polls workflow state; `output` only present when complete    |
| `GET`  | `/db-health`           | Schedules a workflow and waits up to 10s for completion      |

### CI Pipeline (`.github/workflows/ci.yml`)

The CI pipeline runs on pushes to `main`, version tags (`v*`), pull requests, and is reusable via `workflow_call`. Jobs:

- **static-check**: `make static-check` — Prettier check + ESLint + `tsc --noEmit` + `pnpm audit` + gitleaks + Trivy filesystem scan + depcheck (single composite quality gate)
- **build**: `make build` + `make smoke` (HTTP smoke test against the built server, no Dapr)
- **test**: `make test` (Vitest unit tests)
- **e2e**: `make e2e` — build Docker image, run container, validate health endpoint and Dapr lazy-init error handling
- **integration**: `make ci-seed-db` + `make build` + `make ci-dapr-start` + `make test-integration` (PostgreSQL service container, Dapr CLI 1.17.1, full-stack Vitest integration tests)
- **docker** (tag-gated `v*` only): multi-arch build + push to GHCR with pre-push gates (Trivy image scan CRITICAL/HIGH blocking, Node.js boot-marker smoke test, `provenance: mode=max`, `sbom: true`, cosign keyless OIDC signing)
- **ci-pass**: gate job — runs after all upstream jobs and fails if any of them failed; intended as the single status check for branch protection

Job dependencies: `static-check` -> `build` + `test` (parallel) -> `e2e` + `integration` (parallel) -> `docker` (tag-gated) -> `ci-pass`.

CI uses `--frozen-lockfile` for reproducible builds. The Makefile sets `PNPM_INSTALL := pnpm install $(if $(CI),--frozen-lockfile,)`, so `make install` automatically picks the right mode based on the `CI` environment variable.

A second workflow, `.github/workflows/cleanup-runs.yml`, runs weekly to delete old workflow runs and stale caches via the native `gh` CLI (no third-party actions).

**Local CI**: `make ci` runs `format-check`, `static-check`, `test`, and `build` locally. `make ci-run` runs the GitHub Actions workflow via `act`. The `integration` job requires service containers not supported by `act`; test integration locally with `make up` + `make start` + `make test-integration` instead.

## Key Environment Variables

| Variable         | Default | Purpose                                                                                                   |
| ---------------- | ------- | --------------------------------------------------------------------------------------------------------- |
| `PORT`           | `3000`  | Express listen port                                                                                       |
| `DAPR_HTTP_PORT` | `3500`  | Dapr sidecar HTTP port (read by `fetchPostgresDataActivity`)                                              |
| `CI`             | unset   | When set (e.g. by GitHub Actions), `deps` skips podman/dapr checks and `install` uses `--frozen-lockfile` |

> Note: the `start` Makefile target exports `DAPR_HOST=localhost` for completeness, but the application currently hardcodes `daprHost = "localhost"` in `src/api-server.ts` and does not read this env var. Safe to remove on the next refactor.

## Workflow Rules

### Before Every Commit

```bash
make build              # compile TypeScript
make up                 # start PostgreSQL + Redis (Terminal 1)
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

## Upgrade Backlog

- [ ] `@dapr/dapr` bundles Express 4 internally — `path-to-regexp` vuln patched via pnpm override; monitor upstream Dapr JS SDK for express 5 migration so the override can be removed
- [ ] Ubuntu 26.04 LTS releases Apr 2026 — watch for `ubuntu-latest` CI runner migration
- [ ] `dapr/setup-dapr@v2` runs on Node 20 (deprecated by GitHub Sep 2026) — no `v3` released yet, even `main` uses `node20`. Track [dapr/setup-dapr](https://github.com/dapr/setup-dapr) for an update
- [ ] `pnpm/action-setup@v5` emits `[DEP0169] url.parse()` deprecation warning in CI logs — upstream issue, will resolve in a future patch
- [ ] CI workflow `env: DAPR_CLI_VERSION` duplicates Makefile constant — `dapr/setup-dapr` has no auto-detect equivalent of `packageManager`. Either accept the duplication or add a Renovate custom regex
- [ ] `postgres:18-alpine` digest is hardcoded in `ci.yml` AND `docker-compose.yaml` — only the compose pin is Renovate-tracked, so the CI workflow will silently lag. Consider a custom regex or refactor CI to read from compose
- [ ] Dapr runtime is unpinned (`dapr init` pulls latest) — consider `--runtime-version $(DAPR_RUNTIME_VERSION)` for reproducibility

## Skills

Use the following skills when working on related files:

| File(s)                          | Skill          |
| -------------------------------- | -------------- |
| `Makefile`                       | `/makefile`    |
| `renovate.json`                  | `/renovate`    |
| `README.md`                      | `/readme`      |
| `.github/workflows/*.{yml,yaml}` | `/ci-workflow` |

When spawning subagents, always pass conventions from the respective skill into the agent's prompt.
