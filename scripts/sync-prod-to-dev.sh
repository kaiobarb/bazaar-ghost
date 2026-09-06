#!/usr/bin/env bash
# Refresh dev catalog data without replacing migration-managed schemas, roles, or Vault.
set -euo pipefail
: "${PROD_DB_URL:?Set PROD_DB_URL explicitly}"
: "${DEV_DB_URL:?Set DEV_DB_URL explicitly}"
if [[ "$PROD_DB_URL" == "$DEV_DB_URL" ]]; then
  printf 'Source and destination must differ.\n' >&2
  exit 1
fi
cd "$(dirname "$0")/.."
printf 'Replace the dev catalog data using the current migrations? Type yes: '
read -r answer
[[ "$answer" == yes ]] || exit 0
# Export first. Any query error leaves both databases unchanged.
bash scripts/seed-from-prod.sh
# The seed itself is one transaction. A schema mismatch rolls the entire import back.
PGDATABASE="$DEV_DB_URL" psql -X --set ON_ERROR_STOP=1 --file supabase/seed.sql
printf 'Dev catalog refreshed with processing disabled. Schema and Vault were preserved.\n'
