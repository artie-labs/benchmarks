#!/bin/bash
set -e

DB_NAME="${PGBENCH_DB:-postgres}"
SCALE="${PGBENCH_SCALE:-1000}"
CLIENTS=20
THREADS=8
DURATION=6000  # seconds

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Pre-warming pgbench_accounts into OS page cache ==="
psql "$DB_NAME" -c "SELECT count(*) FROM pgbench_accounts;"

echo "=== Running pgbench with custom script (UPDATEs + INSERTs only, no SELECTs) ==="
pgbench -f "$SCRIPT_DIR/custom_tpcb.sql" \
    -s "$SCALE" \
    -c "$CLIENTS" \
    -j "$THREADS" \
    -T "$DURATION" \
    -M prepared \
    -P 5 \
    -n \
    "$DB_NAME"