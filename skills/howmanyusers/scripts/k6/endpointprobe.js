// endpointprobe.js: ONE endpoint in a tight loop (no think time) as random test users, to price it with
// cpuprobe.sh or profile it with pyspy.sh. Run it at saturation: the app's CPU near 100 % of what it can use.
//
//   k6 run -e BASE_URL=http://10.0.0.2:8000 -e EP='GET /users/me' -e VUS=6 -e DURATION=60s endpointprobe.js
//
// Env: EP ("METHOD /path?query", default 'GET /health'), BODY (JSON for POST/PUT/PATCH), NO_AUTH=1 (send no auth;
// automatic for HEALTH, default /health), PIN_USER (index into data/users.json; mind per-user rate limits: one
// pinned user at saturation hits them within seconds and you price 429s), AUTH_HEADER / AUTH_PREFIX (see lib.js).
// The run aborts (exit 99) when fewer than 99.9 % of responses are 2xx: a fast error is not a cheap endpoint.
import http from 'k6/http';
import { SharedArray } from 'k6/data';
import { env, envNum, api, ok, checksThreshold } from './lib.js';

const BASE = env('BASE_URL', '');
const EP = env('EP', 'GET /health');
const [METHOD, PATH] = EP.split(' ');
const NO_AUTH = env('NO_AUTH', '') === '1' || PATH.split('?')[0] === env('HEALTH', '/health');
const BODY = env('BODY', null);
const users = NO_AUTH ? [] : new SharedArray('users', () => JSON.parse(open('./data/users.json')));

export const options = {
  scenarios: { probe: { executor: 'constant-vus', vus: envNum('VUS', 4), duration: env('DURATION', '60s') } },
  thresholds: checksThreshold,
};

export function setup() {
  if (!BASE) throw new Error('set BASE_URL');
  if (!NO_AUTH && !users.length) throw new Error('data/users.json is empty');
}

export default function () {
  let token = null;
  if (!NO_AUTH) {
    const pin = env('PIN_USER', '');
    token = pin === '' ? users[Math.floor(Math.random() * users.length)] : users[Number(pin)];
    if (token === undefined) throw new Error(`no user at PIN_USER=${pin}`);
  }
  ok(http.request(METHOD, `${BASE}${PATH}`, BODY, api(token, EP)), EP);
}
