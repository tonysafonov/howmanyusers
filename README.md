# howmanyusers

**How many users can your app actually hold?** Find out before launch, not during it.

A Claude Code skill that load-tests your backend the way Arjay McCandless scores servers in his
"how many users can a $12 server hold" videos: two rented boxes in one datacenter, a realistic user built from your
analytics, 5-minute holds judged on p95 < 500 ms, p99 < 1 s and < 1 % errors. Then it finds out why the number isn't
higher, fixes it one step at a time, and writes it up so a stranger can check it.

> "It should be fine" is not a capacity plan.

## Install

<details open>
<summary><strong>Claude Code</strong> (one step, updates itself)</summary>

```bash
claude plugin install howmanyusers --marketplace tonysafonov/skills
```

Or in a session: `/plugin install howmanyusers --marketplace tonysafonov/skills`. On Claude Code older than 2.1.275,
add the marketplace first: `claude plugin marketplace add tonysafonov/skills`, then
`claude plugin install howmanyusers@tonysafonov`.

</details>

<details>
<summary><strong>Any other agent, or editable files</strong></summary>

```bash
git clone https://github.com/tonysafonov/howmanyusers ~/howmanyusers
ln -s ~/howmanyusers/skills/howmanyusers ~/.claude/skills/howmanyusers   # or your agent's skills folder
```

Update with `git pull`.

</details>

Optional: personal rules the skill reads first (`~/.claude/howmanyusers/house-rules.md`; see
`skills/howmanyusers/house-rules.example.md`). Then ask your agent *"how many users can this app hold?"* in your
project. It reads the code paths first, proposes the rig and its price, and waits for your OK before anything is rented.

## Why it exists

**#1: Nobody knows the number.** "It should be fine" until the launch post lands. The skill gives you one number a
stranger can check: users held for 5 minutes on a named box, with p95/p99 and 0 errors, next to a published reference
on the same box.

**#2: The first spike breaks things a benchmark never shows.** On a production Mini App, a traffic spike made Docker's
DNS fail under connection churn, and the auth code turned that into 401s: **users logged out mid-campaign**. A burst of
app opens OOM-killed the container. Both came out on a test stand built from the app's real user journey, not from a
hello-world requests-per-second test.

**#3: Optimising blind.** Guesses about "the slow part" are usually wrong. The skill prices CPU per endpoint, profiles
at saturation, and climbs a fix ladder one change at a time, each step measured the same way, so the table says what
each fix was actually worth (including the ones that weren't).

**#4: Load tests that lie.** Fast errors look like capacity, numbers from different days don't compare, and a load
generator on the same box measures itself. Every rule the skill won't break (below) is one of those mistakes we made.

## What it found so far

**A Python framework, 220 → 1,400 users on the same 2-vCPU box** ([gramkit](https://github.com/tonysafonov/gramkit),
Arjay's multicore Conduit benchmark). No new hardware, just profiling under load:

| Step | Users held 5 min |
|---|---:|
| as shipped | 220 |
| one Telegram `Bot` and one Redis pool per process (the per-request `Bot()` was 55 % of CPU) | 500 |
| one worker per core | 830 |
| DB pool bounded below Postgres' `max_connections` | 1,000 |
| pure-ASGI middleware | 1,200 |
| lean per-request dependencies | 1,300 |
| no per-request INFO log line | 1,400 |

**A production Telegram Mini App, 120 → 900 users**, with a realistic journey (app-open bursts, streamed LLM answers)
built from its analytics and logs. Before any fix, the test found the failure that matters most: under a traffic
spike, per-request connections overwhelmed Docker's DNS and the auth code turned those failures into 401s, **logging
real users out mid-campaign**. A burst of app opens also OOM-killed the container. Both showed up on a test stand, not in front of
users.

**Python vs TypeScript, same box, same night** ([gramkit-ts](https://github.com/tonysafonov/gramkit-ts), the same
framework ported to TypeScript, on the same Conduit benchmark):

| Setup (2 workers each, 2 dedicated vCPU) | Users held 5 min | App CPU per request |
|---|---:|---:|
| Python (FastAPI + SQLAlchemy) | 1,200 | 3.9 ms |
| TypeScript on Node (Hono + Drizzle) | 2,700 | 1.5 ms |
| TypeScript on Bun | 2,800 | 1.3 ms |
| TypeScript on Bun, hot queries `.prepare()`d | 3,700 | 1.1 ms |
| plain FastAPI, no ORM (the challenge's reference) | 2,700 | 1.4 ms |

Along the way: Drizzle's query builder sends unprepared statements by default, and `.prepare()` on hot queries was
worth +22 % (Node) to +32 % (Bun). Details: [gramkit-ts benchmark](https://github.com/tonysafonov/gramkit-ts/blob/main/docs/benchmarks/2026-11-08-conduit.md).

"Users" here are simulated people held for 5 minutes, each with think times between requests, as in Arjay's
challenges; not requests per second.

## What it costs

Two small VPS in one datacenter: a target with dedicated cores and a load generator. Ours were Synteq boxes at
$9.40 + $7.60 a month; Arjay's sponsor Synteq offers a $20 credit at [synteq.com/arjay](https://synteq.com/arjay)
(check the current terms), which covers a month of both. Any provider works. Cancel when you're done; ordering and
cancelling servers is always your call, never the skill's.

## Ways to use it

- **Pre-scan, no servers** (an hour): it reads your hot path and lists what will break first, with file and line,
  from the patterns that cost real capacity in the case studies above. Free, and often enough.
  Example: [a pre-scan of gramkit](examples/prescan-gramkit.md), what was left after its own fix ladder.
- **Launch or campaign readiness:** model your real users from analytics and logs, build a stand that mirrors
  production, find the number, fix it step by step, test what happens when the database blips, hand off a release plan.
- **Framework benchmark:** build a published spec (Arjay's Conduit) on your framework and score it next to the
  challenge's reference on the same box.
- **Stack comparison:** two stacks, same app, same box, same night, raw results published.

## What you get

- **The procedure** (`skills/howmanyusers/SKILL.md`): frame the question, rent and check the rig, calibrate against a published reference,
  model the user, build a stand that mirrors production, staircase then 5-minute holds, price CPU per endpoint,
  profile at saturation, a fix ladder with one change per step, a chaos test, an honest report.
- **References loaded on demand:** rig and a Synteq API recipe, calibration (Arjay's challenges and their published
  numbers), the user journey from analytics, load and how to read a failure, profiling, fixes that generalise (with
  numbers), every pitfall we fell into (symptom → cause → fix), reporting, rollout (the production handoff and a
  Postgres major-upgrade rehearsal).
- **Scripts:** preflight (RTT, steal, disk, ports open past the firewall), staircase and hold runs with per-endpoint
  p50/p95/p99 and error checks on every request, CPU price per endpoint, py-spy at saturation and a stack classifier,
  a chaos test, an A/B runner by commit, a memory burst probe and a stream CPU probe, a Postgres major-upgrade
  rehearsal with a database fingerprint diff, an OpenAI-compatible LLM stub, signed Telegram Mini App test users.
- **Templates:** a k6 user journey, a stand compose file, the user-profile doc, the report and the production handoff.

## Running the scripts by hand

```bash
S=~/howmanyusers/skills/howmanyusers      # wherever the skill lives
mkdir -p perf && cp -r $S/scripts/k6 perf/k6 && cp $S/templates/journey.js perf/k6/journey.js   # write your user here
export TARGET=root@<target> LOADER=root@<loader> CONTAINER=<app container> BASE_URL=http://<target>:8000
$S/scripts/preflight.sh                                   # RTT, steal, disk, ports open past ufw, tools
$S/scripts/load.sh staircase asis -e START=30 -e STEP=30   # estimate
$S/scripts/load.sh hold asis 300                           # verdict: 5-minute hold
$S/scripts/cpuprobe.sh endpointprobe.js 6 me -e EP='GET /users/me'   # ms CPU per request (refuses non-2xx)
$S/scripts/pyspy.sh out/me.txt endpointprobe.js 6 -e EP='GET /users/me' && python3 $S/scripts/stacks.py top out/me.txt
DEP=<db container> $S/scripts/chaos.sh before              # DB down 6 s under load: 503 good, 401 bad
DEPLOY_CMD=... $S/scripts/ab.sh out/x base:<sha> new:<sha> # same procedure per variant, one table
```

Needs ssh keys to both boxes, Docker on the target, k6 on the loader, python3 locally. No hosts or keys live in the
scripts.

## Rules it won't break

- Never load-tests production. It builds a stand that mirrors it.
- Two boxes, one datacenter: the load generator never runs on the target or your laptop.
- Asks before spending money.
- Checks every response for 2xx: fast errors look like capacity.
- Compares numbers only within one run, and keeps corrections visible.

## Credits

Arjay McCandless: the challenges, the scoring, and `realistic-load-test` (MIT), from which `lib.js`, `hold.js` and
`staircase.js` are adapted (his licence is next to them in `skills/howmanyusers/scripts/k6/`). [k6](https://k6.io),
[py-spy](https://github.com/benfred/py-spy). Previously published as `perf-lab`. More skills:
[tonysafonov/skills](https://github.com/tonysafonov/skills).

## License

MIT
