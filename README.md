# dapr-nodejs-workflow

## Prerequisites

* Linux OS
* [Docker](https://www.docker.com/)
* [Git](https://git-scm.com/downloads)
* [Dapr](https://dapr.io/)
* [Node.js](https://nodejs.org/en/)
* [pnpm](https://pnpm.io/)

## Clone the repository

```bash
mkdir ~/projects && cd ~/projects
git clone git@github.com:AndriyKalashnykov/dapr-nodejs-workflow.git && cd ~/projects/dapr-nodejs-workflow
```

## Install and Initialize Dapr in your local environment

* [Install the Dapr CLI](https://docs.dapr.io/getting-started/install-dapr-cli/)
* [Initialize Dapr in your local environment](https://docs.dapr.io/getting-started/install-dapr-selfhost/) 

## Start PostgreSQL

```bash
./run-postgres.sh
```

## Running the example

```bash
# Install
pnpm install
pnpm build && pnpm run start:dapr:api-server
```

Once the server is running, you can trigger a new activity sequence workflow by making a POST request to the `/process-payload` endpoint:
```bash
curl -X POST http://localhost:3000/process-payload \
  -H "Content-Type: application/json" \
  -d '{"name": "John Doe", "data": {"key1": "value1", "key2": "value2"}}'
```

This will return a JSON response with the workflow ID, which you can then use to check the status when delayActivity called and pending:
```bash
curl http://localhost:3000/workflow/{workflow-id}/status | jq .
```
response would not have the `output` property
```json
{
  "id": "82236756-4f38-4b5f-9796-a1268184561e",
  "status": "0",
  "createdAt": "2025-09-16T16:34:44.118Z",
  "lastUpdatedAt": "2025-09-16T16:34:47.139Z"
}
```

and then you can check deleyActivity is done:
```bash
curl http://localhost:3000/workflow/{workflow-id}/status | jq .
```
response would have the `output` property
```json
{
  "id": "82236756-4f38-4b5f-9796-a1268184561e",
  "status": "1",
  "output": "{\"name\":\"John Doe\",\"data\":{\"key1\":\"value1\",\"key2\":\"value2\"},\"processed\":true,\"processedAt\":\"2025-09-16T16:35:21.171Z\",\"modified\":true,\"dbData\":[[1,\"2025-09-15T22:57:13.170558-04:00\",\"2025-09-15T22:57:13.170558-04:00\",null,\"john.doe@example.com\",\"hashed_password_1\",\"John\",\"Doe\",\"1980-01-01T00:00:00-05:00\",null,\"USA\",\"American\",null,false,null],[2,\"2025-09-15T22:57:13.170558-04:00\",\"2025-09-15T22:57:13.170558-04:00\",null,\"jane.smith@example.com\",\"hashed_password_2\",\"Jane\",\"Smith\",\"1985-05-15T00:00:00-04:00\",null,\"Canada\",\"Canadian\",null,true,null]]}",
  "createdAt": "2025-09-16T16:34:44.118Z",
  "lastUpdatedAt": "2025-09-16T16:35:21.199Z"
}

```

check DB status
```bash
curl http://localhost:3000/db-health
```

### References

* [Dapr Concepts](https://docs.dapr.io/concepts/)
* [Dapr Workflows](https://docs.dapr.io/developing-applications/building-blocks/workflow/)
* [Dapr SDK for JavaScript](https://github.com/dapr/js-sdk)