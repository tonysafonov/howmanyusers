// streamsonly.js: the streamed endpoint back to back (an optional preparatory GET, then the stream, nothing else),
// to price ONE stream's CPU with cpuprobe.sh (it prints ms per iteration) or to test how many streams the app can
// hold open at once. Think times are zero: VUS = streams in flight.
//
//   scripts/cpuprobe.sh streamsonly.js 40 streams -e STREAM_EP='POST /answers/stream' -e STREAM_BODY='{"q":"hi"}'
//
// Env: STREAM_EP ("METHOD /path", required), STREAM_BODY (JSON body for POST/PUT), PRE_EP (optional "GET /path" made
// first, e.g. the call that fetches what the stream needs), DONE_MARKER (text that ends a complete stream, default
// "done"), STREAM_TIMEOUT (default 120s), VUS (default 30), DURATION (default 90s), AUTH_HEADER / AUTH_PREFIX.
// Judged like holds: kind:stream, done check on every stream; the run aborts when under 99.9 % of checks pass.
import http from 'k6/http';
import { SharedArray } from 'k6/data';
import { env, envNum, api, ok, stream, checksThreshold } from './lib.js';

const BASE = env('BASE_URL', '');
const [METHOD, PATH] = env('STREAM_EP', '').split(' ');
const BODY = env('STREAM_BODY', null);
const PRE = env('PRE_EP', '');
const users = new SharedArray('users', () => JSON.parse(open('./data/users.json')));

export const options = {
  scenarios: { streams: { executor: 'constant-vus', vus: envNum('VUS', 30), duration: env('DURATION', '90s') } },
  thresholds: checksThreshold,
};

export function setup() {
  if (!BASE) throw new Error('set BASE_URL');
  if (!PATH) throw new Error("set STREAM_EP='METHOD /path'");
  if (!users.length) throw new Error('data/users.json is empty');
}

export default function () {
  const u = users[(__VU - 1) % users.length];
  if (PRE) {
    const [pm, pp] = PRE.split(' ');
    ok(http.request(pm, `${BASE}${pp}`, null, api(u, PRE)), PRE);
  }
  stream(METHOD, `${BASE}${PATH}`, BODY, u, env('STREAM_EP', ''));
}
