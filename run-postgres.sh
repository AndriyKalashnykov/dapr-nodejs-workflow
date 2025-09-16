#! /usr/bin/env bash
set -e

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

echo 'Starting database...'

DB_USER=postgres
DB_PASSSWORD=daprrulz


docker run \
  --name dapr-nodejs-postgres \
  -e POSTGRES_PASSWORD=$DB_PASSSWORD \
  -e POSTGRES_USER=$DB_USER \
  -p 5432:5432 \
  -v "db:/var/lib/postgresql/data" \
  -v "./db/baseline_ddl.sql:/docker-entrypoint-initdb.d/create_tables.sql" \
  -v "./db/baseline_dml.sql:/docker-entrypoint-initdb.d/fill_tables.sql" \
  --rm \
  -d \
  postgres:15.0-alpine

echo "Database started successfully."
echo "Connect using: psql -h localhost -U $DB_USER -P $DB_PASSSWORD -d postgres"
echo "Connection string: host=localhost user=$DB_USER password=$DB_PASSSWORD port=5432 connect_timeout=10 database=postgres"

# docker stop dapr-nodejs-postgres