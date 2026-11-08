# The user: a realistic closed-model journey

The load test measures what the journey says a user does. Get the journey wrong and every number after it is about
somebody else.

## Closed model, one VU = one person

- **Closed model:** a fixed number of users, each doing request → wait → think → next request. When the server
  slows down, users slow down with it, the way people do. An open model (k6 sends N req/s no matter what) is right
  for a raw RPS ceiling, and wrong for "how many people can use this at once".
- **One VU = one person** with the app open; one iteration = one session; think times between steps. The capacity
  is then quoted in users, the unit everyone understands.
- Default criteria (Arjay's): a 5-minute hold passes with API p95 < 500 ms, p99 < 1 s, errors < 1 %.

## Where the numbers come from

| What | Source | Typical query |
|---|---|---|
| Request sequence per screen | the frontend code (what fires on open, per screen, after an action) **and** a real browser's network log (headless Chrome against a dev build) | which calls are awaited, which go in parallel (they arrive as a burst) |
| Session length, screens per session | product analytics (PostHog, Amplitude, GA): sessions by `$session_id` | median / p75 / p90; p90 is often "app left open", not activity |
| Think time | time between consecutive events in a session | p25 / median / p75 / p90; sample uniform between ~p25 and ~p75, longer after content (reading an answer) |
| Action mix | event counts or DB rows by type over the window | shares; drop admin, bots, internal users and one-off batch jobs (a "spike" of identical events within one minute is usually a backend batch, not people) |
| New vs returning | sign-up date vs session date | first sessions usually run onboarding and are heavier in writes |
| Peak to size for | the busiest real window: users active in the same 5 minutes | then decide the multiple you want to survive |

A tiny app's daily traffic is too thin for statistics. Take the **request sequence** from code and log samples, the
**think times and mix** from the busiest period you have (a campaign), and the **user count** from the question
("would a campaign 10× the last one fit?"), not from today's peak.

Read production data read-only and keep only aggregates in the repo; no user ids, no message text.

## Writing journey.js

Start from `templates/journey.js`. Things that matter:

- **App open is a burst.** A Mini App or SPA open fires 5–15 requests in two or three waves. Model the waves with
  `http.batch` exactly as the frontend fires them: bursts grow the latency tail far more than the same requests spread
  out. Update the journey when the frontend changes (an aggregated "open" endpoint cuts the burst; the journey must
  follow).
- **Name every URL with an id** (`GET /items/:id`) and leave k6's `url` tag off (lib.js does): one time series per id
  exhausts k6's memory.
- **Check every response** (`ok(res, name)`): a 401 is fast, and fast errors look like capacity.
- **Streams** (LLM answers over SSE/NDJSON, exports): use `stream()` from lib.js. k6 waits for the whole body, so the
  request's duration is the stream's duration; it is tagged `kind:stream` and judged on p95 duration and on reaching
  the done marker, never on the 500 ms API criterion. The user then reads the answer (a long think).
- **Third parties are stubbed** with realistic timing: an LLM with first token after 1–2 s and the production event
  rate (`scripts/llm_stub.py`; the per-event rate matters for CPU, see its docstring), payments and analytics off or
  stubbed. No real keys on the stand, ever.
- **CORS preflights** are answered by the CORS middleware before the app; leave them out of the journey and price
  them separately if they matter (they cost the server ~the `/health` floor, but cost the client an RTT each).
- **Users:** generate signed test credentials (`scripts/tg_initdata.py` for Telegram Mini Apps; JWTs with the
  stand's secret otherwise), `warmup.js` creates the returning ones before any measurement, and `RESET_CMD` resets
  per-user quotas (daily limits, balances, paywall counters) before every run, or the second hold measures paywalls.
- **Several load generators** must not share users: `LG_INDEX` / `LG_COUNT`.
- **Don't start in lockstep:** a random pause before each VU's first iteration (the template does it).

## Calibrate the journey itself

Run a hold at a low user count (e.g. 30) and compare with the analytics before trusting it:

- req/s per user (the hold summary prints it), sessions per user-hour, actions per session, session length;
- all checks 100 %, all streams complete.

Then convert to business units. Hypothetical example: if 30 journey users produce 600 actions/hour and the busiest
real hour had 200 actions, that peak ≈ 10 concurrent journey users, and a hold of 300 users is "30× the real peak".
Every capacity number can then be quoted that way.

Write the model down in `templates/profile.md` (copy to your repo) so the next person can audit it.
