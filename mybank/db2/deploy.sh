#!/usr/bin/env bash
# Build the MYBANK database from scratch into a running db2 container:
# DDL, routines, triggers, reference data, generated seed data, Db2 admin tasks.
#   db2/deploy.sh            (from mybank/)
set -euo pipefail
cd "$(dirname "$0")"

# SQLnnnnN is an error, except LOAD's informational SQL3109N/SQL3110N
ERR='SQL[0-9]{4,5}N'
INFO='SQL31(09|10)N'

run() {  # run a SQL file, fail on any error message
  local log; log=$(mktemp)
  echo "== $1"
  ./sql.sh -f "$1" > "$log" 2>&1 || true
  if grep -E "$ERR" "$log" | grep -qvE "$INFO"; then
    grep -E "$ERR" "$log" | grep -vE "$INFO" | head -5
    grep -B12 -E "$ERR" "$log" | grep -vE "$INFO" | head -60
    echo "FAILED: $1"; exit 1
  fi
}

# Db2's Administrative Task Scheduler runs the three DB2TASK jobs; it's off by default
docker exec -u db2inst1 "${DB2_CONTAINER:-mybank-db2-1}" bash -lc 'db2set DB2_ATS_ENABLE=YES; db2 activate db MYBANK >/dev/null' || true

run ddl/01_storage_and_schemas.sql
run ddl/02_tables.sql
[[ -f ddl/05_legacy.sql ]] && run ddl/05_legacy.sql
./deploy_routines.sh UTIL
run ddl/03_views.sql
run ddl/04_triggers.sql
./deploy_routines.sh
[[ -f ddl/99_legacy_cleanup.sql ]] && run ddl/99_legacy_cleanup.sql
run seed/01_reference.sql
[[ -f seed/02_batch_jobs.sql ]] && run seed/02_batch_jobs.sql

[[ -f seed/data/_restart.sql ]] || python3 seed/generate.py
run seed/10_load.sql
run seed/data/_restart.sql
run seed/20_post_load.sql
[[ -f tasks/admin_tasks.sql ]] && run tasks/admin_tasks.sql
echo "MYBANK deployed."
