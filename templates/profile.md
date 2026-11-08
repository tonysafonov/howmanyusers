# <app>: the user we load-test with

<!-- The journey's source of truth. journey.js cites this file; numbers here cite the analytics query or log window. -->

## Sources
- Analytics: <tool, window, filters (internal users and bots excluded)>
- Server log sample: <window>, read-only
- Frontend code: <files that fire requests on open and per screen>

## A session
- Sessions per user per day: <median / p90>
- Session length: <median / p75 / p90> (p90 is often "app left open": don't model it as activity)
- Screens or actions per session: <median / p90>
- Time between events inside a session: <p25 / median / p75 / p90>
- Mix of actions: <action: share, …>
- New vs returning share at the peak you care about: <x / y>

## Requests per screen
| Screen / action | Requests (in waves) |
|---|---|
| app open | `POST /…` then in parallel `GET /…`, `GET /…` |

## The peak to size for
<The busiest real window (e.g. users active in the same 5 minutes during a campaign) and the scenario you want to
survive (×N of it). Convert: <journey calibration: X users of this journey ≈ Y actions/hour> → peak ≈ Z journey users.>

## Model (what journey.js does)
- One VU = one person; one iteration = one session.
- <session types and their weights, think times per step, streams and their stub timing>
