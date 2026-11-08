# Calibrate against a reference

"Our app holds 900 users" means nothing until a reader can place it. Before measuring your own stack, run a
**published reference implementation on your rig, with its own load generator, unchanged**, and compare with its
published score. Then you know (a) your rig behaves like theirs, and (b) what "good" looks like on this exact box.

## Where references come from

Arjay McCandless's challenges (github.com/arjaythedev) are the best source we know: a fixed spec, a load generator
with a realistic closed-model user, a fixed scoring procedure, and dozens of implementations with published scores.

| Challenge | Workload | Box | Useful Python references (published) |
|---|---|---|---|
| `multicore-server-challenge` | Conduit (Medium clone, 19 endpoints), Postgres on the same box, Nginx in front | 8 dedicated vCPU | `examples/python` (FastAPI + uvicorn workers + asyncpg, idiomatic and untuned): 10,000 users / 2,634 req/s. `examples/go` 24,000 (rig calibration). Tuned Python: uvloop 46,000, raw sockets 78,000 |
| `twelve-dollar-server-challenge` | feed + post, SQLite only, no Redis | 1 vCPU / 2 GB | plain FastAPI 48,000; FastAPI + Granian 70,000; PyPy 90,000 (top C/io_uring entry 295,000) |
| `million-users-challenge` | Postgres on a separate box | 4–16 cores | `examples/python` 51k / 104k / 213k on 4 / 8 / 16 cores |

Numbers as published in late 2026; re-check the leaderboards. Scores are "users held for a 5-minute hold with p95 <
500 ms, p99 < 1 s, < 1 % errors", where a user is a person with think times (≈ 1 request every few seconds), not a
request per second.

Pick the reference whose workload is closest to yours: same language and framework family, a real database, auth.
For a FastAPI-based framework, multicore's `examples/python` is the natural baseline: it *is* FastAPI without your
layers, so "reference minus yours" is the cost of your layers.

## Procedure

1. Use their box setup and load generator verbatim (their `setup-box.sh`, pgtune, seed data with matching checksums,
   their `loadgen search`: warm-up, doubling probes, bisection to 5 %, 5-minute holds). Write down every deviation
   (we had to skip one conformance check whose request takes 26–30 s on 2 cores and isn't in the load mix).
2. Note box CPU split during the hold (`docker stats` / `pidstat`: app, Postgres, Nginx) and the loader's CPU (it
   must be far from saturated: ours was 3 %).
3. Compare **per core** with the published score when your box is smaller. Example: their 8 vCPU held 10,000 users
   (1,250 per core, and that run left CPU idle); our 2 vCPU held 3,400 (1,700 per core) on the same CPU model.
   Plausible, so the rig is trusted. If you're off by 2× per core, find out why before going further (region, steal
   time, loader saturation, a different CPU, a missing tuning step).
4. Compute CPU per request for the reference: box CPU × cores / req/s. Ours: ≈ 2.2 ms of box CPU per request, ≈ 1.2
   ms for the app alone. This is the yardstick for your own per-request prices later.

## Build your stack's version of the reference workload

The strongest comparison: implement the reference spec **on your framework, the way your templates build an app**
(same dependency wiring, same ORM layer, same middleware, same server command, same pool settings), pass the same
conformance suite, and run the same `loadgen search`. Then the only difference is your framework's overhead, and the
fix ladder (references/fixes.md) can climb towards the reference on the same scale. Keep the spec-forced
differences (auth scheme, error shape) and write them down.

Rules: copy the template's code verbatim ("as shipped"); ship fix steps as overlays over it, never edits to the
baseline; build outside any directory a sync script might wipe.

## After calibration: your real app

The reference tells you about the rig and the framework. Your production app's capacity comes from its own
realistic journey (references/journey.md) on a stand that mirrors production (`templates/stand-compose.yml`), and is
reported in your own units ("× the biggest campaign peak so far"), not in Conduit users.
