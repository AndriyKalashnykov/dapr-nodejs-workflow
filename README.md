[![CI](https://github.com/AndriyKalashnykov/dapr-nodejs-workflow/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/AndriyKalashnykov/dapr-nodejs-workflow/actions/workflows/ci.yml)
[![Hits](https://hits.sh/github.com/AndriyKalashnykov/dapr-nodejs-workflow.svg?view=today-total&style=plastic)](https://hits.sh/github.com/AndriyKalashnykov/dapr-nodejs-workflow/)
[![License: MIT](https://img.shields.io/badge/License-MIT-brightgreen.svg)](https://opensource.org/licenses/MIT)
[![Renovate enabled](https://img.shields.io/badge/renovate-enabled-brightgreen.svg)](https://app.renovatebot.com/dashboard#github/AndriyKalashnykov/dapr-nodejs-workflow)

# Dapr Node.js Workflow

A Dapr Workflow demo using the [Dapr JS SDK](https://github.com/dapr/js-sdk) with an Express HTTP API. The app schedules durable workflows that query PostgreSQL through Dapr bindings, with Redis as the workflow state backend.

| Component       | Technology                                    |
| --------------- | --------------------------------------------- |
| Language        | TypeScript 6                                  |
| Runtime         | Node.js 24.14.1                               |
| Web framework   | Express 5                                     |
| Workflow engine | Dapr Workflow via `@dapr/dapr` 3.6            |
| State store     | Redis (via Dapr state component)              |
| Data binding    | PostgreSQL 18 (via Dapr binding component)    |
| Container CLI   | Podman (Docker-compatible) + Podman Compose   |
| Testing         | Vitest 4 (unit + integration)                 |
| Linting         | ESLint 10 + typescript-eslint 8               |
| Formatting      | Prettier 3                                    |
| Security        | gitleaks, Trivy filesystem scan, `pnpm audit` |
| CI/CD           | GitHub Actions, Renovate, act (local CI)      |

## Quick Start

```bash
make deps          # install system dependencies (node, pnpm, podman, dapr, git)
make dapr-init     # initialize Dapr (one-time; starts Redis, placement, scheduler)
make up            # start PostgreSQL via Podman Compose
make start         # build and start API server with Dapr sidecar (foreground)
# -> http://localhost:3000
```

## Prerequisites

| Tool                                                               | Version  | Purpose                                                                  |
| ------------------------------------------------------------------ | -------- | ------------------------------------------------------------------------ |
| [GNU Make](https://www.gnu.org/software/make/)                     | 3.81+    | Build orchestration                                                      |
| [Node.js](https://nodejs.org/)                                     | 24.14.1+ | JavaScript runtime (installed by `make deps`)                            |
| [pnpm](https://pnpm.io/)                                           | 10.33.0+ | Package manager (installed by `make deps`)                               |
| [Podman](https://podman.io/)                                       | latest   | Container runtime for PostgreSQL/Redis                                   |
| [Dapr CLI](https://docs.dapr.io/getting-started/install-dapr-cli/) | 1.17.1+  | Dapr sidecar management (installed by `make deps`)                       |
| [Git](https://git-scm.com/)                                        | latest   | Version control                                                          |
| [act](https://github.com/nektos/act)                               | 0.2.87+  | Run GitHub Actions locally (optional, installed by `make deps-act`)      |
| [Trivy](https://trivy.dev/)                                        | 0.69.3+  | Filesystem CVE/secret/misconfig scanner (installed by `make deps-trivy`) |
| [gitleaks](https://github.com/gitleaks/gitleaks)                   | 8.30.1+  | Secret scanner (installed by `make deps-gitleaks`)                       |

Install all required dependencies:

```bash
make deps
```

## Available Make Targets

Run `make help` to see all targets in one list.

### Setup & Dependencies

| Target               | Description                                                             |
| -------------------- | ----------------------------------------------------------------------- |
| `make help`          | List all available tasks                                                |
| `make deps`          | Check and install required dependencies (node, pnpm, podman, dapr, git) |
| `make deps-act`      | Install act for local CI (GitHub Actions runner)                        |
| `make deps-trivy`    | Install Trivy for filesystem security scanning                          |
| `make deps-gitleaks` | Install gitleaks for secret scanning                                    |
| `make install`       | Install npm dependencies (uses `--frozen-lockfile` when `CI=true`)      |
| `make clean`         | Remove build artifacts and node_modules                                 |

### Build & Quality

| Target                  | Description                                                                       |
| ----------------------- | --------------------------------------------------------------------------------- |
| `make build`            | Build TypeScript to `dist/`                                                       |
| `make format`           | Auto-fix formatting with Prettier                                                 |
| `make format-check`     | Check formatting without modifying files                                          |
| `make lint`             | Run Prettier check, ESLint, and TypeScript noEmit                                 |
| `make vulncheck`        | Audit dependencies for known vulnerabilities                                      |
| `make secrets`          | Scan for hardcoded secrets with gitleaks                                          |
| `make trivy-fs`         | Scan filesystem for vulnerabilities, secrets, and misconfigurations               |
| `make deps-prune`       | Show unused/redundant Node.js dependencies                                        |
| `make deps-prune-check` | Verify no prunable dependencies (CI gate)                                         |
| `make static-check`     | Composite quality gate (lint + vulncheck + secrets + trivy-fs + deps-prune-check) |

### Test

| Target                  | Description                                         |
| ----------------------- | --------------------------------------------------- |
| `make test`             | Run unit tests                                      |
| `make test-watch`       | Run unit tests in watch mode                        |
| `make test-integration` | Run integration tests (requires running Dapr stack) |
| `make smoke`            | HTTP smoke test against built server (no Dapr)      |

### Infrastructure

| Target                | Description                                                              |
| --------------------- | ------------------------------------------------------------------------ |
| `make dapr-init`      | Initialize Dapr in local environment (stops conflicting Redis if needed) |
| `make up`             | Start PostgreSQL and Redis via Podman Compose                            |
| `make down`           | Stop infrastructure services and remove containers                       |
| `make postgres-start` | Start standalone PostgreSQL (alternative to `make up`)                   |
| `make postgres-stop`  | Stop standalone PostgreSQL                                               |

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

| Target                        | Description                                                                  |
| ----------------------------- | ---------------------------------------------------------------------------- |
| `make check`                  | Run full local verification (format-check, static-check, test, build)        |
| `make ci`                     | Run local CI pipeline (format-check, static-check, test, build)              |
| `make ci-run`                 | Run GitHub Actions workflow locally via [act](https://github.com/nektos/act) |
| `make release VERSION=vX.Y.Z` | Create and push a release tag                                                |

> The `ci-seed-db` and `ci-dapr-start` Makefile targets exist for the `integration` GitHub Actions job (which provisions PostgreSQL and Dapr CLI on the runner). They are not intended for local use — use `make up` + `make start` locally instead.

### Utilities

| Target                   | Description                                               |
| ------------------------ | --------------------------------------------------------- |
| `make update`            | Update dependencies to latest allowed versions            |
| `make upgrade`           | Upgrade dependencies to latest versions (ignoring ranges) |
| `make renovate`          | Run Renovate locally in dry-run mode                      |
| `make renovate-validate` | Validate Renovate configuration                           |

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

| Service        | Port  | Protocol | Purpose                          |
| -------------- | ----- | -------- | -------------------------------- |
| Express API    | 3000  | HTTP     | REST endpoints                   |
| Dapr sidecar   | 3500  | HTTP     | Binding calls from activities    |
| Dapr sidecar   | 50001 | gRPC     | WorkflowClient / WorkflowRuntime |
| Dapr scheduler | 50006 | gRPC     | Workflow scheduling              |
| PostgreSQL     | 5432  | TCP      | Database backend                 |
| Redis          | 6379  | TCP      | Dapr state store                 |

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

## CI/CD

GitHub Actions runs on every push to `main`, version tags (`v*`), and pull requests. The workflow is reusable via `workflow_call`.

| Job              | Depends on       | Steps                                                                                                                           |
| ---------------- | ---------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| **static-check** | —                | `make static-check` (Prettier check, ESLint, `tsc --noEmit`, `pnpm audit`, gitleaks, Trivy fs scan, depcheck)                   |
| **build**        | static-check     | `make build` + `make smoke` (HTTP smoke test against the built server)                                                          |
| **test**         | static-check     | `make test` (Vitest unit tests)                                                                                                 |
| **e2e**          | build            | `make e2e` (build Docker image, start container, validate HTTP endpoints)                                                       |
| **integration**  | build, test      | `make ci-seed-db`, `make build`, `make ci-dapr-start`, `make test-integration` (PostgreSQL service container + Dapr CLI 1.17.1) |
| **docker**       | build, test, e2e | Tag-gated (`v*` only): multi-arch build + push to GHCR with pre-push security gates (see below)                                 |
| **ci-pass**      | all of the above | Gate job: fails if any upstream job failed                                                                                      |

### Pre-push image hardening

The `docker` job runs the following gates **before** any image is pushed to GHCR. Any gate failure blocks the release.

| #   | Gate                                          | Catches                                                                                     | Tool                                                          |
| --- | --------------------------------------------- | ------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| 1   | Build local single-arch image                 | Build regressions on the runner architecture                                                | `docker/build-push-action` with `load: true`                  |
| 2   | **Trivy image scan** (CRITICAL/HIGH blocking) | CVEs in the base image, OS packages, build layers                                           | `aquasecurity/trivy-action` with `image-ref:`                 |
| 3   | **Smoke test**                                | Image boots correctly on its own (Node.js boot-marker grep)                                 | `make docker-smoke-test`                                      |
| 4   | **ZAP baseline DAST scan**                    | Missing security headers, misconfigs, info leaks                                            | `make dast-scan` ([OWASP ZAP](https://www.zaproxy.org/) `-I`) |
| 5   | Multi-arch build + push                       | Publishes for `linux/amd64` and `linux/arm64`                                               | `docker/build-push-action`                                    |
| 6   | **Multi-arch manifest verification**          | Asserts image index has both platforms and no `unknown/unknown` (catches attestation leaks) | `make docker-verify-manifest`                                 |
| 7   | **Cosign keyless OIDC signing**               | Sigstore signature on the manifest digest                                                   | `sigstore/cosign-installer` + `cosign sign`                   |

Buildkit in-manifest attestations (`provenance` + `sbom`) are disabled so the image index stays free of `unknown/unknown` platform entries, which lets GHCR's Packages UI render the "OS / Arch" tab for the multi-arch manifest. Cosign keyless signing still provides the Sigstore signature for supply-chain verification.

Verify a published image's signature:

```bash
cosign verify ghcr.io/andriykalashnykov/dapr-nodejs-workflow:<tag> \
  --certificate-identity-regexp 'https://github\.com/AndriyKalashnykov/dapr-nodejs-workflow/.+' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

The `cleanup-runs.yml` workflow runs weekly to delete old workflow runs and stale caches via the native `gh` CLI.

[Renovate](https://docs.renovatebot.com/) keeps dependencies up to date with platform automerge enabled. Tool versions pinned in the `Makefile` are tracked via inline `# renovate:` comments.

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
make down          # stop PostgreSQL container
```

## API

| Method | Path                   | Description                                                 |
| ------ | ---------------------- | ----------------------------------------------------------- |
| `GET`  | `/`                    | Health check                                                |
| `POST` | `/process-payload`     | Schedule a new workflow; returns `{ id }` immediately (202) |
| `GET`  | `/workflow/:id/status` | Poll workflow state; `output` only present when complete    |
| `GET`  | `/db-health`           | Schedule a workflow and wait up to 10s for DB result        |

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
make ci            # run format-check, static-check, test, build locally
make ci-run        # run GitHub Actions workflow locally via act (requires Docker)
```

> The `integration` GitHub Actions job uses service containers not supported by `act`. Test integration locally with the steps above.

## References

- [Dapr Concepts](https://docs.dapr.io/concepts/)
- [Dapr Workflows](https://docs.dapr.io/developing-applications/building-blocks/workflow/)
- [Dapr SDK for JavaScript](https://github.com/dapr/js-sdk)

## License

This project is licensed under the MIT License — see [LICENSE](LICENSE) for details.
