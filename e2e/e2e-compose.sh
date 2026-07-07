#!/usr/bin/env bash
set -euo pipefail

# E2E for the docker-compose.yaml CONFIG itself — CI's integration-test/e2e-dapr
# jobs use a Postgres SERVICE CONTAINER, so the compose file's own config
# (postgres:18 data-dir mount, redis maxmemory flags, healthchecks, seed-data
# init scripts, the pg-data volume) is otherwise exercised only locally via
# `make up`. This harness boots the stack, proves it comes up healthy and that
# the seeded schema is queryable + Redis round-trips, then tears it down.
#
# Ports are the compose FIXED host ports (operator-tunable, mirror .env.example);
# the Makefile passes them in. Timing knobs reuse the shared .env.example names.

DOCKER="${DOCKER:-$(command -v docker || command -v podman)}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
REDIS_PORT="${REDIS_PORT:-6379}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_READY_TIMEOUT="${POSTGRES_READY_TIMEOUT:-60}"
REDIS_READY_TIMEOUT="${REDIS_READY_TIMEOUT:-30}"
BOOT_POLL_INTERVAL="${BOOT_POLL_INTERVAL:-1}"

cd "$(dirname "$0")/.."

cleanup() { "$DOCKER" compose down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Bringing up compose stack (POSTGRES_PORT=$POSTGRES_PORT REDIS_PORT=$REDIS_PORT via $DOCKER)"
POSTGRES_PORT="$POSTGRES_PORT" REDIS_PORT="$REDIS_PORT" "$DOCKER" compose up -d

echo "==> Waiting for Postgres to accept connections (<= ${POSTGRES_READY_TIMEOUT}s)"
pg_deadline=$(( $(date +%s) + POSTGRES_READY_TIMEOUT ))
until "$DOCKER" compose exec -T postgres pg_isready -U "$POSTGRES_USER" >/dev/null 2>&1; do
  [ "$(date +%s)" -ge "$pg_deadline" ] && {
    echo "ERROR: Postgres did not become ready in ${POSTGRES_READY_TIMEOUT}s"
    "$DOCKER" compose ps
    exit 1
  }
  sleep "$BOOT_POLL_INTERVAL"
done

echo "==> Waiting for Redis to accept connections (<= ${REDIS_READY_TIMEOUT}s)"
rd_deadline=$(( $(date +%s) + REDIS_READY_TIMEOUT ))
until [ "$("$DOCKER" compose exec -T redis redis-cli ping 2>/dev/null | tr -d '[:space:]')" = "PONG" ]; do
  [ "$(date +%s)" -ge "$rd_deadline" ] && {
    echo "ERROR: Redis did not become ready in ${REDIS_READY_TIMEOUT}s"
    "$DOCKER" compose ps
    exit 1
  }
  sleep "$BOOT_POLL_INTERVAL"
done
echo "    both services accept connections."

# Postgres: the seeded users table is only populated if the init scripts under
# /docker-entrypoint-initdb.d ran, which happens only on a FRESH data dir — so a
# non-empty count also proves the pg-data volume mount at /var/lib/postgresql
# (the postgres:18 path) is correct (a wrong mount makes 18 refuse to start).
echo "==> Postgres: querying the seeded users table"
rows=$("$DOCKER" compose exec -T postgres psql -U "$POSTGRES_USER" -tAc 'SELECT count(*) FROM users;' | tr -d '[:space:]')
echo "    users rows: ${rows:-<none>}"
[ -n "$rows" ] && [ "$rows" -ge 1 ] 2>/dev/null || {
  echo "ERROR: expected >= 1 seeded user row, got '${rows}'"
  exit 1
}

# Redis: ping + a set/get round-trip proves the container booted with its
# maxmemory/eviction command-line config (a bad flag would crash-loop it).
echo "==> Redis: set/get round-trip"
"$DOCKER" compose exec -T redis redis-cli set e2e_compose_probe ok >/dev/null
[ "$("$DOCKER" compose exec -T redis redis-cli get e2e_compose_probe | tr -d '[:space:]')" = "ok" ] || {
  echo "ERROR: Redis set/get round-trip failed"
  exit 1
}

echo "==> e2e-compose PASSED (stack healthy; Postgres seeded + queryable; Redis round-trips)"
