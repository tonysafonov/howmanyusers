---
name: howmanyusers
description: Load-test, profile and optimize a web backend on rented servers, Arjay-McCandless-style ("how many users can this server hold") — two VPS boxes in one datacenter, calibration against a published reference implementation, a realistic closed-model k6 user journey built from real analytics, staircase then 5-minute holds with p95/p99/error criteria (streams judged on duration and completion), CPU price per endpoint, py-spy profiles at saturation, a fix ladder with A/B by commit, a chaos test (stop the DB under load, count 401/5xx), and an honest report with raw results. Use it whenever the user wants a load test, stress test, capacity estimate, "will it survive a launch / campaign / spike", benchmark of their API or framework against a reference, k6 scripts, a py-spy / flame-graph investigation of a slow Python backend, or to make a backend hold more users — even if they don't say "load test". Built on FastAPI/asyncio experience; the method works for any HTTP backend. Not for: frontend Web Vitals / Lighthouse, single-function microbenchmarks, or pointing load at production.
---

# howmanyusers

You run a performance lab for a web backend. The deliverable is a sentence a stranger can check — **"N users held
for 5 minutes on <box>, p95/p99, 0 errors; what breaks first is X; after these fixes, M; the reference holds R on
the same box"** — plus the tables, raw results and fixes behind it.

The method comes from Arjay McCandless's server challenges (github.com/arjaythedev: "how many users can a $12
server hold") and from load-testing an open-source FastAPI + Telegram Mini App framework and a production app built
on it: 220 → 1,400 users on 2 dedicated vCPU against a 3,400-user FastAPI reference, and a production stand that
stopped logging users out under load. Everything below is what actually worked or actually went wrong.

If `~/.claude/howmanyusers/house-rules.md` (or the older `~/.claude/perf-lab/house-rules.md`) exists, read it first: the owner's short list of things that went wrong for
them before. It beats anything here.

## Non-negotiables

1. **Never load-test production.** A stand that mirrors it: same image, server command, worker count, memory
   limits, restart policy, DB version; fake credentials; every third party stubbed.
2. **Two boxes, one datacenter.** Target runs the stand; a separate loader runs k6. Not the laptop, not k6 on the
   target. RTT ~0.2–0.5 ms.
3. **Ask before spending money.** Ordering, resizing, or cancelling servers needs the owner's explicit OK each time.
4. **Every request is checked for 2xx**, in every script. Fast errors look like capacity. A probe below 99.9 %
   checks has no price.
5. **Only compare numbers from one A/B run** (same stand state, same procedure, back to back).
6. **Profile at saturation only.** Below it, the idle event loop is sampled as busy.
7. **One change per fix step**, measured with the same procedure; steps that don't help stay in the table.
8. **Repeat before concluding at the edge.** One failing run at the boundary is noise until it repeats.
9. **Report honestly:** raw files for every number, corrections visible, measured vs estimated labelled.

## How to work

0. **Frame the question.** Which app and endpoints, what "a user" is, which peak to survive ("10× the last
   campaign"), which box size to quote, which reference to compare with. Read the code paths that serve the hot
   endpoints before renting anything.
1. **Rig** (`references/rig.md`). Order a target (dedicated cores) and a loader in one datacenter — any provider; a
   Synteq API recipe is included — with the owner's OK. Install Docker + py-spy on the target, k6 on the loader.
   Put `TARGET`, `LOADER`, `CONTAINER`, `BASE_URL` in an untracked `perf/rig.env`. Run `scripts/preflight.sh`.
2. **Calibrate** (`references/calibration.md`). Run a published reference (e.g. multicore-server-challenge's
   `examples/python`) with its own load generator, unchanged, on your target. Compare per core with its published
   score. If it's off, fix the rig first. Optionally build your framework's version of the same spec — the cleanest
   way to measure a framework's own overhead.
3. **Model the user** (`references/journey.md`). From analytics and frontend code: request waves per screen, think
   times, action mix, session length, new vs returning. Write `perf/k6/journey.js` from `templates/journey.js` and
   the model doc from `templates/profile.md`. Smoke at a few users; calibrate req/s per user against analytics.
4. **Stand** (`templates/stand-compose.yml`). Production's command and limits verbatim, a fresh DB per variant,
   stubs (`scripts/llm_stub.py` for OpenAI-compatible LLMs), signed test users (`scripts/tg_initdata.py` for
   Telegram Mini Apps), `warmup.js` for returning users, `RESET_CMD` for per-user quotas.
5. **Measure** (`references/load.md`). Staircase for the estimate, then 5-minute holds around it. Record CPU and
   memory per container, the app log, `pg_stat_activity`. Read the failure: CPU-bound, queueing, or a resource
   running out.
6. **Price and profile** (`references/profiling.md`). CPU per endpoint at saturation (`cpuprobe.sh`; the floor
   `/health`, the per-request tax `/me`, outliers), check the sum against a hold, py-spy the expensive ones
   (`pyspy.sh` → `stacks.py`). Turn shares into ms × rate.
7. **Fix ladder** (`references/fixes.md`). One change per step as a commit or overlay, re-measure with the same
   procedure, re-prioritise after each step (the bottleneck moves). `ab.sh` runs deploy → warm-up → prices → profile →
   holds for each variant.
8. **Chaos** (`scripts/chaos.sh`). Stop the DB (then Redis, DNS...) for a few seconds under load; count statuses.
   You want 503 + retry, never 401.
9. **Report** (`references/reporting.md`, `templates/report.md`). Answer first, rig, calibration, the user, results
   tables, ladder, chaos, corrections, what's left. Then propose the production rollout separately; it's the owner's
   call.

`references/pitfalls.md` lists every trap we fell into, symptom → cause → fix. Read it before step 5 and again
before step 9.

## The lab

```bash
S=<this skill dir>
cp -r $S/scripts/k6 perf/k6 && cp $S/templates/journey.js perf/k6/journey.js     # then write the journey
set -a; . perf/rig.env; set +a                     # TARGET LOADER CONTAINER BASE_URL K6_SRC RESET_CMD PYSPY ...
$S/scripts/preflight.sh                            # ssh, CPU/steal, RTT, health from loader, disk, open ports, tools
$S/scripts/load.sh staircase asis -e START=30 -e STEP=30 -e MAX=900 -e STEP_DUR=90   # estimate
$S/scripts/load.sh hold asis 300                   # verdict: 60 s ramp + 5 min hold -> results/asis-300/
$S/scripts/cpuprobe.sh endpointprobe.js 6 me -e EP='GET /users/me'                   # ms CPU per request
$S/scripts/pyspy.sh out/me.txt endpointprobe.js 6 -e EP='GET /users/me'              # profile at saturation
python3 $S/scripts/stacks.py top out/me.txt        # inclusive shares of a request (+ children / match / diff)
DEP=<db container> $S/scripts/chaos.sh before      # DB stopped 6 s under load: statuses + error window
DEPLOY_CMD='./perf/deploy.sh "$REF"' EPS='GET /health;GET /users/me' HOLDS='600 750' \
  $S/scripts/ab.sh out/auth base:<sha> new:<sha>   # same procedure per variant, one comparison table
BOT_TOKEN=<fake> python3 -I $S/scripts/tg_initdata.py 3000 > perf/k6/data/users.json   # Telegram test users
uv run --with aiohttp python $S/scripts/llm_stub.py                                    # OpenAI-compatible stub
```

Needs: ssh with keys to both boxes, rsync, python3 locally; Docker and py-spy on the target; k6 on the loader.
Scripts read `env.sh` (see its header for every variable); none contain hosts or keys.

What the scripts already do for you: reset + restart + health-check (from the loader) before every measurement;
refuse to price a probe whose responses aren't 2xx; refuse k6 env names the OS already sets; py-spy non-blocking
with a timeout on the busiest worker (host PIDs via `docker top`); per-step staircase verdicts; per-endpoint
p50/p95/p99/errors and req/s per user in every hold summary; streams judged on duration and completion; results and
`docker stats` copied back into `results/<label>/`.

## Criteria (defaults, Arjay's scoring)

| Requests | Pass |
|---|---|
| API (`kind:api`) | p95 < 500 ms, p99 < 1 s, over a 5-minute hold |
| everything | errors < 1 %; checks ~100 % |
| streams (`kind:stream`) | p95 duration < stub length + margin (default 30 s), > 99 % complete |

## Where to look

| When you want… | Read |
|---|---|
| boxes, sizing, setup, firewall/Docker ports, disk, the Synteq API recipe, env vars | `references/rig.md` |
| a reference to calibrate against (Arjay's challenges + published numbers), per-core comparison, building your stack's version | `references/calibration.md` |
| the user model: analytics → think times, request waves, streams, test users, warm-up, journey calibration | `references/journey.md` |
| staircase vs holds, criteria, what to record, reading a failure, the chaos test | `references/load.md` |
| CPU price per endpoint, py-spy at saturation, `stacks.py`, memory probes, frames to search for | `references/profiling.md` |
| the fix ladder procedure, the worked Conduit ladder, fixes that generalise (with numbers) | `references/fixes.md` |
| every trap we hit: symptom → cause → fix | `references/pitfalls.md` |
| what goes in the write-up, corrections, public claims | `references/reporting.md` |

## Talking to the owner

- Before renting: the plan, the boxes and their monthly price, what you'll answer. Wait for the OK.
- During: short updates with numbers ("as shipped holds 120, fails at 150: DNS failures turned into 401s").
- After: the answer sentence, the tables, the fixes ranked by gain over risk, what you would ship to production and
  in what order, and when to cancel the boxes. Never push a fix to production as part of the lab.
