#!/usr/bin/env bash
# The CPU price of one kind of load: runs a k6 script at saturation for 75 s, averages the app container's CPU over
# the middle 40 s, and divides by the throughput.
#
#   scripts/cpuprobe.sh endpointprobe.js 6 users-me  -e EP='GET /users/me'
#   scripts/cpuprobe.sh streamsonly.js 40 streams    # your own script: CPU per iteration is printed too
#
# Args: <k6 script in K6_DIR> <VUs> <label> [extra k6 flags...]. Env: see env.sh.
# Prints: label, req/s, iterations/s, checks pass rate, CPU % of one core, ms CPU per request and per iteration.
# Refuses to print a price when checks are below 99.9 %: fast errors look like a cheap endpoint.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/env.sh"
sync_k6
script=${1:?k6 script}; vus=${2:?VUs}; label=${3:?label}; shift 3
extra=""; [ $# -gt 0 ] && extra=$(printf "%q " "$@")

reset_stand
restart_app
cpu_log=$(mktemp); sum=$(mktemp)
trap 'rm -f "$cpu_log" "$sum"' EXIT
sample_cpu 20 10 > "$cpu_log" &
lssh "cd '$K6_DIR' && rm -f /tmp/perflab-cpuprobe.json && k6 run -q --summary-export /tmp/perflab-cpuprobe.json -e BASE_URL='$BASE_URL' -e HEALTH='$HEALTH' -e VUS=$vus -e DURATION=75s $extra '$script' >/dev/null 2>&1; cat /tmp/perflab-cpuprobe.json" > "$sum" || true
wait

python3 - "$cpu_log" "$sum" "$label" <<'PY'
import json, sys
cpu_path, sum_path, label = sys.argv[1:]
cpu = [float(x) for x in open(cpu_path).read().split() if x.replace(".", "", 1).isdigit()]
try:
    m = json.load(open(sum_path))["metrics"]
except Exception as e:
    sys.exit(f"{label}: no k6 summary ({e}); run the script by hand on the loader to see why")
rps = m.get("http_reqs", {}).get("rate", 0.0)
its = m.get("iterations", {}).get("rate", 0.0)
chk = m.get("checks", {})
ok = chk.get("value", chk.get("rate"))
avg = sum(cpu) / len(cpu) if cpu else float("nan")
line = f"{label}: {rps:.1f} req/s, {its:.2f} it/s, CPU {avg:.1f}% of one core ({len(cpu)} samples)"
if ok is None:
    print(line + "  [no checks in the script: add a 2xx check before trusting this]")
elif ok < 0.999:
    print(line + f"  CHECKS {ok * 100:.2f}% -> NO PRICE: the probe is measuring errors, fix it first")
    sys.exit(1)
else:
    print(line + f", checks {ok * 100:.2f}%")
if rps and cpu:
    print(f"  {avg * 10 / rps:.2f} ms CPU per request" + (f", {avg * 10 / its:.1f} ms per iteration" if its else ""))
PY
