# Where the time goes: CPU prices and profiles

A hold tells you *how many*. These two tell you *why*: what each request costs, and where inside a request the CPU
goes. Both run **at saturation, one endpoint at a time**, not inside a realistic hold.

## 1. CPU price per endpoint

```bash
scripts/cpuprobe.sh endpointprobe.js 6 health  -e EP='GET /health'
scripts/cpuprobe.sh endpointprobe.js 6 me      -e EP='GET /users/me'
scripts/cpuprobe.sh endpointprobe.js 6 start   -e EP='POST /session/start' -e BODY='{"tz":"UTC"}'
scripts/cpuprobe.sh streamsonly.js 40 streams                     # your own script: price per iteration
```

The probe hammers one endpoint with no think time as random test users, samples the container's CPU over the
middle 40 s of a 75 s run, and prints **ms of CPU per request = CPU% of one core × 10 / req/s**. Use enough VUs
to saturate what the app can use (e.g. 6 for 2 workers) and check the CPU really is near the ceiling.

How to read the table:

- `GET /health` (no auth, no DB) is the **framework floor**: middleware + routing + server. Ours: ~0.5 ms.
- `GET /me` (auth + one SELECT, nothing else) minus the floor is the **per-request tax** every authenticated call
  pays. Ours went 3.6 → 2.8 ms with the fixes, from a floor of 0.5.
- Endpoints far above the tax hide something: ours had a payments endpoint at 12.8 ms that only returned an
  in-memory list (it built an HTTP client per request; 2.8 ms after the fix).
- Price a whole flow: **CPU per app open = Σ its requests**; a mixed load's CPU ≈ Σ (rate × price). Check it
  against a hold: "25 API req/s × 6.4 ms + 2.4 streams/s × 126 ms ≈ 0.46 core; measured 0.47." When the sum
  matches, you know where every millisecond goes; when it doesn't, something isn't in the model.
- Streams: price them separately (a streams-only script). One LLM answer relayed as ~300 chunks cost us 126–197
  ms of CPU depending on the client library, more than twenty API calls.

**Trust rules** (each one learned the hard way):
- `cpuprobe.sh` refuses to print a price when fewer than 99.9 % of checks pass. A probe that sends broken auth
  measures fast 401s. Ours did, for hours, and produced a table showing a 40 % win that was really 17–27 %.
- Don't pin one user at saturation (`PIN_USER`) unless rate limits are off: per-user limits answer 429 within
  seconds. Seed a heavy user only for the endpoint whose cost depends on data size, and price the size curve
  (history of 30 / 160 / 1,600 items) instead of one point.
- One table = one stand state. Prices drift between a fresh stand and one that has run holds for days (we saw 1.8
  vs 3.6 ms for the same endpoint across two stand states). Re-price the baseline in the same `ab.sh` run.

## 2. py-spy at saturation

```bash
scripts/pyspy.sh out/me.txt endpointprobe.js 6 -e EP='GET /users/me'
python3 scripts/stacks.py top out/me.txt --min 3
python3 scripts/stacks.py children out/me.txt solve_dependencies
python3 scripts/stacks.py match out/me.txt 'get_dependant' 'logging.*(flush|emit)' 'sqlalchemy' 'pydantic'
python3 scripts/stacks.py diff out/base/me.txt out/new/me.txt
```

- **Only at saturation.** py-spy samples wall-clock stacks. In `--nonblocking` mode an idle asyncio/uvloop worker
  is sampled sitting in the C `run` / `select` leaf and counted as busy; at partial load that leaf was 77 % of our
  samples and every share was meaningless. With one endpoint in a tight loop the loop is rarely idle and shares mean
  CPU. `stacks.py top` warns when > 15 % of samples are in an event-loop wait.
- **Shares of a request:** by default `stacks.py` keeps only stacks under the request entry frame (`run_asgi` for
  uvicorn; `--entry` for others) and counts each frame once per sample (inclusive). Quote those: "28.8 % of a
  request is FastAPI rebuilding the dependency tree".
- **Translate shares into ms** with the endpoint's price: 28.8 % of a 3.5 ms request ≈ 1 ms. Then rank fixes by ms
  × request rate, not by share.
- `--nonblocking` always (the blocking mode pauses the process per sample and hung our worker), with a `timeout`
  around py-spy itself; profile one worker (the busiest; `docker top` gives host PIDs; `pgrep -f` over ssh matches
  its own command line); root on the host, or `cap_add: SYS_PTRACE` inside the container.
- Raw `--format raw` (collapsed) files are small and diffable; keep them in results/. For a picture: `py-spy record
  -f speedscope` and https://www.speedscope.app.

## 3. Node and Bun at saturation

Price first with `cpuprobe.sh`: it divides container CPU by throughput, so it works for any runtime. Then profile the
expensive endpoints, at saturation only, same as py-spy.

- **Node:** start the server with `--cpu-prof --cpu-prof-dir=/tmp/prof` (cluster workers inherit the flag, one profile
  per process), drive the endpoint with `endpointprobe.js` for 30–60 s, then stop the server **gracefully** (SIGINT or
  SIGTERM): the profile is written on exit, and SIGKILL writes nothing. Open the `.cpuprofile` in Chrome DevTools
  (Performance → load profile) or speedscope.app and read the bottom-up view.
- **Attach to a running Node process (Linux):** start it with `--perf-basic-prof` so JS frames get names, then
  `perf record -F 99 -g -p <pid> -- sleep 30` and a flamegraph. Closest to the py-spy workflow; needs `perf` on the
  target.
- **Bun:** `bun --cpu-prof` (1.3+) writes a profile on exit, the same way; `bun --inspect` opens the web debugger,
  whose profiler works on a live process.
- Drop `(idle)` and `(program)` from the totals (the event loop waiting), translate shares into ms with the
  endpoint's price, rank fixes by ms × rate.

What we saw in a TypeScript backend (Hono + Drizzle, Conduit): the app was cheap (1.1–1.5 ms per request) and the
**database** became the cost: Drizzle sends unprepared statements, so Postgres planned every query. That shows on the
database side, not in the app profile: compare Postgres CPU per request between variants, and check
`pg_stat_statements` / `pg_prepared_statements`. Frames worth searching in Node/Bun profiles: client constructors and
`createSecureContext` under a request (built per request), ORM query building on every call, `JSON.stringify` of
large payloads, synchronous log writes, schema validation of large responses.

## What profiles of Python web backends tend to show

Frames worth searching for (`stacks.py match`), each a finding we actually had (details in references/fixes.md):

| Frame pattern | Meaning |
|---|---|
| `create_default_context`, `load_verify_locations`, `ClientSession.__init__`, `Bot(`, `httpx.AsyncClient(` | a client (and its SSL context) built per request |
| `get_dependant`, `get_typed_signature` under `solve_dependencies` | FastAPI's slow path with `app.dependency_overrides` set: it rebuilds the dependency tree per request |
| `StreamHandler.flush`, `emit` | logging writing to a pipe on the event loop |
| `BaseHTTPMiddleware`, `anyio` streams under middleware | Starlette's `BaseHTTPMiddleware`: a task + memory stream per request |
| `connect` under `asyncpg` / `pool` | new DB connections mid-request: pool overflow churn |
| `getaddrinfo` | DNS per connection (and Docker's embedded DNS under churn) |
| `construct_type`, `model_validate` per chunk | SDK model objects per streamed event |
| `threading.Timer`, `_expire_events` | an in-memory rate limiter starting a thread per request |
| `sentry_sdk` spans | tracing at 100 % sample rate |

## Memory

`docker stats` during a burst probe (app opens in a tight loop at 2, 4, 8 VUs) shows whether memory scales with
requests in flight. Ours went 305 → 501 MB in 15 s at 4 VUs and the 512 MB container was OOM-killed (restart, every
in-flight request and stream dropped). Cause: a per-request HTTP client with its own SSL context (the CA store loaded
each time); the allocator keeps the peak. One client per process: flat at ~305 MB at 8 VUs. Run this probe before
any hold whose result you'll quote, and check `RestartCount` after every hold.
