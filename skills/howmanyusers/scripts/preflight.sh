#!/usr/bin/env bash
# Checks the rig before a measuring session. Read every WARN; most of them have cost someone a day.
#
#   TARGET=root@... LOADER=root@... CONTAINER=myapp-web-1 scripts/preflight.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/env.sh"
set +e
warn() { echo "  WARN  $*"; }
info() { echo "  ok    $*"; }

echo "== ssh"
tssh true && info "target reachable" || { warn "cannot ssh to $TARGET"; exit 1; }
lssh true && info "loader reachable" || { warn "cannot ssh to $LOADER"; exit 1; }

echo "== hardware"
tssh "echo \"target: \$(nproc) vCPU, \$(free -m | awk '/Mem:/ {print \$2}') MB RAM, \$(lscpu | sed -n 's/^Model name: *//p')\"" | sed 's/^/  /'
lssh "echo \"loader: \$(nproc) vCPU, \$(free -m | awk '/Mem:/ {print \$2}') MB RAM\"" | sed 's/^/  /'
steal=$(tssh "vmstat 1 6 | tail -5 | awk '{s+=\$17} END {print int(s/NR)}'")
[ "${steal:-0}" -gt 2 ] && warn "target CPU steal ${steal}% at idle: shared vCPU with noisy neighbours, results will drift" || info "target steal ${steal:-?}%"

echo "== network"
rtt=$(lssh "ping -c 20 -i 0.2 -q $TARGET_HOST | awk -F/ '/rtt|round-trip/ {print \$5}'")
if [ -z "$rtt" ]; then warn "ping loader -> target failed (ICMP blocked?)";
elif awk -v r="$rtt" 'BEGIN {exit !(r > 1.0)}'; then warn "RTT ${rtt} ms: not the same datacenter? (expect ~0.2-0.5 ms)";
else info "RTT loader -> target ${rtt} ms"; fi
lssh "curl -sf -o /dev/null -w '%{http_code} in %{time_total}s' '$BASE_URL$HEALTH'" >/tmp/perflab-h 2>&1 && info "health from loader: $(cat /tmp/perflab-h)" || warn "health check from loader failed: $BASE_URL$HEALTH"
lssh "echo \"nofile \$(ulimit -n), ports \$(cat /proc/sys/net/ipv4/ip_local_port_range | tr '\t' '-')\"" | sed 's/^/  ok    loader /'

echo "== tools"
lssh "k6 version 2>/dev/null | head -1" | sed 's/^/  ok    /' | grep . || warn "k6 missing on loader"
tssh "command -v ${PYSPY:-py-spy} >/dev/null" && info "py-spy on target" || warn "py-spy not found on target (pip install py-spy into a venv; set PYSPY=/path)"
tssh "docker inspect '$CONTAINER' >/dev/null 2>&1" && info "container $CONTAINER exists" || warn "no container $CONTAINER on target"

echo "== target hygiene"
df=$(tssh "df -P / | awk 'NR==2 {print \$5}' | tr -d %")
[ "${df:-0}" -gt 75 ] && warn "target disk ${df}% full (old images? docker image prune -a)" || info "target disk ${df:-?}% used"
tssh "docker system df --format '{{.Type}} {{.Size}} ({{.Reclaimable}} reclaimable)'" 2>/dev/null | sed 's/^/        /'
pub=$(tssh "docker ps --format '{{.Names}} {{.Ports}}' | grep -E '0\.0\.0\.0:|\[::\]:'")
if [ -n "$pub" ]; then
  warn "ports published on all interfaces (Docker bypasses ufw: these are open to the internet unless a cloud firewall blocks them):"
  echo "$pub" | sed 's/^/          /'
  echo "        only the app port should be here; bind databases to 127.0.0.1 or don't publish them"
else info "nothing published on 0.0.0.0"; fi
echo "        test from outside, e.g.: nc -vz -w 5 $TARGET_HOST 5432   (must fail)"

echo "== clocks"
echo "  target $(tssh 'date -u +%T')  loader $(lssh 'date -u +%T')  local $(date -u +%T)"
