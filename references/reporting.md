# Reporting: honest numbers

The write-up is the product. A reader should be able to check every number, rerun any of it, and know what wasn't
measured. Template: `templates/report.md`.

## Rules

- **Lead with the answer:** "N users held for 5 minutes on 2 dedicated vCPU; first to break: X; after the fixes, M."
- **Every number has a raw file** in `results/<date>-<label>/` (k6 JSON + text, docker stats, profiles, the deploy
  log with the commit). Commit them; they are small.
- **Tables, not prose,** for anything with more than two numbers: holds per variant, CPU per endpoint per variant,
  profile shares, chaos counts, the fix ladder.
- **Say what each variant is:** commit SHA, overlays, workers, pool, memory limits, DB version. "Fixed" is not a variant.
- **Compare within one run.** Put the baseline re-measured in the same A/B next to the change, even if an older table
  exists. Say so when two tables come from different stand states.
- **Include what didn't help** (a fix step with no gain stays in the ladder with its number) and **what was left on
  the table by choice** ("uvicorn and SQLAlchemy stay").
- **Corrections stay visible.** When a measurement turns out wrong, mark the table INVALID with one line on why,
  add the re-measured table below, and fix every claim that used it. Silently replacing numbers destroys trust in
  the rest.
- **Separate measured from estimated.** "Expected −20 ms per open" is a plan; "measured 12.8 → 2.8 ms" is a result.
  Label local microbenchmarks as such: they give ratios, not absolute numbers for the box.
- **Stand vs production:** list the differences (no tracing DSN, stubbed LLM and its event rate, worker count, a
  stub on the box, fresh users) and the direction each one biases the result.
- **Anomalies seen once** are reported as anomalies, not explained away and not turned into findings.
- **Security findings** (an open port, tokens that never expire) go in their own section, privately, and are fixed
  before anything goes public.

## Public claims

For a README, a post or a video, one honest line with the context that makes it checkable:

> Load-tested on Arjay McCandless's multicore Conduit benchmark (2 dedicated vCPU, same procedure as the
> leaderboard): 1,400 users held for 5 minutes, p99 < 1 s, 0 errors. The plain FastAPI reference holds 3,400 on the
> same box; the framework as first shipped held 220. Method and raw results: <link>.

Always name the rig, the procedure, the reference on the same box, and the "before". A number without its reference
is marketing; with it, it's a measurement.

The handoff for whoever releases (config-only edits, security section, rollout order, after-release checks) is `templates/handoff.md`; see references/rollout.md.
