#!/usr/bin/env bash
# Does the app's memory scale with requests in flight? Runs memprobe.js (app opens in a tight loop) at rising VUs and
# prints, per step: memory before and after, the peak, the container's memory limit, and RestartCount (an OOM kill).
#
#   scripts/memprobe.sh                      # VUS_LIST="2 4 8", 20 s each
#   VUS_LIST="2 4 8 16" STEP_DUR=30s scripts/memprobe.sh
#
# Env: see env.sh, plus VUS_LIST, STEP_DUR (default 20s). Restarts the app before the first step only.
# Healthy: memory flat from step to step. Climbing, then a restart: a per-request allocation (see profiling.md).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/env.sh"
sync_k6
VUS_LIST=${VUS_LIST:-2 4 8}; STEP_DUR=${STEP_DUR:-20s}
secs=${STEP_DUR%s}

reset_stand
restart_app
restarts() { tssh "docker inspect -f '{{.RestartCount}}' '$CONTAINER'"; }
mem() { tssh "docker stats --no-stream --format '{{.MemUsage}}' '$CONTAINER'"; }
echo "limit/usage format: used / limit"
r0=$(restarts)
printf '%-6s %-24s %-24s %-14s %s\n' VUs before after peak restarts
for v in $VUS_LIST; do
  before=$(mem)
  log=$(mktemp)
  (sleep 2; for _ in $(seq 1 $(( (secs - 2) / 2 ))); do mem | awk '{print $1}'; sleep 2; done) > "$log" &
  lssh "cd '$K6_DIR' && k6 run -q -e BASE_URL='$BASE_URL' -e HEALTH='$HEALTH' -e VUS=$v -e DURATION=$STEP_DUR memprobe.js >/dev/null 2>&1" || echo "  (k6 exited non-zero at $v VUs: errors or aborted checks)"
  wait
  after=$(mem)
  peak=$(python3 - "$log" <<'PY'
import re, sys
u = {"B": 1 / 1048576, "KiB": 1 / 1024, "MiB": 1, "GiB": 1024}
vals = []
for s in open(sys.argv[1]).read().split():
    m = re.match(r"([\d.]+)([A-Za-z]+)", s)
    if m and m.group(2) in u: vals.append(float(m.group(1)) * u[m.group(2)])
print(f"{max(vals):.0f} MiB" if vals else "-")
PY
)
  rm -f "$log"
  printf '%-6s %-24s %-24s %-14s %s\n' "$v" "$before" "$after" "$peak" "$(( $(restarts) - r0 ))"
done
