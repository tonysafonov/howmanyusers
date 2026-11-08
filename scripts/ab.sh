#!/usr/bin/env bash
# A/B (or A/B/C...) on the same stand with the same procedure: for each variant, deploy it, warm up, price every
# endpoint, profile one, and run the holds. Only numbers from one ab.sh run are comparable with each other.
#
#   DEPLOY_CMD='./perf/push.sh "$VARIANT"' EPS='GET /health;GET /users/me;POST /orders' HOLDS='600 750 900' \
#     scripts/ab.sh out/2026-11-05-auth base:c2c53683 new:a1cdbc40
#   # repeats against drift: scripts/ab.sh out/x a:REF1 b:REF2 b:REF2 a:REF1   (results go to a, b, b.2, a.2)
#
# A variant is NAME[:REF]; DEPLOY_CMD runs locally with VARIANT=NAME and REF=REF exported and must leave a fresh
# app up on TARGET (fresh DB too, if the numbers depend on data). Env: see env.sh, plus
#   EPS         ';'-separated endpoints for endpointprobe.js (default 'GET /health')
#   PROBE_VUS   VUs for the CPU probes (default 6: enough to saturate 2 workers; check the box is at ~100 %)
#   PROFILE_EP  the endpoint to py-spy (default: the last of EPS; 'none' to skip)
#   WARMUP      a k6 script run once after each deploy (default warmup.js if it exists on the loader; 'none' to skip)
#   HOLDS       users for 5-minute holds (default none)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/env.sh"
out=${1:?outdir}; shift
[ $# -ge 1 ] || { echo "usage: ab.sh <outdir> NAME[:REF]..." >&2; exit 2; }
: "${DEPLOY_CMD:?set DEPLOY_CMD (runs with VARIANT and REF exported; must leave a fresh app up on TARGET)}"
EPS=${EPS:-GET /health}
IFS=';' read -r -a eps <<< "$EPS"
PROFILE_EP=${PROFILE_EP:-${eps[${#eps[@]}-1]}}
mkdir -p "$out"
sync_k6

seen=" "  # names done so far (bash 3.2 on macOS has no associative arrays)
for v in "$@"; do
  name=${v%%:*}; ref=${v#*:}; [ "$ref" = "$v" ] && ref=""
  n=1; for x in $seen; do [ "$x" = "$name" ] && n=$((n + 1)); done; seen="$seen $name"
  dir="$out/$name"; [ "$n" -gt 1 ] && dir="$out/$name.$n"
  mkdir -p "$dir"
  echo "=== $name ${ref:+($ref)} -> $dir"
  VARIANT=$name REF=$ref bash -c "$DEPLOY_CMD" > "$dir/deploy.log" 2>&1 || { echo "deploy failed, see $dir/deploy.log"; exit 1; }
  wait_healthy
  if [ "${WARMUP:-}" != none ]; then
    w=${WARMUP:-warmup.js}
    lssh "cd '$K6_DIR' && [ -f '$w' ] && k6 run -q -e BASE_URL='$BASE_URL' '$w' >/dev/null 2>&1 || true"
  fi
  : > "$dir/cpu.txt"
  for ep in "${eps[@]}"; do
    "$HERE/cpuprobe.sh" endpointprobe.js "${PROBE_VUS:-6}" "$ep" -e "EP=$ep" >> "$dir/cpu.txt" 2>&1 || true
  done
  cat "$dir/cpu.txt"
  if [ "$PROFILE_EP" != none ]; then
    "$HERE/pyspy.sh" "$dir/pyspy.txt" endpointprobe.js "${PROBE_VUS:-6}" -e "EP=$PROFILE_EP" || true
  fi
  for users in ${HOLDS:-}; do
    RESULTS="$dir" "$HERE/load.sh" hold "$name" "$users" > "$dir/hold-$users.log" 2>&1 || true
    grep -E "VERDICT|latency|errors|streams" "$dir/hold-$users.log" | sed "s/^/  $users users: /" || true
  done
done

# One table: ms CPU per request, endpoint x variant.
python3 - "$out" <<'PY'
import os, re, sys
root = sys.argv[1]
cols = sorted(d for d in os.listdir(root) if os.path.isfile(os.path.join(root, d, "cpu.txt")))
rows, table = [], {}
for c in cols:
    label = None
    for line in open(os.path.join(root, c, "cpu.txt")):
        m = re.match(r"(.+?): [\d.]+ req/s", line)
        if m:
            label = m.group(1)
            if label not in rows: rows.append(label)
            if "NO PRICE" in line: table[(label, c)] = "ERR"
        m = re.search(r"([\d.]+) ms CPU per request", line)
        if m and label and (label, c) not in table:
            table[(label, c)] = m.group(1)
w = max([len(r) for r in rows] + [18]) + 2
print("\n" + "ms CPU per request".ljust(w) + "".join(f"{c:>12}" for c in cols))
for r in rows:
    print(f"{r:<{w}}" + "".join(f"{table.get((r, c), '-'):>12}" for c in cols))
PY
