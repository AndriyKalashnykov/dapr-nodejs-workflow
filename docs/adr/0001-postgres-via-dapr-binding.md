# ADR-0001: Query PostgreSQL via Dapr binding, not a direct driver

- **Status**: Accepted
- **Date**: 2026-04-28
- **Decision drivers**: portability across Dapr-supported state/binding backends, no per-driver connection-pool management in the app, sidecar handles credential rotation.

## Context

The `dataRequestWorkflow` needs to read rows from PostgreSQL inside an activity. Two options:

1. **Direct driver** — `pg` (or `postgres-js`) opens a TCP connection from the Node.js process to PostgreSQL on `:5432`. The app owns the connection string, the pool, the timeout policy, and the credential rotation story.
2. **Dapr binding** — the app POSTs `{ operation, metadata: { sql, params } }` to `http://localhost:${DAPR_HTTP_PORT}/v1.0/bindings/postgres-db`. The Dapr sidecar owns the connection, the pool, and the credentials (configured in `components/postgres.yaml`).

Both work. The choice shapes operations, not the workflow logic — the activity returns rows either way.

## Decision

Use the Dapr binding (`bindings.postgres`). The app reaches PostgreSQL only through the sidecar's HTTP API; `pg`/`postgres-js` is not a dependency.

## Consequences

**Positive**

- **Credential boundary**: connection strings live in `components/postgres.yaml` (locally) and `dapr/ci/postgres.yaml` (CI), never in app env vars. Rotating the Postgres password is a sidecar redeploy, not an app rebuild.
- **Backend swap**: replacing PostgreSQL with another `bindings.*` component (MySQL, SQL Server, Cosmos DB) is a YAML edit. The activity payload (`{ operation: "query", metadata: { sql } }`) is uniform across SQL-binding backends.
- **One less driver to vet**: no `pg` / `postgres-js` in `package.json` → no transitive CVE surface, no native-binding rebuild on Node major bumps, no Trivy findings against the driver.
- **Same code path in tests**: unit tests, integration tests, and e2e all hit the binding API; production is the same call.

**Negative**

- **HTTP overhead per query**: each `fetchPostgresDataActivity` invocation is a localhost HTTP POST to the sidecar plus the sidecar's own SQL round-trip. For a workflow that reads once per execution this is invisible; for a hot read path it would not be.
- **No prepared statements / no transactions across calls**: the binding API exposes one-shot `query` and `exec` operations. Multi-statement transactions or prepared-statement reuse require either a different component (e.g. `state.postgresql` for state semantics) or the direct-driver fallback.
- **Diagnostic chain is longer**: a slow query is visible in Postgres logs, the sidecar's binding logs, AND the app logs. Tracing setup needs to span all three.

## Alternatives considered

- **`pg` driver in the app** — rejected for the credential-boundary and dependency-surface reasons above. Would be the right choice if the workflow needed transactions, prepared statements, or sub-millisecond reads.
- **Dapr `state.postgresql`** — different abstraction (key/value with optional ETag), wrong shape for "run this SELECT and return rows". Used elsewhere in the project for workflow state via Redis.

## References

- `src/data-request-workflow.ts` — `fetchPostgresDataActivity` is the only place this decision is visible at the code level
- `components/postgres.yaml` / `dapr/ci/postgres.yaml` — the component manifests that own the connection string
- Dapr docs: [PostgreSQL output binding](https://docs.dapr.io/reference/components-reference/supported-bindings/postgresql/)
