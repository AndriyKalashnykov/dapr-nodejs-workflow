#!/usr/bin/env bash
# Workflow durability e2e — Dapr's crown-jewel value prop.
#
# Schedules a workflow with a 15s delay, waits until the activity is running,
# KILLS the app container mid-flight, restarts it, and asserts the workflow
# still COMPLETES. Verifies Dapr replays the workflow from Redis-persisted state.
#
# The Dapr SIDECAR is left running across the restart — only the app container
# is killed. This mirrors a real incident: app pod crashes and is rescheduled,
# sidecar survives or is rescheduled alongside, state is safe.
#
# Prerequisites: same as e2e-dapr.sh.

set -euo pipefail

DOCKER="${DOCKER:-docker}"
IMAGE="${IMAGE:?IMAGE is required (e.g. IMAGE=dapr-nodejs-workflow:dev)}"
APP_ID="${APP_ID:-workflow-api-durability}"
APP_PORT="${APP_PORT:-3110}"
DAPR_GRPC_PORT="${DAPR_GRPC_PORT:-50021}"
DAPR_HTTP_PORT="${DAPR_HTTP_PORT:-3520}"
RESOURCES_PATH="${RESOURCES_PATH:-./components}"
CONTAINER_NAME="${CONTAINER_NAME:-dapr-nodejs-workflow-e2e-durability}"
COMPLETION_TIMEOUT="${COMPLETION_TIMEOUT:-90}"
WORKFLOW_DELAY_MS="${WORKFLOW_DELAY_MS:-15000}"

cleanup() {
  local exit_code=$?
  echo ""
  echo "=== Cleanup ==="
  dapr stop --app-id "$APP_ID" >/dev/null 2>&1 || true
  "$DOCKER" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  exit "$exit_code"
}
trap cleanup EXIT

start_app() {
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
      return 0
    fi
    sleep 1
    if [ "$i" -eq 30 ]; then
      echo "FAIL: app container did not bind :$APP_PORT within 30s"
      "$DOCKER" logs "$CONTAINER_NAME"
      exit 1
    fi
  done
}

echo "=== [1/6] Starting app ==="
start_app
echo "  app is serving on :$APP_PORT"

echo ""
echo "=== [2/6] Starting Dapr sidecar ==="
dapr run \
  --app-id "$APP_ID" \
  --app-port "$APP_PORT" \
  --app-protocol http \
  --dapr-grpc-port "$DAPR_GRPC_PORT" \
  --dapr-http-port "$DAPR_HTTP_PORT" \
  --scheduler-host-address "localhost:50006" \
  --resources-path "$RESOURCES_PATH" \
  --log-level warn \
  -- sleep 86400 >/tmp/e2e-durability.log 2>&1 &

for i in $(seq 1 30); do
  if curl -sf "http://localhost:$DAPR_HTTP_PORT/v1.0/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 1
  if [ "$i" -eq 30 ]; then
    echo "FAIL: Dapr sidecar did not become healthy within 30s"
    tail -40 /tmp/e2e-durability.log || true
    exit 1
  fi
done
echo "  sidecar healthy"

echo ""
echo "=== [3/6] Schedule workflow with delayMs=$WORKFLOW_DELAY_MS ==="
SCHEDULE_RESP=$(curl -sf -X POST "http://localhost:$APP_PORT/process-payload" \
  -H "Content-Type: application/json" \
  -d "{\"delayMs\":$WORKFLOW_DELAY_MS,\"payload\":{\"name\":\"durability-test\"}}")
WF_ID=$(printf '%s' "$SCHEDULE_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
[ -n "$WF_ID" ] || { echo "FAIL: missing workflow id"; exit 1; }
echo "  workflow id: $WF_ID"

echo ""
echo "=== [4/6] Wait 5s so delayActivity is mid-flight, then KILL app container ==="
sleep 5
PRE_KILL_STATUS=$(curl -sf "http://localhost:$APP_PORT/workflow/$WF_ID/status" | \
  python3 -c 'import sys,json; print(json.load(sys.stdin).get("status",""))')
echo "  pre-kill status: $PRE_KILL_STATUS"
if [ "$PRE_KILL_STATUS" = "COMPLETED" ]; then
  echo "FAIL: workflow completed before we could kill the app — increase WORKFLOW_DELAY_MS"
  exit 1
fi

"$DOCKER" kill "$CONTAINER_NAME" >/dev/null
"$DOCKER" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
echo "  app container killed"

echo ""
echo "=== [5/6] Restart app container (sidecar still alive, Redis state preserved) ==="
start_app
echo "  app is back on :$APP_PORT"

echo ""
echo "=== [6/6] Poll /workflow/$WF_ID/status until COMPLETED (timeout ${COMPLETION_TIMEOUT}s) ==="
DEADLINE=$(( $(date +%s) + COMPLETION_TIMEOUT ))
STATUS=""
OUTPUT=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  STATE=$(curl -sf "http://localhost:$APP_PORT/workflow/$WF_ID/status" 2>/dev/null || echo "")
  if [ -n "$STATE" ]; then
    STATUS=$(printf '%s' "$STATE" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("status",""))')
    echo "  status=$STATUS"
    case "$STATUS" in
      COMPLETED)
        OUTPUT=$(printf '%s' "$STATE" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("output",""))')
        break
        ;;
      FAILED|TERMINATED)
        echo "FAIL: workflow ended in $STATUS after restart"
        echo "  state: $STATE"
        exit 1
        ;;
    esac
  fi
  sleep 2
done

if [ "$STATUS" != "COMPLETED" ]; then
  echo "FAIL: workflow did not COMPLETE within ${COMPLETION_TIMEOUT}s after restart (last: $STATUS)"
  exit 1
fi

echo "  output: $OUTPUT"
printf '%s' "$OUTPUT" | grep -q '"processed":true' || { echo "FAIL: processed flag missing after replay"; exit 1; }
printf '%s' "$OUTPUT" | grep -q '"dbData"'         || { echo "FAIL: dbData missing — postgres binding did not re-execute on replay"; exit 1; }

echo ""
echo "e2e-durability tests passed — workflow survived container restart"
