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

## CI

Run the GitHub Actions CI pipeline locally (requires Docker):

```bash
make ci
```

## References

* [Dapr Concepts](https://docs.dapr.io/concepts/)
* [Dapr Workflows](https://docs.dapr.io/developing-applications/building-blocks/workflow/)
* [Dapr SDK for JavaScript](https://github.com/dapr/js-sdk)
