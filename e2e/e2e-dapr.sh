#!/usr/bin/env bash
# Full-stack e2e for dapr-nodejs-workflow.
#
# Runs the PRODUCTION Docker image next to a Dapr sidecar on the host. Exercises
# the complete workflow happy path: POST /process-payload -> scheduler ->
# activities (modify, postgres-binding) -> COMPLETED with enriched output.
#
# Prerequisites (supplied by the caller — Makefile / CI):
#   - Postgres reachable on $POSTGRES_HOST:$POSTGRES_PORT (default localhost:5432)
#     with the baseline schema/data loaded (db/baseline_*.sql)
#   - `dapr init` has been run (for scheduler/placement on :50006)
#   - The production image $IMAGE is built and present on the host daemon
#
# Requires Linux host networking (--network host) — same constraint as make dast.

set -euo pipefail

DOCKER="${DOCKER:-docker}"
IMAGE="${IMAGE:?IMAGE is required (e.g. IMAGE=dapr-nodejs-workflow:dev)}"
APP_ID="${APP_ID:-workflow-api-e2e}"
APP_PORT="${APP_PORT:-3100}"
DAPR_GRPC_PORT="${DAPR_GRPC_PORT:-50011}"
DAPR_HTTP_PORT="${DAPR_HTTP_PORT:-3510}"
RESOURCES_PATH="${RESOURCES_PATH:-./components}"
CONTAINER_NAME="${CONTAINER_NAME:-dapr-nodejs-workflow-e2e-dapr}"
COMPLETION_TIMEOUT="${COMPLETION_TIMEOUT:-60}"

cleanup() {
  local exit_code=$?
  echo ""
  echo "=== Cleanup ==="
  dapr stop --app-id "$APP_ID" >/dev/null 2>&1 || true
  "$DOCKER" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  exit "$exit_code"
}
trap cleanup EXIT

echo "=== [1/5] Starting app image $IMAGE on :$APP_PORT ==="
"$DOCKER" run -d \
  --name "$CONTAINER_NAME" \
  --network host \
  -e "PORT=$APP_PORT" \
  -e "DAPR_HOST=localhost" \
  -e "DAPR_GRPC_PORT=$DAPR_GRPC_PORT" \
  -e "DAPR_HTTP_PORT=$DAPR_HTTP_PORT" \
  "$IMAGE" >/dev/null

for i in $(seq 1 30); do
  if curl -sf "http://localhost:$APP_PORT/" >/dev/null 2>&1; then
    break
  fi
  sleep 1
  if [ "$i" -eq 30 ]; then
    echo "FAIL: app container did not bind :$APP_PORT within 30s"
    "$DOCKER" logs "$CONTAINER_NAME"
    exit 1
  fi
done
echo "  app is serving on :$APP_PORT"

echo ""
echo "=== [2/5] Starting Dapr sidecar ($APP_ID, gRPC=$DAPR_GRPC_PORT, HTTP=$DAPR_HTTP_PORT) ==="
dapr run \
  --app-id "$APP_ID" \
  --app-port "$APP_PORT" \
  --app-protocol http \
  --dapr-grpc-port "$DAPR_GRPC_PORT" \
  --dapr-http-port "$DAPR_HTTP_PORT" \
  --scheduler-host-address "localhost:50006" \
  --resources-path "$RESOURCES_PATH" \
  --log-level warn \
  -- sleep 86400 >/tmp/e2e-dapr.log 2>&1 &

for i in $(seq 1 30); do
  if curl -sf "http://localhost:$DAPR_HTTP_PORT/v1.0/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 1
  if [ "$i" -eq 30 ]; then
    echo "FAIL: Dapr sidecar did not become healthy within 30s"
    tail -40 /tmp/e2e-dapr.log || true
    exit 1
  fi
done
echo "  sidecar healthy"

echo ""
echo "=== [3/5] POST /process-payload (delayMs=0) ==="
SCHEDULE_RESP=$(curl -sf -X POST "http://localhost:$APP_PORT/process-payload" \
  -H "Content-Type: application/json" \
  -d '{"delayMs":0,"payload":{"name":"e2e-dapr"}}')
echo "  response: $SCHEDULE_RESP"
WF_ID=$(printf '%s' "$SCHEDULE_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
[ -n "$WF_ID" ] || { echo "FAIL: missing workflow id"; exit 1; }
echo "  workflow id: $WF_ID"

echo ""
echo "=== [4/5] Polling /workflow/$WF_ID/status until COMPLETED (timeout ${COMPLETION_TIMEOUT}s) ==="
DEADLINE=$(( $(date +%s) + COMPLETION_TIMEOUT ))
STATUS=""
OUTPUT=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  STATE=$(curl -sf "http://localhost:$APP_PORT/workflow/$WF_ID/status")
  STATUS=$(printf '%s' "$STATE" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("status",""))')
  echo "  status=$STATUS"
  case "$STATUS" in
    COMPLETED)
      OUTPUT=$(printf '%s' "$STATE" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("output",""))')
      break
      ;;
    FAILED|TERMINATED)
      echo "FAIL: workflow ended in $STATUS"
      echo "  state: $STATE"
      exit 1
      ;;
  esac
  sleep 2
done

if [ "$STATUS" != "COMPLETED" ]; then
  echo "FAIL: workflow did not COMPLETE within ${COMPLETION_TIMEOUT}s (last status: $STATUS)"
  exit 1
fi

echo ""
echo "=== [5/5] Asserting output shape ==="
echo "  output: $OUTPUT"
printf '%s' "$OUTPUT" | grep -q '"processed":true' || { echo "FAIL: processed flag missing"; exit 1; }
printf '%s' "$OUTPUT" | grep -q '"modified":true'  || { echo "FAIL: modified flag missing"; exit 1; }
printf '%s' "$OUTPUT" | grep -q '"processedAt"'    || { echo "FAIL: processedAt field missing"; exit 1; }
printf '%s' "$OUTPUT" | grep -q '"dbData"'         || { echo "FAIL: dbData field missing (postgres binding round-trip)"; exit 1; }
echo "  PASS: payload enriched by modifyPayloadActivity + postgres binding round-tripped"

echo ""
echo "e2e-dapr tests passed"
