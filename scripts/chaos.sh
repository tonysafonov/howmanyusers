#!/usr/bin/env bash
# Chaos under load: authenticated requests in a loop (k6/chaos.js) while a dependency is stopped for a few seconds.
# Counts responses by status. What you want to see: 503 (+ Retry-After) during the outage, never 401 (users logged
# out because "auth failed") and few 500s; and full recovery after it.
#
#   DEP=myapp-db-1 scripts/chaos.sh before
#   DEP=myapp-redis-1 OUTAGE=10 scripts/chaos.sh redis -e EP='GET /me'
#
# Env: see env.sh, plus DEP (container to stop, required), OUTAGE (seconds, default 6), AT (seconds into the run,
# default 15), VUS (default 4), DURATION (default 45s). Extra args go to k6.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/env.sh"
label=${1:?label}; shift
: "${DEP:?set DEP=<container to stop on TARGET, e.g. the database>}"
extra=""; [ $# -gt 0 ] && extra=$(printf "%q " "$@")
sync_k6
reset_stand
restart_app
(sleep "${AT:-15}"; tssh "docker stop '$DEP' >/dev/null; sleep ${OUTAGE:-6}; docker start '$DEP' >/dev/null"; echo "  $DEP stopped for ${OUTAGE:-6} s at t=${AT:-15} s") &
echo "== chaos $label"
lssh "cd '$K6_DIR' && k6 run -q -e BASE_URL='$BASE_URL' -e VUS=${VUS:-4} -e DURATION=${DURATION:-45s} $extra chaos.js 2>&1" | grep -E "status|errors seen" || true
wait
