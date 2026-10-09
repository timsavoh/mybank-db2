#!/usr/bin/env bash
# Compile every routine under db2/routines (UTIL first), retrying failures until
# no further progress is made, so cross-routine dependencies resolve themselves.
#   db2/deploy_routines.sh            all routines
#   db2/deploy_routines.sh BATCH PAY  only these schema folders
set -uo pipefail
CONTAINER=${DB2_CONTAINER:-mybank-db2-1}
docker exec -u db2inst1 -e SCHEMAS="$*" "$CONTAINER" bash -lc '
cd /mybank/db2/routines
if [[ -n "$SCHEMAS" ]]; then
  pending=$(for s in $SCHEMAS; do ls $s/*.sql; done)
else
  pending=$(ls UTIL/*.sql; ls */*.sql | grep -v "^UTIL/")
fi
db2 connect to MYBANK >/dev/null
pass=1
while [[ -n "$pending" ]]; do
  failed=""
  for f in $pending; do
    log=/tmp/err_${f//\//_}.log
    db2 -td@ -f "$f" > "$log" 2>&1
    if grep -qE "SQL[0-9]{4,5}N" "$log"; then failed="$failed $f"; fi
  done
  n_before=$(echo $pending | wc -w); n_after=$(echo $failed | wc -w)
  echo "pass $pass: $((n_before - n_after)) compiled, $n_after failed"
  if [[ $n_after -eq 0 || $n_after -eq $n_before ]]; then break; fi
  pending=$failed; pass=$((pass+1))
done
for f in $failed; do echo "--- FAILED: $f"; grep -E "SQL[0-9]{4,5}N" "/tmp/err_${f//\//_}.log" | head -3; done
db2 connect reset >/dev/null
[[ -z "$failed" ]]
'
