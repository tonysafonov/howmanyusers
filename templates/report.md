# <app> under load: <one-line question>

<!-- Fill from results/. Every number in this file must point at a raw file in results/. -->

**Answer:** <N users held for 5 minutes on <box>; what breaks first; after the fixes, M users.>

## Rig

| Role | Spec | Notes |
|---|---|---|
| target | <vCPU dedicated/shared, RAM, CPU model, OS, kernel> | <provider, region> |
| load generator | <vCPU, RAM> | same datacenter, RTT <x> ms; loader CPU peak <y>% |

Stand: <what runs on the target: app command, workers, memory limits, DB version and size, stubs>. Code: <commit(s)>.

## Calibration

Reference <implementation> on the same box with its own load generator, unchanged: **<N> users** (<req/s>, p95 / p99,
errors). Published: <N'> on <their box>. Per core: <ours> vs <theirs> → <the rig behaves like theirs / doesn't, because…>.

## The user

<One paragraph: where the journey comes from (analytics window, sessions, think times, action mix, request sequence per
screen), and the calibration of the journey itself: req/s per user and actions per session vs the analytics.>
Criteria: API p95 < 500 ms, p99 < 1 s, errors < 1 %; streams p95 < <x> s, > 99 % complete; 5-minute hold.

## Results

| Variant (commit) | Holds 5 min | Fails at | req/s | API p95 / p99 | errors | What breaks first |
|---|---:|---:|---:|---|---:|---|
| as shipped (<sha>) | | | | | | |
| + fix 1 … | | | | | | |
| reference | | | | | | |

### What each request costs (ms CPU at saturation, one table = one stand state)

| Endpoint | <variant A> | <variant B> |
|---|---:|---:|
| `GET /health` (floor) | | |

### Where the time goes (py-spy at saturation, share of a request)

| Share | What | Why |
|---:|---|---|

### Chaos: <dependency> stopped for <n> s under load

| Variant | 2xx | 401 | 5xx | 503 |
|---|---:|---:|---:|---:|

## Fix ladder

1. **<change>** (<commit / overlay>) → <N users> (<×>), <req/s>, p99 <x>. <one sentence: why it helped, or why it didn't>

## Corrections

<Anything measured wrong, what was wrong, the re-measured numbers. Keep the wrong table, struck through or marked INVALID.>

## Not done / open

<Levers left on the table by choice, measurements not repeated, anomalies seen once.>

Raw results: `results/<date>-<label>/` (k6 summaries, docker stats, profiles, deploy logs).
