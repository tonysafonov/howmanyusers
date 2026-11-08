# Production handoff: <app>, from the load-test stand (<date>)

<!-- Written for whoever releases to production, possibly weeks later. Everything here is on <branch>/<staging> and NOT
     on production. Background and raw numbers: <report path>. Keep it a checklist, not a story. Section 3 holds
     security findings: keep this file private, or delete section 3 before it goes anywhere public. -->

Status: <not released | released <date>>. Why not yet: <one line, e.g. "too many changes at once">.
Diff size: <N commits ahead of production>, including <other people's work?>.

## 1. What the stand proved

| Setup (same box, same journey) | Users held 5 min | Failure mode |
|---|---:|---|
| production as it runs today | <N> | <first thing to break> |
| + everything in section 2 | <M> | <next thing to break> |

Stand vs production differences and the direction each biases the result: <list; see reporting.md>.
Raw files: `<results dir>`.

## 2. What a normal release already carries

No extra production edits; the usual release path ships these. One row per change.

| Change | Commits / PR | Check after release |
|---|---|---|
| <fix, in one line> | `<sha>` | <one command or screen: expected output> |
| <migration, e.g. new index> | `<sha>` | runs at deploy, <duration measured on N rows>; <the screen that uses it> |

State what production does NOT get from these (e.g. "runs 1 worker, so it gets the per-request savings but not the
2-worker capacity until 3.x").

## 3. Production-only config edits (compose / env / proxy)

Not in the release because production's config lives outside the code path. For each: what, why, the exact snippet,
what the staging stack already proves, the after-deploy check.

### 3.1 <edit, ordered by urgency: security first>
- Why: <finding or measured gain>
- Edit: <snippet>
- Proven on staging: <what, which commit>
- Verify after deploy: `<command>` must <expected>. Rollback: <how>.

### 3.2 Workers / pool / memory (capacity)
Workers <old> -> <new>; memory limit <old> -> <new>; pool per process <a> + overflow <b>.
Budget: `processes x (pool + overflow) + other clients < DB max_connections` = <sum> < <limit>. Check free memory on
the host first (`docker stats --no-stream`). Measured on the stand: <before> -> <after>.

## 4. Security findings (private)

| Finding | Evidence (how it was checked, when, from where) | Fix | Done |
|---|---|---|---|
| <e.g. DB port reachable from the internet> | <command + result> | <edit, see 3.1> | [ ] |
| <credentials exposed for an unknown time> | | rotate: new secret in the env store + change it in the DB, redeploy | [ ] |
| <auth token that never expires / is never checked> | | <proposal> | [ ] |
| <end-of-life component (e.g. Postgres major)> | | rehearsed upgrade: `scripts/pg_rehearse.sh`, runbook <path> | [ ] |

Also: remove routes/domains that expose internals; check logs for attempted logins while the port was open.

## 5. Rollout order

1. Security edits first (3.1 and section 4's quick ones), alone if you can: they are independent of the code.
2. Staging stack builds the release; check section 2's rows there.
3. Release to production; check section 2's rows again.
4. Config edits one at a time (proxy / origin, then workers + memory), each with its check, so a regression has one cause.
5. Capacity change last, with `docker stats` watched for a day (memory, `RestartCount`).
6. Re-measure the user-facing metric (<analytics event>) two weeks later against the baseline below.

## 6. Baseline to compare against later

| Metric | Source, window, filters | Before |
|---|---|---|
| <e.g. app-load time p50 / p75 / p95> | <analytics query, last 90 days, minus test accounts> | <values> |
| <errors, restarts, memory at peak> | <where to read it> | <values> |

## 7. Not blocking (open items)

- <deprecated endpoint to remove after old clients age out (~N weeks)>
- <perf backlog items with the report section that ranks them>
- <flaky test, analytics oddity, device-only visual check>
- Stand servers: <paid until date>; cancel if no more load tests are planned (the owner's call).
