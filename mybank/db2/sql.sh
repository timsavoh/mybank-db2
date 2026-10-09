#!/usr/bin/env bash
# Run SQL against the local MYBANK database inside the db2 container.
#   db2/sql.sh -f db2/ddl/02_tables.sql     run a file (terminator @)
#   db2/sql.sh "SELECT ... FROM ..."        run one statement
set -euo pipefail
CONTAINER=${DB2_CONTAINER:-mybank-db2-1}
if [[ "${1:-}" == "-f" ]]; then
  file="$2"
  remote="/tmp/run_$$_$RANDOM.sql"
  docker cp "$file" "$CONTAINER:$remote" >/dev/null
  docker exec "$CONTAINER" chmod 644 "$remote"
  docker exec -u db2inst1 "$CONTAINER" bash -lc "db2 -x connect to MYBANK >/dev/null; db2 -td@ -v -f $remote; rc=\$?; db2 connect reset >/dev/null; exit \$rc"; rc=$?
  docker exec "$CONTAINER" rm -f "$remote"
  exit $rc
else
  docker exec -u db2inst1 "$CONTAINER" bash -lc "db2 connect to MYBANK >/dev/null; db2 \"$1\"; rc=\$?; db2 connect reset >/dev/null; exit \$rc"
fi
