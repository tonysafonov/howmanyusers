# Pre-scan: read the code before renting anything

An hour with the code finds most of what a load test would find first, for free. Every pattern below cost real users
or real capacity in a backend we tested; the numbers are what fixing it was worth there. A pre-scan finding is a
**hypothesis**: write it down with its file and line, then confirm or kill it with a measurement (a CPU price, a
profile, a hold). Never report a pre-scan finding as a measured result.

## How to run it

1. **Map the hot path.** What an app open or a page load sends (frontend code: what fires on mount, per screen),
   the endpoints with the most traffic (access logs, analytics), and what every request pays before the handler:
   middleware, auth, dependency injection, the DB session, logging. No logs or analytics (an open-source framework,
   a new app)? Use the frontend's mount code and the route table. Rare but heavy paths (login, payments, exports)
   still get a look: one blocking call there stalls everyone on that worker.
2. **Walk the checks below** over that path, plus process setup (server command, worker count, pool settings,
   container limits) and anything streamed.
3. **Report** one table, most expensive first:

   | # | Pattern | Where (file:line) | Why it costs | Expected effect | Fix | How to confirm |
   |---|---|---|---|---|---|---|

   "Expected effect" is an estimate and is labelled as one. "How to confirm" names the probe: `cpuprobe.sh` on the
   endpoint, a py-spy frame to look for, a hold, `pg_stat_activity` during a hold.
   - **Ranking without measurements:** by the damage of one occurrence (stalls a worker, caps a user group, fails
     requests) before per-request cost; say which rule you used.
   - **Report the clean checks too**, one line each with the file:line that shows it: "per-request clients: clean"
     is a result, and it stops the next person from re-checking.
   - **Numbers from this file** are what a pattern cost *elsewhere*: cite them as such ("cost 7 ms per request in
     another backend"), never as a measurement of the scanned code.
   - Keep table cells short; put the reasoning in a numbered list under the table.
   - Example output: [`examples/prescan-gramkit.md`](../examples/prescan-gramkit.md).
4. Hand the list to the fix ladder (`references/fixes.md`): the measurement decides the order, not the pre-scan.

## The checks

### Built per request: clients, pools, SSL contexts
Search request-scoped code (dependencies, middleware, service constructors, lazy properties on per-request objects)
for anything that opens connections or loads certificates:
- Python: `Bot(`, `aiohttp.ClientSession(`, `httpx.AsyncClient(`, `create_pool(`, `Redis(`, `AsyncOpenAI(`,
  `ssl.create_default_context(`, SDK clients in `__init__` of a service built per request, `@cached_property` that
  constructs a client on an object that lives one request.
- Node/TS: `new Bot(`, `new Redis(`, `new OpenAI(`, `new Pool(`, `new Queue(` inside a handler or a per-request
  factory.

Seen: a Telegram `Bot()` per request was **55 % of request CPU (≈ 7 ms)**; one per process took a framework from 220
to 500 users. The same pattern hid in a payments provider (12.8 → 2.8 ms per request) and an admin-alert path.
Memory grows with requests in flight, so a burst can OOM the container. Fix: one per process, created at startup,
closed at shutdown.

### Blocking calls on the event loop
In async code (FastAPI/Starlette `async def`, Node handlers), anything synchronous stops every request on that worker
while it runs:
- Python: `requests` (and SDKs built on it: many payment and email SDKs, e.g. `yookassa`, `resend`), `time.sleep`,
  `subprocess.run`, sync file I/O on big files, CPU-heavy work inline: password hashing (Argon2 at 64 MiB, bcrypt at a
  high cost), image processing, large `json.dumps`. Grep `import requests`, the SDK's `.create(` / `.send(`, `hash(` /
  `verify(` inside `async def`.
- Node/Bun: `*Sync` fs and crypto calls (`pbkdf2Sync`, `scryptSync`), sync bcrypt, big synchronous loops.
Also check for missing timeouts on those calls. Fix: an async client, or `asyncio.to_thread` / a worker pool with a
bound (a semaphore), so a burst of logins can't take every thread.

### Shared rows and shared keys
- A write to the same row on every request: a shared guest/anonymous user upserted per request, a global counter, a
  singleton settings row. Under a transaction it holds the row lock until commit, so those requests run one at a time.
- Rate limits keyed on an identity many callers share: every logged-out visitor mapped to one guest id shares one
  bucket, so the limit caps the whole anonymous audience, not one visitor. Check the key function of every limiter.
- Global mutable state used per request (a module-level object holding the current user's locale or tenant) instead
  of a context variable: under concurrency one request reads another's value.
- Load-test side: per-user limits fail a run that uses too few test identities; generate enough users.

### Pool sizes against the database's connection limit
`pool_size + max_overflow` (or `max`) × workers × every process that connects (web, bot, background workers) must stay
under Postgres' `max_connections`. A large overflow (`max_overflow=200`) also means a new TCP connection, a DNS lookup
and maybe TLS for every waiting request.
Seen: "too many clients" collapsed throughput to a fraction above ~870 users; a bounded pool (10 per worker, no
overflow) moved the ceiling from 830 to 1,000. Fix: size the pool per worker; requests then wait instead of failing.
`pool_pre_ping` (SQLAlchemy) adds a round trip per checkout (on asyncpg: a `BEGIN; ; ROLLBACK`): about 1 % of a request
where we measured it. Keep it if the chaos test needs it; just count it.

### Connection churn plus Docker DNS plus an auth catch-all
Each new connection to `db` / `redis` resolves the name through Docker's embedded DNS, which fails under churn
(`[Errno -3] Temporary failure in name resolution`). Then look at authentication: does an `except Exception` around
user resolution answer 401, or fall back to a guest?
Seen: 72 % errors in a hold, every one a 401: **a traffic spike would have logged real users out.** Fix the churn
(per-process clients, bounded pools) and the mapping: infrastructure errors in auth are a 503 with `Retry-After`, and
the client shows a retry screen. Confirm with the chaos test.

### Transactions held across slow I/O
A request-scoped DB session or transaction that stays open while the handler streams an LLM answer, calls a slow API
or waits on a queue. Look for streaming responses whose generator closes over the request's session.
Seen: 25 connections all `idle in transaction` during 20-second LLM streams; every other request waited for the pool
(p99 9.2 s at 60 users). Fix: checks on the normal session, commit, stream with no transaction, save the result in a
short transaction afterwards. Never shrink the pool before this fix.

### Framework slow paths
- FastAPI: `app.dependency_overrides` set outside tests makes FastAPI rebuild every dependency tree on every request:
  **29–35 % of a light request**; removing it took a stand from 600 to 750 users.
- Starlette `BaseHTTPMiddleware` (a task and a memory stream per request): pure-ASGI middleware took 1,000 → 1,200.
- A dependency that pulls five sub-dependencies (bot, queue, Redis, producer, session) on every route when most routes
  need one: resolving only the session took 1,200 → 1,300. That was before those clients were per-process; when the
  sub-dependencies are trivial getters, expect much less.

### Logging on the event loop
A per-request INFO line and an access log written synchronously to stdout (a container pipe) block the loop.
Look for extra per-request log lines beyond one access line, f-strings formatted for disabled levels, handlers
without a queue/listener thread. Seen: 9 % of a request in `StreamHandler.flush`; the last ladder step (1,300 →
1,400) was removing one INFO line. Fix: one access line, debug-level details with lazy formatting, writes off the loop. Even with a listener thread, the
formatting and the thread's time remain: fewer lines is still the bigger win.

### One process on many cores
`uvicorn` with `--workers 1`, a single Node process, gunicorn with one worker, on a multi-core box. Seen: one worker
held 710 users with the second core idle; a worker per core held 1,300 (and memory multiplies: count it).

### Statements the database plans on every call
- Drizzle's query builder sends unprepared statements unless you call `.prepare()`: **+22 % (Node) and +32 % (Bun)**
  users from preparing the hot queries, with ~40 % less Postgres CPU per request.
- `node-postgres` (`pg`) sends unnamed statements by default (Arjay's JS benchmark: median +14 % from naming them).
- asyncpg, postgres.js and Bun.sql prepare automatically; check that a pooler (PgBouncer in transaction mode) isn't
  silently turning that off.

### What an app open sends
- Endpoints returning whole histories or lists, unpaginated: one returned 5.6 MB and blocked its worker 140 ms for a
  heavy user. Paginate; send page one on open.
- Ten parallel requests per open, each authenticating against the DB: count the per-request tax × requests per open.
- Large JSON with no compression anywhere (app or proxy).
- A cross-origin API with a custom auth header: a CORS preflight before every request and a second TLS connection.
  This is latency for the user, not server CPU: serve the API on the app's origin.

### Streams
Relaying an LLM answer one event per token through several generator layers, building an SDK model object per chunk:
a reading cost 197 ms of CPU through a heavy client vs 91 ms through a plain SSE parser with ~100 ms chunk merging.
Check the HTTP connector's connection limit (aiohttp's `TCPConnector` defaults to 100, httpx to 100) against
concurrent streams: at the default, stream p95 reached 43 s at half a core.

### Timeouts and keep-alive
- Server keep-alive shorter than users' think time (Node's default is 5 s): every request reconnects.
- Outbound calls with no timeout: one slow third party holds workers and connections.

### Observability overhead
Tracing or profiling at a 100 % sample rate in production, a span per DB query, request bodies captured into
breadcrumbs. One stand under-counted ~0.5 ms per request because it ran without the tracing DSN production has: mirror
it on the stand, or count it.

### Side findings worth a line (not performance)
Database or Redis ports published by Docker (they bypass ufw), tokens that never expire, webhooks that accept
unsigned requests. Report these privately, separately from the performance list.
