#!/usr/bin/env bash
# Read a bounded catalog snapshot. Credentials are supplied explicitly, never sourced.
set -euo pipefail
: "${PROD_DB_URL:?Set PROD_DB_URL to a PostgreSQL connection string or service name}"
cd "$(dirname "$0")/.."
mkdir -p .ignore
seed_tmp=$(mktemp .ignore/seed.XXXXXX)
trap 'rm -f "$seed_tmp"' EXIT
PGDATABASE="$PROD_DB_URL" psql -X --no-align --tuples-only --quiet --set ON_ERROR_STOP=1 \
  --file scripts/seed-catalog.sql > "$seed_tmp"
test -s "$seed_tmp"
mv "$seed_tmp" supabase/seed.sql
printf 'Wrote supabase/seed.sql. Apply locally with supabase db reset.\n'
