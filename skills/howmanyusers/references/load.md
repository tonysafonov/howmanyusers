# Measuring: staircase, holds, chaos

## Staircase first, holds decide

1. **Smoke** (2–10 users, 1 minute): every check 100 %, every stream completes, the stand logs no errors. Fix the
   journey before anything else.
2. **Staircase** (`load.sh staircase`): one run that adds users in steps (e.g. START=30 STEP=30 STEP_DUR=90 CLIMB=15)
   and stops at the first failing step. Each step is judged only on its own requests. It is an **estimate**: a step
   can fail on a single slow sample (the first stream of a step), and steps are short.
3. **Holds** (`load.sh hold <label> <users>`): ramp 60 s, hold 5 minutes, judged on the whole run. Bracket the
   estimate: one hold at the last passing step, one a step above. The score is the highest hold that passes. Arjay's
   `loadgen search` automates the same idea: warm-up, doubling probes, bisection to 5 %, then 5-minute holds.
4. **Repeat at the edge.** Two runs at the same load can differ by a step. Before you write "X is slower than Y" from
   one failing hold at the boundary, run both again (we once read a database upgrade as a regression from one run
   each; the database wasn't even the bottleneck).

Keep `STEP` small relative to the user count: a step's new users arrive within `CLIMB` seconds, which is itself a
burst some servers fail on.

## Criteria

| Requests | Pass when | Why |
|---|---|---|
| `kind:api` | p95 < 500 ms, p99 < 1 s | what a person notices; Arjay's scoring |
| all | errors < 1 % | anything else is not "holding" |
| `kind:stream` | p95 duration < (stub's own length + margin), > 99 % reach the done marker | a 20 s answer is fine; an answer that never finishes isn't |
| checks | 100 % in probes, ~100 % in holds | a status you didn't expect is a bug in the journey or the app, never noise |

Override with `P95_MS`, `P99_MS`, `MAX_ERROR_RATE`, `STREAM_P95_MS`, `MIN_STREAM_OK`.

## What to record during every run

`load.sh` saves the k6 summary (text + JSON with per-endpoint p50/p95/p99/errors) and `docker stats` every 10 s
(CPU and memory per container). Also look at, while it runs:

- the app's log (errors, tracebacks, "too many clients", DNS failures, OOM restarts: `docker inspect -f
  '{{.RestartCount}}'`);
- Postgres: `select state, count(*) from pg_stat_activity group by 1` — many `idle in transaction` means requests
  hold transactions while waiting on something else;
- the loader's CPU (must stay well under saturation) and the target's total CPU (is it CPU-bound at the failing step,
  or failing at 50 % CPU? The second means queueing, locks, pools or I/O, not compute).

## Reading a failure

| Symptom at the failing step | Usually |
|---|---|
| CPU ~100 % of the cores the app can use, p99 climbs smoothly | compute-bound: go price endpoints and profile |
| one worker at ~100 % of one core, other cores idle | a single process: workers = cores |
| CPU at 40–70 %, latency explodes, few errors | queueing on something else: DB pool waits, a held transaction, a connector limit, one event loop's bursts |
| errors jump at a threshold (hundreds of 401/500) | a resource ran out: connections, DNS, file descriptors, memory |
| memory climbs, then everything drops at once | a per-request allocation; the container's OOM kill restarts the app and kills every in-flight request |
| the error rate is high but the app's log is clean | errors before the app: connection refused, a proxy, the loader itself |

## Chaos: stop a dependency under load

```bash
DEP=<db container> OUTAGE=6 scripts/chaos.sh before -e EP='GET /users/me'
```

Authenticated requests in a loop (~a few hundred req/s); the database stops for 6 s; responses are counted by
status. What you want: **503 with `Retry-After`** during the outage, a client that shows a retry screen, and
recovery within seconds. What we found instead: auth's catch-all turned the DB error into **401**, and a 6-second
database blip logged users out (58 × 401 in one run). After the fix: 0 × 401, 30 × 503. Run it for every dependency
on the auth path (DB, Redis, an auth service, DNS), before and after the fix, and put the table in the report.

## Memory and stream probes

| Probe | Run | Reads |
|---|---|---|
| burst memory | `VUS_LIST="2 4 8" scripts/memprobe.sh` (loops the journey's app open, `memprobe.js`) | memory before / after / peak per step against the container limit, and `RestartCount`. Flat is healthy; climbing then a restart is a per-request allocation (profiling.md, Memory) |
| price of one stream | `scripts/cpuprobe.sh streamsonly.js 40 streams -e STREAM_EP='POST /path' -e STREAM_BODY='{...}' [-e PRE_EP='GET /path']` | ms CPU per stream (the per-iteration line), and with `VUS` raised how many streams in flight the app holds |

Both abort below 99.9 % checks (streams are checked for `DONE_MARKER`). Run the memory probe before any hold whose
result you'll quote, warm the app up gently first (`warmup.js` at 2 VUs: a cold app can OOM on the warm-up alone), and
use the stub's real stream length when judging stream duration.

## CPU price and profiles

See references/profiling.md: they run at saturation with probes, not inside holds.
