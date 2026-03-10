#!/bin/bash
set -e

DB_NAME="${PGBENCH_DB:-postgres}"
SCALE=1000  # 100 million rows in pgbench_accounts (100,000 * 1000)

echo "=== Initializing pgbench tables with scale factor $SCALE ==="
pgbench -i -I dtGvp -s "$SCALE" "$DB_NAME"
