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

Once the server is running, you can trigger a new activity sequence workflow by making a POST request to the `/schedule-activity-sequence` endpoint:
```bash
curl -X POST http://localhost:3000/process-payload \
  -H "Content-Type: application/json" \
  -d '{"name": "John Doe", "data": {"key1": "value1", "key2": "value2"}}'
```

This will return a JSON response with the workflow ID, which you can then use to check the status:
```bash
curl http://localhost:3000/workflow/{workflow-id}/status

curl http://localhost:3000/db-health
```

### References

* [Dapr Concepts](https://docs.dapr.io/concepts/)
* [Dapr Workflows](https://docs.dapr.io/developing-applications/building-blocks/workflow/)
* [Dapr SDK for JavaScript](https://github.com/dapr/js-sdk)