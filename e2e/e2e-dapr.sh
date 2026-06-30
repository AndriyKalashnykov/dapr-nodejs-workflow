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

# Pick a free TCP port from the kernel's ephemeral range. Avoids collision with
# `make dast`/`docker-smoke-test`/parallel runs and with the Dapr CLI standalone
# mode's :3500/:50001 if a prior `dapr run` is still up.
pick_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

DOCKER="${DOCKER:-docker}"
IMAGE="${IMAGE:?IMAGE is required (e.g. IMAGE=dapr-nodejs-workflow:dev)}"
HOST="${HOST:-localhost}"
APP_ID="${APP_ID:-workflow-api-e2e}"
APP_PORT="${APP_PORT:-$(pick_port)}"
DAPR_GRPC_PORT="${DAPR_GRPC_PORT:-$(pick_port)}"
DAPR_HTTP_PORT="${DAPR_HTTP_PORT:-$(pick_port)}"
DAPR_SCHEDULER_PORT="${DAPR_SCHEDULER_PORT:-50006}"
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

echo "=== [1/6] Starting app image $IMAGE on :$APP_PORT ==="
"$DOCKER" run -d \
  --name "$CONTAINER_NAME" \
  --network host \
  -e "PORT=$APP_PORT" \
  -e "DAPR_HOST=$HOST" \
  -e "DAPR_GRPC_PORT=$DAPR_GRPC_PORT" \
  -e "DAPR_HTTP_PORT=$DAPR_HTTP_PORT" \
  "$IMAGE" >/dev/null

for i in $(seq 1 30); do
  if curl -sf "http://$HOST:$APP_PORT/" >/dev/null 2>&1; then
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
echo "=== [2/6] Starting Dapr sidecar ($APP_ID, gRPC=$DAPR_GRPC_PORT, HTTP=$DAPR_HTTP_PORT) ==="
dapr run \
  --app-id "$APP_ID" \
  --app-port "$APP_PORT" \
  --app-protocol http \
  --dapr-grpc-port "$DAPR_GRPC_PORT" \
  --dapr-http-port "$DAPR_HTTP_PORT" \
  --scheduler-host-address "$HOST:$DAPR_SCHEDULER_PORT" \
  --resources-path "$RESOURCES_PATH" \
  --log-level warn \
  -- sleep 86400 >/tmp/e2e-dapr.log 2>&1 &

for i in $(seq 1 30); do
  if curl -sf "http://$HOST:$DAPR_HTTP_PORT/v1.0/healthz" >/dev/null 2>&1; then
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
echo "=== [3/6] POST /process-payload (delayMs=0) ==="
SCHEDULE_RESP=$(curl -sf -X POST "http://$HOST:$APP_PORT/process-payload" \
  -H "Content-Type: application/json" \
  -d '{"delayMs":0,"payload":{"name":"e2e-dapr"}}')
echo "  response: $SCHEDULE_RESP"
WF_ID=$(printf '%s' "$SCHEDULE_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
[ -n "$WF_ID" ] || { echo "FAIL: missing workflow id"; exit 1; }
echo "  workflow id: $WF_ID"

echo ""
echo "=== [4/6] Polling /workflow/$WF_ID/status until COMPLETED (timeout ${COMPLETION_TIMEOUT}s) ==="
DEADLINE=$(( $(date +%s) + COMPLETION_TIMEOUT ))
STATUS=""
OUTPUT=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  STATE=$(curl -sf "http://$HOST:$APP_PORT/workflow/$WF_ID/status")
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
echo "=== [5/6] Asserting output shape ==="
echo "  output: $OUTPUT"

# JSON-parse + structural assertions. `grep -q '"processed":true'` would pass
# for any substring match (e.g. nested fields with the same key); parsing catches
# regressions where the binding silently returns an empty payload or an error
# envelope under the dbData key.
#
# Pattern: capture script via $()-quoted-heredoc (no shell expansion), feed JSON
# via stdin pipe, run via `python3 -c "$SCRIPT"`. Avoids two collisions:
#   - `python3 - <<'PY'` eats stdin for the heredoc → JSON pipe lost
#   - `python3 -c '… "k" \"v\" …'` mixes shell and Python escaping → SyntaxError
PYSCRIPT=$(cat <<'PYSCRIPT_EOF'
import json, sys
output = json.loads(sys.stdin.read())
assert output.get("processed") is True, "processed flag not True: " + repr(output.get("processed"))
assert output.get("modified")  is True, "modified flag not True: "  + repr(output.get("modified"))
assert isinstance(output.get("processedAt"), str) and output["processedAt"], "processedAt missing or empty"
db = output.get("dbData")
assert db is not None, "dbData missing"
# Postgres binding returns a non-empty array of rows (or a wrapped object) when
# the seed data is present. An empty list/dict means the binding round-tripped
# but returned nothing — usually a seed/CI race.
if isinstance(db, list):
    assert len(db) > 0, "dbData is an empty list - postgres binding returned no rows"
elif isinstance(db, dict):
    assert "error" not in db, "dbData carries error envelope: " + repr(db)
    assert db, "dbData is an empty dict"
else:
    raise AssertionError("dbData unexpected type " + type(db).__name__ + ": " + repr(db))
print("  payload structure OK")
PYSCRIPT_EOF
)
printf '%s' "$OUTPUT" | python3 -c "$PYSCRIPT"
echo "  PASS: payload enriched by modifyPayloadActivity + postgres binding round-tripped"

echo ""
echo "=== [6/6] GET /db-health (own workflow + Postgres round-trip via the prod image) ==="
# /db-health has its own logic path (waitForWorkflowCompletion + JSON.parse of the
# binding result) not exercised by the /process-payload flow above — assert it
# end-to-end through the production image, not only at the integration layer.
DB_HEALTH=$(curl -sf "http://$HOST:$APP_PORT/db-health")
echo "  response: $DB_HEALTH"
DBH_PYSCRIPT=$(cat <<'DBH_EOF'
import json, sys
body = json.loads(sys.stdin.read())
assert body.get("status") == "success", "db-health status not success: " + repr(body.get("status"))
assert body.get("dbConnection") == "working", "dbConnection not working: " + repr(body.get("dbConnection"))
print("  db-health OK")
DBH_EOF
)
printf '%s' "$DB_HEALTH" | python3 -c "$DBH_PYSCRIPT"
echo "  PASS: /db-health reports a working Postgres binding through the prod image"

echo ""
echo "e2e-dapr tests passed"
