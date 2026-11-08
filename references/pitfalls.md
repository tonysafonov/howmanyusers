# Pitfalls we actually hit (symptom → cause → fix)

Read this before the first measurement and again before you write the report.

**k6's `__ENV` contains the OS environment.**
Symptom: a probe showed every authenticated endpoint 40 % cheaper after a change; the realistic holds showed half
that. Cause: the probe pinned a user with `-e USER=…`-style code reading `__ENV.USER`; when the flag was absent,
`__ENV.USER` was the loader's OS user, `root`; the lookup returned `undefined`, every request carried
`initData: undefined` and got a fast 401, and the probe priced 401s for hours. Fix: never use names the OS sets
(`lib.js`'s `env()` refuses them); **check 2xx on every request in every script**; probes abort below 99.9 % checks
and `cpuprobe.sh` refuses to print a price; keep the wrong table in the report, marked INVALID, next to the re-measure.

**Per-user rate limits when pinning one user.**
Symptom: a pinned-user probe at saturation shows a cheap endpoint and a pile of 429s. Cause: the app's per-user
limit (e.g. 100/minute) trips in seconds. Fix: random users from a large pool; pin only to price data-size effects,
with limits off on the stand.

**py-spy hangs.**
Symptom: the profiling ssh never returns; the worker stalls. Cause: py-spy's default blocking mode stops the process
for every sample. Fix: `--nonblocking`, `timeout` around py-spy, a fixed `-d` duration (`pyspy.sh` does all three).

**uvloop's idle time counted as busy.**
Symptom: a profile at partial load where 77 % of samples are in uvloop's `run`, and every other share is tiny.
Cause: non-blocking sampling sees the idle event loop waiting in C and counts it. Fix: profile at saturation (one
endpoint in a tight loop); price CPU with `cpuprobe.sh` (container CPU / throughput), not with profile totals.

**`pgrep -f` finds itself.**
Symptom: `ssh target 'pgrep -f uvicorn'` returns a PID that isn't the server, py-spy attaches to a shell. Cause: the
pattern is in the remote shell's own command line. Fix: `docker top <container>` (host PIDs, the container's
processes only), or the `[u]vicorn` grep trick; pick the busiest worker, not the supervisor.

**The target's disk fills up.**
Symptom: builds fail, Postgres errors, a run dies halfway. Cause: a full image per variant on a 20 GB disk. Fix:
variants as thin layers over one base image; `docker image prune -a` between sessions; `preflight.sh` warns at 75 %.

**Comparing numbers across stand states.**
Symptom: the same endpoint cost 1.8 ms in one table and 3.6 ms in another. Cause: different stand states (days of
holds vs fresh, a different pool config). Fix: only compare inside one A/B run (`ab.sh` deploys and measures every
variant with the same procedure, back to back); repeat with alternating order (`a b b a`) when the difference is small.

**Docker-published ports bypass ufw.**
Symptom: a database answers from the internet although ufw "denies" its port. Cause: Docker writes its own iptables
rules ahead of ufw. Fix: publish only the app port, bind everything else to `127.0.0.1` or don't publish it, use the
provider's firewall, and test from outside with `nc -vz`. Check production compose files for the same mistake.

**Loader and target in different regions.**
Symptom: p50 never goes below 20–80 ms, even at 1 user. Cause: the network is in every request. Fix: same
datacenter, RTT ~0.2–0.5 ms (`preflight.sh`); note the RTT in the report.

**Single runs at the edge are noisy.**
Symptom: variant B fails at 900 users where A passed, and B "is a regression". Cause: one run each at the boundary,
where a single burst decides the verdict. Fix: repeat both before concluding; report "within noise" when it is.

**A staircase step fails on one sample.**
Symptom: the staircase stops at a step whose numbers look fine. Cause: a per-step threshold aborts on the first bad
sample (e.g. the first stream of the step) after the grace period. Fix: treat the staircase as an estimate and decide
with 5-minute holds.

**The loader is the bottleneck.**
Symptom: req/s plateaus while the target has idle CPU. Cause: k6 out of CPU, file descriptors or ephemeral ports.
Fix: watch the loader's CPU; `ulimit -n`, `ip_local_port_range`; a bigger or second loader with `LG_INDEX`/`LG_COUNT`.

**Fast errors look like capacity.**
Symptom: a variant "holds more" with a high error rate, or a hold passes with errors just under 1 %. Cause: errors
return in a millisecond and free the server. Fix: read errors by status and endpoint (the summary lists them) and the
app log for every run; a 401/5xx pattern is a finding, not noise.

**The stand isn't production.**
Symptom: great numbers that production never sees. Causes we've seen: the stand had no Sentry DSN (tracing cost
~0.5 ms/request in prod), an LLM stub with half the production event rate (streams looked ~2× cheaper), a different
worker count or memory limit, a stub on the target eating CPU production doesn't spend. Fix: mirror the production
command and limits; list every stand-vs-prod difference in the report.

**Fresh users only.**
Symptom: production is slower than the stand for loyal users. Cause: data grows per user (history, inbox, feeds) and
the test only has new ones. Fix: seed heavy users and price the curve.

**Warm-up overload.**
Symptom: the warm-up itself fails or the app restarts during it. Cause: a cold app at full concurrency (per-request
allocations, empty caches). Fix: warm up gently (a few VUs); if that's what kills it, you found the first finding.
