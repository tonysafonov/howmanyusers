# The fix ladder, and fixes that paid off

## Procedure

- **One change per step**, stacked: step 3 = baseline + 1 + 2 + 3. Measure each with the **same procedure** (same
  stand state, same warm-up, same search or holds). A step that doesn't help stays in the table with its number:
  "no gain" is a result.
- **Each step is a commit or an overlay** (a folder of changed files copied over the baseline), never an edit to the
  baseline. `ab.sh base:<sha> new:<sha>` deploys by commit; overlays let fix steps ship without touching the code
  under test. Build variants as thin image layers over the base image (disk).
- **Re-prioritise after every step.** The bottleneck moves: after removing per-request clients our app was no longer
  CPU-bound and failed on tail latency; after adding workers it hit the DB connection cap; after bounding the pool
  it was CPU-bound again. Profile again; don't follow the original list blindly.
- **Order by expected ms saved × rate, over risk.** Small, reversible, behaviour-preserving changes first.
- **A fix can make things worse until its partner lands.** Bounding the DB pool without first releasing the
  transaction held during LLM streams took a stand from passing to p99 9.2 s at a fraction of the load: streams
  owned every pooled connection. Write such couplings into the plan ("never ship A without B").
- Production: every fix behind tests, rolled out on staging first, then measured there too.

## Worked example: a FastAPI framework on Conduit (2 dedicated vCPU, multicore rig)

| Step | Users (5-min hold) | req/s | p99 ms |
|---|---:|---:|---:|
| framework as shipped | 220 | 56 | 610 |
| 1 one HTTP client (Bot) + one Redis/arq pool per process, not per request | 500 | 131 | 938 |
| 2 workers = cores | 830 | 220 | 172 |
| 3 bounded DB pool per worker (10, no overflow) | 1,000 | 259 | 575 |
| 4 keep-alive 65 s, no access log | 950 | 247 | 317 |
| 5 pure-ASGI middleware instead of `BaseHTTPMiddleware` | 1,200 | 314 | 292 |
| 6 lean per-request dependency (only the DB session) | 1,300 | 337 | 569 |
| 7 no per-request INFO log line | **1,400** | 359 | 919 |
| reference FastAPI (`examples/python`) | 3,400 | 888 | 611 |

6.4× over as shipped, 41 % of the reference. Step 4 brought nothing (Nginx held the client connections, so uvicorn's
keep-alive barely mattered) and stays in the table.

## Findings that generalise (symptom → measure → fix)

**Per-request clients.** An HTTP client, bot SDK object, Redis/queue pool or SSL context built in a dependency or a
service constructor. Profile: SSL context creation and CA loading; memory scales with requests in flight (OOM under a
burst). One framework spent 55 % of request CPU (≈ 7 ms) building a Telegram `Bot()` per request. Fix: one per
process, created in the lifespan, closed at shutdown; make lazy constructors (`cached_property`) reuse it. Search the
whole codebase: we found the same pattern again later in a payments provider (12.8 → 2.8 ms) and an admin alert path.

**Workers = cores.** One uvicorn worker uses one core. `--workers N` (or gunicorn with uvicorn workers) for N cores,
minus what the DB and other services on the box need. Memory multiplies (one worker ≈ 280–300 MB in our stack), and
the gain is rarely N×: 2 workers on 2 vCPU gave +33 % when they shared the box with Postgres and an LLM stub.

**DB pool vs `max_connections`.** `pool_size + max_overflow` per worker × workers (+ every other process: bot,
background workers) must stay below Postgres's `max_connections`. Symptom: `TooManyConnectionsError` / "too many
clients" and a collapse to a fraction of throughput. A huge overflow also means a new connection (and a DNS lookup,
and maybe TLS) per waiting request. Fix: a bounded pool sized for the workload, no overflow churn; requests then wait
for a connection instead of failing.

**Transactions held across slow I/O.** A request-scoped session opened by a dependency stays `idle in transaction`
for the whole streamed LLM answer (~20 s) while doing nothing in the DB. Visible in `pg_stat_activity`. Fix: do the
checks on the normal session and commit before the stream; stream with no transaction; save the result in a short
transaction afterwards (keep the `FOR UPDATE` on balances at the end, so balance logic is unchanged).

**Connection churn → Docker DNS → 401s.** Every new TCP connection to `db` / `redis` resolves the name through
Docker's embedded DNS; at high churn it starts failing (`[Errno -3] Temporary failure in name resolution`), and an
auth catch-all turned each failure into a 401: users got logged out under load (72 % errors in a hold). Fix the
churn (per-process pools, bounded pools, shared HTTP sessions) **and** the error mapping (below).

**Auth errors are not 401.** A DB / Redis / DNS failure inside authentication must answer 503 (+ `Retry-After`), and
the client must show a retry screen, not log the user out. Verify with the chaos test (references/load.md).

**Connector limits.** aiohttp's `ClientSession` allows 100 connections by default (`TCPConnector(limit=100)`). With
hundreds of concurrent LLM streams through one session, stream p95 went to 43 s at half a core of CPU. Raise the
limit deliberately (we used 1,000) and size it against the upstream's rate limits.

**FastAPI `dependency_overrides` in production.** With overrides set, FastAPI re-resolves the dependant of every
dependency on every request (`get_dependant` → `get_typed_signature`): 29–35 % of a light request. Wire real
dependencies instead of production overrides (keep overrides for tests): the per-request tax fell 17–27 % per
authenticated endpoint, and the same 2-worker stand went from 600 to 750 users.

**Logging on the event loop.** A per-request INFO line (+ access log) flushed to a container's stdout pipe is a
blocking write on the loop (9 % of a request was `StreamHandler.flush`). Fix: DEBUG for per-request lines with lazy
`%s` formatting; move handlers behind a `QueueHandler` + `QueueListener` thread. CPU stays similar (the write still
happens), but the loop stops waiting on the pipe, which shows in the tail: 750 → 900 users with the same CPU prices.

**`BaseHTTPMiddleware`.** Each one adds a task and memory streams per request. Rewrite as pure ASGI middleware
(same headers): +200 users on the Conduit ladder (step 5).

**Streams: per-event cost.** An LLM answer arrives as hundreds of SSE events; each costs a socket wakeup, parsing,
objects, and a write downstream. Measured client-side per chunk: raw aiohttp + `json.loads` 118–160 µs; the old
client 244–291; the official SDK on httpx 560–579 (a model object per event). A raw SSE client over one shared
session plus ~100 ms chunk coalescing toward the browser halved CPU per answer (197 → 91 ms at a realistic event rate).

**Unbounded list endpoints.** "Return the whole history" grows with retention, which a test with fresh users never
sees: 30 / 160 / 1,600 items took 7.8 / 19 / 140 ms and up to 5.6 MB uncompressed per app open (and 140 ms blocks the
worker's loop). Seed heavy users, price the curve, paginate with slim list items.

**Bursts and round trips on open.** Each extra request on app open pays the per-request tax and, cross-origin with a
custom auth header, a CORS preflight (an RTT; WebKit caps the preflight cache at 600 s, per exact URL, so
`Access-Control-Max-Age` can't fix it). An aggregated read endpoint for the open and a same-origin API path remove
most of it.

**Smaller ones, measure before trusting:** Sentry tracing at 100 % (~0.5 ms per request locally; sample 2–5 %,
skip `/health`, OPTIONS and streams); `gc.freeze()` after startup (a full collection of a big import graph took
120–145 ms, a stall of the only loop); `pool_pre_ping` is 3 round trips per checkout on asyncpg; in-memory rate
limiters that start a timer thread per request; uvicorn keep-alive above the proxy's idle timeout (avoids a 502
race); `MALLOC_ARENA_MAX=2` for RSS growth.

**Checked and not worth it (for us):** caching the validated user per token (~0.4 ms, and a cache incoherent across
workers); swapping JSON response classes (modern FastAPI already serializes via Pydantic); a newer Postgres major
(no gain; the DB was not the bottleneck); HMAC verification of auth tokens (~20 µs).
