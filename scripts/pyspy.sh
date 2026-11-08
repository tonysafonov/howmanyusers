#!/usr/bin/env bash
# Profiles the app at saturation: a k6 script in a tight loop from the loader, py-spy on the busiest worker of
# CONTAINER for 30 s. Only at saturation do py-spy's shares mean CPU: at partial load the event loop's idle wait
# (uvloop's C `run`) is sampled as busy and swamps everything.
#
#   scripts/pyspy.sh out/users-me.txt endpointprobe.js 6 -e EP='GET /users/me'
#   python3 scripts/stacks.py top out/users-me.txt
#
# Args: <output file (local)> <k6 script> <VUs> [extra k6 flags...]. Env: see env.sh, plus
#   PYSPY      py-spy on TARGET (default py-spy; e.g. /opt/pyspy/bin/py-spy)
#   PYSPY_PID  a host PID to profile instead of auto-picking the busiest python process in CONTAINER
#   DURATION   seconds of profile (default 30), RATE samples/s (default 200)
# Writes collapsed stacks (py-spy --format raw: "frame;frame;frame count" per line).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/env.sh"
sync_k6
out=${1:?output file}; script=${2:?k6 script}; vus=${3:?VUs}; shift 3
extra=""; [ $# -gt 0 ] && extra=$(printf "%q " "$@")
PYSPY=${PYSPY:-py-spy}; DUR=${DURATION:-30}; RATE=${RATE:-200}
mkdir -p "$(dirname "$out")"

reset_stand
restart_app
lssh "cd '$K6_DIR' && k6 run -q -e BASE_URL='$BASE_URL' -e HEALTH='$HEALTH' -e VUS=$vus -e DURATION=$((DUR + 35))s $extra '$script' >/dev/null 2>&1" &
sleep 15
# docker top lists host PIDs; sort by %CPU so a multi-worker server gives a worker, not the idle supervisor.
# (Not `pgrep -f` over ssh: it matches the ssh command line that contains the pattern.)
tssh "set -e
pid='${PYSPY_PID:-}'
if [ -z \"\$pid\" ]; then
  pid=\$(docker top '$CONTAINER' -eo pid,pcpu,args | awk 'NR>1 && /python|uvicorn|gunicorn|granian|hypercorn/ {print \$2, \$1}' | sort -rn | head -1 | awk '{print \$2}')
fi
[ -n \"\$pid\" ] || { echo 'no python process in $CONTAINER' >&2; exit 1; }
echo \"profiling pid \$pid\" >&2
# --nonblocking: blocking mode stops the process for every sample and can hang it; timeout guards py-spy itself.
timeout $((DUR + 20)) '$PYSPY' record --nonblocking -p \"\$pid\" -d $DUR -r $RATE --format raw -o /tmp/perflab-pyspy.txt >/dev/null 2>&1 || true
cat /tmp/perflab-pyspy.txt" > "$out"
wait || true
lines=$(wc -l < "$out" | tr -d ' ')
[ "$lines" -gt 0 ] || { echo "empty profile: is py-spy installed on TARGET, and run as root?" >&2; exit 1; }
echo "stacks: $lines lines -> $out   (next: python3 $HERE/stacks.py top $out)"
