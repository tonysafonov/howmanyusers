#!/usr/bin/env bash
# One measured run of the realistic journey from the loader, on a freshly reset and restarted app.
#
#   scripts/load.sh staircase <label> [-e START=50 -e STEP=50 -e MAX=1500 ...]   # the fast estimate
#   scripts/load.sh hold <label> <users> [-e DURATION=5m ...]                    # the verdict: a 5-minute hold
#
# Syncs K6_SRC to the loader, runs RESET_CMD, restarts the app, runs k6, and copies the loader's result files to
# ./results/<label>/ (override with RESULTS). Also logs the app container's CPU and memory every 10 s into
# docker-stats.txt next to them, so "what was saturated" is answered by the same run. Env: see env.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/env.sh"
mode=${1:?staircase|hold}; label=${2:?label}; shift 2
case "$mode" in
  staircase) script=staircase.js; users_flag="" ;;
  hold) script=hold.js; users=${1:?users}; shift; users_flag="-e VUS=$users"; label="$label-$users" ;;
  *) echo "mode: staircase | hold" >&2; exit 2 ;;
esac
extra=""; [ $# -gt 0 ] && extra=$(printf "%q " "$@")
out=${RESULTS:-results}/$label
mkdir -p "$out"

sync_k6
reset_stand
restart_app
remote_dir="results/$label"
tssh "while true; do date -u +%H:%M:%S; docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemUsage}}'; sleep 10; done" > "$out/docker-stats.txt" 2>/dev/null &
stats_pid=$!
trap 'kill $stats_pid 2>/dev/null || true' EXIT
set +e
lssh "cd '$K6_DIR' && mkdir -p '$remote_dir' && k6 run -q -e BASE_URL='$BASE_URL' -e RESULTS_DIR='$remote_dir' -e LABEL='$label' $users_flag $extra $script" 2>&1 | tee "$out/k6.log"
code=${PIPESTATUS[0]}
set -e
rsync -a "$LOADER:$K6_DIR/$remote_dir/" "$out/" 2>/dev/null || true
echo "results -> $out   (k6 exit $code: 0 = pass, 99 = thresholds failed)"
exit "$code"
