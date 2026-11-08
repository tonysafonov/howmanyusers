/**
 * journey.js: ONE user of YOUR app. hold.js, staircase.js and warmup.js import it. Copy it next to lib.js as
 * journey.js and rewrite the EDIT parts from your own data (references/journey.md).
 *
 * One VU = one person with the app open; one iteration = one session. Think times between screens, the session mix
 * and the action mix come from analytics (session length, screens per session, time between events, share of each
 * action). The request sequence per screen comes from the frontend code or a browser's network log, not from memory.
 * Browsers' CORS preflights (OPTIONS) are left out: they are answered by the CORS middleware before the app and
 * cost little server CPU; price them separately if you care (endpointprobe with EP='OPTIONS /path').
 *
 * Requests are tagged kind:api (judged on p95 / p99 / errors) or kind:stream (long streamed answers: judged on full
 * duration and on completing; see stream() in lib.js). Give every URL with an id a `name` ("GET /items/:id").
 */
import http from 'k6/http';
import exec from 'k6/execution';
import { SharedArray } from 'k6/data';
import { Counter, Trend } from 'k6/metrics';
import { env, envNum, think, pickWeighted, api, ok, stream } from './lib.js';

const BASE = env('BASE_URL', '');
const sessionSec = new Trend('session_seconds');
const sessions = new Counter('sessions');

// EDIT: every `name` you use below, so the summary reports each one separately.
export const ENDPOINTS = [
  'POST /session/start', 'GET /me', 'GET /feed', 'GET /items/:id', 'POST /items', 'PATCH /me', 'POST /answers/stream',
];

// Test users: tokens your app accepts (signed initData, JWTs, session cookies...). Returning users are created by
// warmup.js before the run; new users (optional file) are used once each, for first sessions. Several load
// generators must not share users: LG_INDEX / LG_COUNT pick disjoint slices.
const users = new SharedArray('users', () => JSON.parse(open('./data/users.json')));
const newUsers = new SharedArray('new', () => { try { return JSON.parse(open('./data/new_users.json')); } catch (_) { return []; } });
const LG = envNum('LG_INDEX', 0), LGS = envNum('LG_COUNT', 1);

// EDIT: the app's first paint. Whatever the frontend fires on open, in the same waves: awaited calls one by one,
// parallel ones in http.batch (bursts like this are what grow the latency tail, so keep them as bursts).
function openApp(u) {
  ok(http.post(`${BASE}/session/start`, JSON.stringify({ tz: 'UTC' }), api(u, 'POST /session/start')), 'start');
  const res = http.batch([
    ['GET', `${BASE}/me`, null, api(u, 'GET /me')],
    ['GET', `${BASE}/feed?limit=20`, null, api(u, 'GET /feed')],
  ]);
  res.forEach((r, i) => ok(r, `open#${i}`));
  try { return res[1].status === 200 ? res[1].json() : []; } catch (_) { return []; }
}

// EDIT: the actions, weighted by how often real sessions do them.
const ACTIONS = [
  { weight: 60, run: (u, feed) => { if (feed.length) ok(http.get(`${BASE}/items/${feed[0].id}`, api(u, 'GET /items/:id')), 'item'); think(10, 40); } },
  { weight: 25, run: (u) => { ok(http.post(`${BASE}/items`, JSON.stringify({ text: 'load test' }), api(u, 'POST /items')), 'create'); think(3, 10); } },
  { weight: 15, run: (u) => answer(u) },
];

// A streamed answer (e.g. an LLM through a stub): k6 waits for the whole body, then the user reads it.
function answer(u) {
  stream('POST', `${BASE}/answers/stream`, JSON.stringify({ q: 'load test question' }), u, 'POST /answers/stream');
  think(30, 90); // reading the answer
}

function returningSession() {
  const u = users[((__VU - 1) * LGS + LG) % users.length];
  const feed = openApp(u);
  think(2, 14);                                   // EDIT: time to the first action (analytics: median gap between events)
  pickWeighted(ACTIONS).run(u, feed);
  if (Math.random() < 0.4) pickWeighted(ACTIONS).run(u, feed);  // EDIT: share of sessions with a second action
}

function firstSession() {
  const u = newUsers[(exec.scenario.iterationInTest * LGS + LG) % newUsers.length];
  openApp(u);                                     // creates the user
  think(4, 14);
  ok(http.patch(`${BASE}/me`, JSON.stringify({ onboarded: true }), api(u, 'PATCH /me')), 'onboarded');
  answer(u);
}

/** warmup.js calls this once per returning user, so the run measures them against existing rows. */
export function warmUser(u) { openApp(u); }

export default function () {
  if (exec.vu.iterationInScenario === 0) think(0, 5); // don't start in lockstep
  const t0 = Date.now();
  if (newUsers.length && Math.random() < envNum('NEW_SHARE', 0.3)) firstSession(); else returningSession();
  sessionSec.add((Date.now() - t0) / 1000);
  sessions.add(1);
  think(1, 3); // the next session starts
}
