#!/usr/bin/env bash
# Shared settings and helpers for the howmanyusers scripts. Sourced, not run.
#
# Required:
#   TARGET      ssh destination of the box under test, e.g. root@203.0.113.10
#   LOADER      ssh destination of the load generator (a second box in the same datacenter)
#   CONTAINER   docker container of the app on TARGET (CPU is read from it; it is restarted between runs)
# Optional:
#   BASE_URL    the app as the LOADER sees it          (default http://<TARGET host>:${PORT:-8000})
#   HEALTH      a cheap no-auth path                    (default /health)
#   K6_DIR      where the k6 folder lives on LOADER     (default /root/perf-k6)
#   K6_SRC      the local k6 folder to sync             (default ./perf/k6)
#   RESET_CMD   shell run on TARGET before every measurement (reset quotas, balances, rate limits...)
#   RESTART_CMD shell run on TARGET to restart the app  (default: docker restart $CONTAINER)
#   NO_RESTART  1 = never restart the app between runs
set -euo pipefail

: "${TARGET:?set TARGET=user@host (the box under test)}"
: "${LOADER:?set LOADER=user@host (the load generator)}"
: "${CONTAINER:?set CONTAINER=<docker container of the app on TARGET>}"
TARGET_HOST=${TARGET#*@}
BASE_URL=${BASE_URL:-http://$TARGET_HOST:${PORT:-8000}}
HEALTH=${HEALTH:-/health}
K6_DIR=${K6_DIR:-/root/perf-k6}
K6_SRC=${K6_SRC:-./perf/k6}
RESTART_CMD=${RESTART_CMD:-docker restart $CONTAINER}
SSH_OPTS=${SSH_OPTS:--o BatchMode=yes -o ServerAliveInterval=30}

tssh() { ssh $SSH_OPTS "$TARGET" "$@"; }
lssh() { ssh $SSH_OPTS "$LOADER" "$@"; }

# Health from the loader, not from the target: it also proves the network path the test uses.
wait_healthy() {
  lssh "for i in \$(seq 1 90); do curl -sf -o /dev/null '$BASE_URL$HEALTH' && exit 0; sleep 1; done; echo 'not healthy: $BASE_URL$HEALTH' >&2; exit 1"
}

restart_app() {
  [ "${NO_RESTART:-0}" = 1 ] && return 0
  tssh "$RESTART_CMD" >/dev/null
  wait_healthy
}

reset_stand() {
  [ -n "${RESET_CMD:-}" ] && tssh "$RESET_CMD" >/dev/null
  return 0
}

sync_k6() {
  [ -d "$K6_SRC" ] || { echo "no k6 folder at $K6_SRC (set K6_SRC)" >&2; exit 1; }
  lssh "mkdir -p '$K6_DIR'"
  rsync -a --delete --exclude results "$K6_SRC/" "$LOADER:$K6_DIR/"
}

# Samples the container's CPU (% of one core) every 4 s, N times, after a delay. Prints one number per line.
sample_cpu() {
  local delay=$1 n=$2
  sleep "$delay"
  tssh "for i in \$(seq 1 $n); do docker stats --no-stream --format '{{.CPUPerc}}' '$CONTAINER' | tr -d '%'; sleep 4; done"
}
