# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Dapr Workflow demo using the Dapr JS SDK with an Express HTTP API frontend. A single Node.js/TypeScript service runs alongside a Dapr sidecar that orchestrates durable workflows with PostgreSQL and Redis backends. Container runtime is Podman (Docker-compatible).

## Quick Start

```bash
# One-time setup
make deps                # Bootstrap mise + install node/pnpm (from .nvmrc / .mise.toml), then check podman + git
make dapr-init           # Initialize Dapr (starts Redis, placement, scheduler containers)

# Start infrastructure + server (two terminals)
make up                  # Terminal 1: start PostgreSQL + Redis via Podman Compose
make start               # Terminal 2: build and start API server with Dapr sidecar (foreground)

# Verify (from another terminal)
make check-workflow      # Trigger a test workflow and poll the result
make check-db            # Run the database health check endpoint

# Run tests (three-layer pyramid)
make test                # Unit tests (Vitest, seconds)
make integration-test    # Integration tests with running Dapr stack (tens of seconds)
make e2e                 # End-to-end against the production Docker image (minutes)

# Stop everything
make stop                # Stop Dapr sidecar and API server
make down                # Stop PostgreSQL + Redis containers
```

## Makefile Targets

Run `make help` for the full list. Key targets grouped by purpose:

### Setup & Dependencies

| Target           | Description                                                                                                                                                                            |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `make deps`      | Bootstrap mise (once) and install every pinned tool (node from `.nvmrc`; pnpm, act, dapr, gitleaks, hadolint, trivy from `.mise.toml`); check podman + git (CI skips the podman check) |
| `make install`   | Install npm dependencies (uses `--frozen-lockfile` when `CI=true`)                                                                                                                     |
| `make dapr-init` | Initialize Dapr in local environment (stops conflicting Redis if needed)                                                                                                               |

### Build & Quality

| Target                  | Description                                                                                                                                                                     |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `make build`            | Compile TypeScript to `dist/`                                                                                                                                                   |
| `make format`           | Auto-fix formatting with Prettier                                                                                                                                               |
| `make format-check`     | Check formatting without modifying files                                                                                                                                        |
| `make lint`             | Run Prettier check, ESLint (zero warnings), `tsc --noEmit`, and hadolint on the Dockerfile                                                                                      |
| `make vulncheck`        | Audit dependencies for known vulnerabilities (`pnpm audit --audit-level=moderate`)                                                                                              |
| `make secrets`          | Scan for hardcoded secrets with gitleaks                                                                                                                                        |
| `make trivy-fs`         | Scan filesystem for vulnerabilities, secrets, and misconfigurations                                                                                                             |
| `make deps-prune`       | Show unused/redundant Node.js dependencies                                                                                                                                      |
| `make deps-prune-check` | Verify no prunable dependencies (CI gate)                                                                                                                                       |
| `make components-check` | Drift gate: fails if `components/*.yaml` and `dapr/ci/*.yaml` differ beyond password/comments                                                                                   |
| `make mermaid-lint`     | Validate Mermaid diagrams in `README.md` and `CLAUDE.md` via pinned `minlag/mermaid-cli` — same engine GitHub renders with                                                      |
| `make diagrams`         | Render the C4 PlantUML sources (`docs/diagrams/*.puml`) to committed PNGs via pinned `plantuml/plantuml`                                                                        |
| `make diagrams-clean`   | Remove rendered diagram artefacts (`docs/diagrams/out/`)                                                                                                                        |
| `make diagrams-check`   | Drift gate: re-render the C4 diagrams and fail if the committed PNGs differ from current `.puml` source                                                                         |
| `make static-check`     | Composite quality gate: `lint` + `vulncheck` + `secrets` + `trivy-fs` + `deps-prune-check` + `components-check` + `diagrams-check` + `mermaid-lint`. CI calls this single step. |
| `make check`            | Full local verification: `static-check` + `test` + `build` (static-check runs lint which runs prettier --check)                                                                 |

### Infrastructure

| Target                | Description                                           |
| --------------------- | ----------------------------------------------------- |
| `make up`             | Start PostgreSQL + Redis via Podman Compose           |
| `make down`           | Stop and remove Podman Compose containers             |
| `make postgres-start` | Start PostgreSQL in Podman (alternative to `make up`) |
| `make postgres-stop`  | Stop PostgreSQL Podman container                      |

### Run

| Target               | Description                                                      |
| -------------------- | ---------------------------------------------------------------- |
| `make start`         | Build and start API server with Dapr sidecar (foreground)        |
| `make stop`          | Stop the Dapr sidecar and API server                             |
| `make start-no-dapr` | Build and start API server without Dapr (HTTP health check only) |
| `make run`           | Alias for `start-no-dapr`                                        |

### Test & Verify

| Target                        | Description                                                                                                              |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `make test`                   | Run unit tests                                                                                                           |
| `make test-watch`             | Run unit tests in watch mode                                                                                             |
| `make integration-test`       | Run integration tests (requires running Dapr stack + PostgreSQL)                                                         |
| `make smoke`                  | HTTP smoke test against built server (no Dapr)                                                                           |
| `make e2e`                    | Shallow e2e: runs the production image standalone and verifies the Dapr-unreachable error path                           |
| `make e2e-dapr`               | Full-stack e2e: runs the production image alongside a real Dapr sidecar and asserts a workflow COMPLETES                 |
| `make e2e-durability`         | Workflow replay e2e: kills the app mid-flight and asserts the workflow still COMPLETES from Redis-persisted state        |
| `make dast`                   | ZAP baseline DAST scan (local: builds image, runs container, scans, cleans up)                                           |
| `make docker-smoke-test`      | Boot-marker smoke test; starts `smoke-test` container and leaves it running for DAST (CI)                                |
| `make dast-scan`              | Run ZAP scan against an already-running container on `localhost:3100` (CI)                                               |
| `make docker-verify-manifest` | Assert a published multi-arch image has `linux/amd64` + `linux/arm64` and no attestations (CI; requires `IMAGE_REF=...`) |
| `make check-workflow`         | Trigger a workflow via API and poll its status                                                                           |
| `make check-db`               | Hit the `/db-health` endpoint                                                                                            |

### CI & Release

| Target                        | Description                                                                                                   |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `make ci`                     | Run local CI pipeline (`static-check`, `test`, `build`; `format-check` runs inside `static-check` via `lint`) |
| `make ci-run`                 | Run GitHub Actions workflow locally via `act` (requires Docker)                                               |
| `make ci-run-tag`             | Run the workflow via `act` with a tag event (exercises the docker job)                                        |
| `make release VERSION=vX.Y.Z` | Tag and push a release                                                                                        |

The `ci-seed-db`, `ci-dapr-start`, `docker-smoke-test`, `dast-scan`, and `docker-verify-manifest` Makefile targets exist exclusively for the GitHub Actions `integration-test` and `docker` jobs and are not intended for local use — use `make up` + `make start` (integration) or `make dast` / `make e2e` / `make image-*` (image workflow) locally instead.

### Docker & Image

| Target             | Description                                                |
| ------------------ | ---------------------------------------------------------- |
| `make image-build` | Build the production Docker image (multi-stage distroless) |
| `make image-run`   | Run the built image standalone (no Dapr)                   |
| `make image-stop`  | Stop the running image container                           |

## Architecture

### Project Layout

```
src/
  api-server.ts              Entrypoint: imports app, calls listen, wires SIGINT
  app.ts                     Express app, lazy-init WorkflowRuntime + DaprWorkflowClient, exported for tests
  data-request-workflow.ts   dataRequestWorkflow generator and activities
  __tests__/
    *.test.ts                Unit tests (Vitest; supertest against the exported app)
    *.integration.test.ts    Integration tests (require running Dapr stack)
e2e/
  e2e-dapr.sh                Full-stack e2e: production image + Dapr sidecar + workflow happy-path
  e2e-durability.sh          Durability e2e: kill app mid-flight, assert workflow resumes
components/                  Dapr component configs -- local dev
  postgres.yaml              bindings.postgres (password: daprrulz)
  redis.yaml                 state.redis (localhost:6379)
dapr/ci/                     Dapr component configs -- CI
  postgres.yaml              bindings.postgres (password: postgres)
  redis.yaml                 state.redis (localhost:6379)
docs/
  diagrams/                  C4 architecture diagrams (PlantUML source + committed PNGs)
    c4-context.puml          System Context — rendered to out/c4-context.png (README hero)
    c4-container.puml        Container View — rendered to out/c4-container.png
    out/                     Rendered PNGs (committed; render-trigger stamp gitignored)
  adr/                       Architecture Decision Records
db/                          Schema and seed data
  baseline_ddl.sql           Table schema (users table)
  baseline_dml.sql           Seed data
docker-compose.yaml          PostgreSQL + Redis for local development
Dockerfile                   Multi-stage production image (distroless, non-root)
.dockerignore                Excludes non-runtime files from build context
.hadolint.yaml               Hadolint Dockerfile linter configuration
.mise.toml                   mise tool pins (pnpm); Node pinned via .nvmrc
.nvmrc                       Node major version; read by mise and actions/setup-node
pnpm-workspace.yaml          pnpm `overrides` + `allowBuilds` (security pins; v11+ renamed `onlyBuiltDependencies` and ignores the legacy package.json location)
```

### Request Flow

```mermaid
sequenceDiagram
  autonumber
  participant U as API Consumer
  participant A as Express API<br/>(+ WorkflowRuntime)
  participant D as Dapr Sidecar
  participant P as PostgreSQL

  U->>A: POST /process-payload
  A->>D: scheduleNewWorkflow (gRPC :50001)
  D-->>A: workflow id
  A-->>U: 202 { id }
  Note over D,A: Activity dispatch via gRPC streaming
  D->>A: delayActivity (30s default, 0 in tests)
  D->>A: modifyPayloadActivity (enrich payload)
  D->>A: fetchPostgresDataActivity
  A->>D: POST /v1.0/bindings/postgres-db (HTTP :3500)
  D->>P: SELECT * FROM users
  P-->>D: rows
  D-->>A: rows -> dbData
  Note over D: State persisted to Redis after each activity
  U->>A: GET /workflow/:id/status
  A->>D: getWorkflowState (gRPC)
  D-->>A: COMPLETED + output
  A-->>U: 200 { status, output }
```

Architecture diagrams live in `README.md` under `## Architecture`. The C4 **Context** and **Container** views are [C4-PlantUML](https://github.com/plantuml-stdlib/C4-PlantUML) sources in `docs/diagrams/*.puml`, rendered to committed PNGs by `make diagrams` and guarded against drift by `make diagrams-check` (in `static-check`). The **Workflow Sequence** and **Durability** diagrams are inline Mermaid that GitHub renders directly (validated by `make mermaid-lint`). `PLANTUML_VERSION` in the `Makefile` is intentionally not Renovate-tracked — see the Upgrade Backlog.

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

| Method | Path                   | Description                                                                                                                          |
| ------ | ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `GET`  | `/`                    | Health check -- returns `{ message }`                                                                                                |
| `POST` | `/process-payload`     | Schedules a new workflow; returns `{ id }` (202). Empty body returns 400. Optional `delayMs` override (default 30000 — tests use 0). |
| `GET`  | `/workflow/:id/status` | Polls workflow state; `output` only present when complete. Unknown id returns 404.                                                   |
| `GET`  | `/db-health`           | Schedules a workflow and waits up to 10s for completion                                                                              |

### CI Pipeline (`.github/workflows/ci.yml`)

The CI pipeline runs on pushes to `main`, version tags (`v*`), pull requests, and is reusable via `workflow_call`. Jobs:

- **changes**: lightweight detector job using `dorny/paths-filter` that emits `code=true` for code changes and `code=false` for doc-only changes (`*.md`, `docs/**`, image assets, etc., with `CLAUDE.md` re-included as project config). Heavy jobs gate on `needs.changes.outputs.code == 'true'`, so doc-only PRs skip them and `ci-pass` reports green via skipped-jobs (compatible with the active Repository Ruleset's required-check gate). Replaces trigger-level `paths-ignore`, which deadlocks against Rulesets.
- **static-check**: `make static-check` — Prettier check + ESLint + `tsc --noEmit` + hadolint + `pnpm audit` + gitleaks + Trivy filesystem scan + depcheck + `components-check` (local vs CI Dapr component drift gate) + `diagrams-check` (C4 PlantUML source vs committed PNG drift gate) + `mermaid-lint` — single composite quality gate
- **build**: `make build` + `make smoke` (HTTP smoke test against the built server, no Dapr)
- **test**: `make test` (Vitest unit tests — activity unit tests, supertest-based HTTP tests, `checkPort` helper)
- **e2e**: `make e2e` — build Docker image, run container, validate health endpoint and Dapr lazy-init error handling (shallow e2e; no Dapr sidecar)
- **e2e-dapr**: `make ci-seed-db` + builds the image + `./e2e/e2e-dapr.sh` (PostgreSQL service container, Dapr CLI, production image running alongside `dapr run` sidecar). Verifies a real workflow COMPLETES end-to-end with `processed:true` + `dbData` from the Postgres binding. Skipped under act (`vars.ACT=true`).
- **integration-test**: `make ci-seed-db` + `make build` + `make ci-dapr-start` + `make integration-test` (PostgreSQL service container, Dapr CLI 1.17.1, full-stack Vitest integration tests; covers 404, 400, COMPLETED happy path with `delayMs:0`). Skipped under act (`vars.ACT=true`) because service containers aren't supported.
- **dast**: `make docker-smoke-test` + `make dast-scan` — rebuilds the production image via `cache-from: type=gha` (≈10s cache hit from the `docker` job), starts it, runs OWASP ZAP baseline scan against `localhost:3100`, uploads the ZAP report as an artifact. Skipped under act (`vars.ACT=true`) because ZAP's docker-in-docker bind mount doesn't round-trip through the host Docker daemon.
- **docker**: runs on every push in parallel with `e2e` and `dast`. Gates 1–3 (single-arch build, Trivy image scan CRITICAL/HIGH blocking, boot-marker smoke test via `make docker-smoke-test`) and Gate 4 (multi-arch build via `docker/build-push-action`) always run — catches arm64 cross-compile regressions and cosign installer breakage on the commit that introduced them. On tag pushes only, step-level `if: startsWith(github.ref, 'refs/tags/')` gates `Log in to GHCR`, `push: ${{ ... }}` on the multi-arch build, `Verify multi-arch manifest` via `make docker-verify-manifest`, `Install cosign`, and `Sign image with cosign` (Sigstore keyless OIDC signing by digest). Buildkit in-manifest attestations (`provenance`/`sbom`) are explicitly disabled to keep the image index clean of `unknown/unknown` platform entries so GHCR's Packages UI renders the "OS / Arch" tab.
- **ci-pass**: gate job — runs after all upstream jobs and fails if any of them failed; intended as the single status check for branch protection

Job dependencies: `changes` -> `static-check` -> `build` + `test` (parallel) -> `e2e` + `e2e-dapr` + `integration-test` + `dast` + `docker` (all five parallel; `e2e`/`e2e-dapr`/`integration-test`/`dast` need `[changes, build, test]`, `docker` needs `[changes, static-check, build, test]`) -> `ci-pass` (lists every upstream job including `changes` in its `needs:`).

CI uses `--frozen-lockfile` for reproducible builds. The Makefile sets `PNPM_INSTALL := pnpm install $(if $(CI),--frozen-lockfile,)`, so `make install` automatically picks the right mode based on the `CI` environment variable.

A second workflow, `.github/workflows/cleanup-runs.yml`, runs weekly to delete old workflow runs and stale caches via the native `gh` CLI (no third-party actions).

**Local CI**: `make ci` runs `static-check` (which internally runs `format-check` via `lint`), `test`, and `build` locally. `make ci-run` runs the GitHub Actions workflow via `act` (its event payload includes `repository.default_branch` so `dorny/paths-filter` resolves the diff base correctly). The `integration-test` job requires service containers not supported by `act`; test integration locally with `make up` + `make start` + `make integration-test` instead.

## Key Environment Variables

| Variable         | Default     | Purpose                                                                                                   |
| ---------------- | ----------- | --------------------------------------------------------------------------------------------------------- |
| `PORT`           | `3000`      | Express listen port                                                                                       |
| `HOST`           | `localhost` | Express bind host (also threaded through every Makefile target as `$(HOST)`)                              |
| `DAPR_HOST`      | `localhost` | Dapr sidecar hostname used by `DaprWorkflowClient` / `WorkflowRuntime` (gRPC)                             |
| `DAPR_GRPC_PORT` | `50001`     | Dapr sidecar gRPC port used by `DaprWorkflowClient` / `WorkflowRuntime`                                   |
| `DAPR_HTTP_PORT` | `3500`      | Dapr sidecar HTTP port (read by `fetchPostgresDataActivity` for binding calls)                            |
| `CI`             | unset       | When set (e.g. by GitHub Actions), `deps` skips podman/dapr checks and `install` uses `--frozen-lockfile` |

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

### Known architectural gaps (monitor upstream)

- [ ] `@dapr/dapr` bundles Express 4 internally — `path-to-regexp` vuln patched via pnpm override (`pnpm-workspace.yaml`); monitor upstream Dapr JS SDK for express 5 migration so the override can be removed
- [ ] Ubuntu 26.04 LTS shipped Apr 2026 — actively track the GitHub Actions `ubuntu-latest` runner migration (runners transition in stages after the release) and bump any hardcoded `ubuntu-24.04` / `ubuntu-22.04` `runs-on:` pins when the new image is stable
- [ ] **`PLANTUML_VERSION` (Makefile) is manually bumped, not Renovate-tracked.** The committed C4 PNGs are a generated artifact guarded by `make diagrams-check`; the hosted Renovate app can't run `make diagrams` to regenerate them, so a tracked bump PR would sit permanently RED on the drift gate under this repo's automerge. To bump: edit the `plantuml/plantuml` tag, run `make diagrams`, and commit the source + regenerated PNGs together. (Re-evaluate if a regen-and-commit-back CI workflow with an App/PAT token is ever added — a Ruleset-gated repo needs a non-`GITHUB_TOKEN` push for the commit-back.)

## Skills

Use the following skills when working on related files:

| File(s)                          | Skill          |
| -------------------------------- | -------------- |
| `Makefile`                       | `/makefile`    |
| `renovate.json`                  | `/renovate`    |
| `README.md`                      | `/readme`      |
| `.github/workflows/*.{yml,yaml}` | `/ci-workflow` |

When spawning subagents, always pass conventions from the respective skill into the agent's prompt.
