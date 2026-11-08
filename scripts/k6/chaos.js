// chaos.js: authenticated requests in a loop while chaos.sh stops a dependency for a few seconds. Prints responses
// by status and the window in which clients saw errors. Good: 503 during the outage, recovery right after it.
// Bad: 401 (a DB/Redis/DNS error inside auth became "not authenticated": users get logged out) or a slow recovery.
//
//   k6 run -e BASE_URL=... -e EP='GET /users/me' -e VUS=4 -e DURATION=45s chaos.js
import http from 'k6/http';
import exec from 'k6/execution';
import { Counter, Trend } from 'k6/metrics';
import { SharedArray } from 'k6/data';
import { env, envNum, api } from './lib.js';

const users = new SharedArray('users', () => JSON.parse(open('./data/users.json')));
const STATUSES = [200, 201, 204, 401, 403, 429, 500, 502, 503, 504];
const by = Object.fromEntries(STATUSES.map((s) => [s, new Counter(`status_${s}`)]));
const neterr = new Counter('status_0_network');
const other = new Counter('status_other');
const errAt = new Trend('error_at_s');
const [METHOD, PATH] = env('EP', 'GET /users/me').split(' ');

export const options = {
  scenarios: { chaos: { executor: 'constant-vus', vus: envNum('VUS', 4), duration: env('DURATION', '45s') } },
  summaryTrendStats: ['min', 'max'],
};

export default function () {
  const u = users[Math.floor(Math.random() * users.length)];
  const r = http.request(METHOD, `${env('BASE_URL', '')}${PATH}`, env('BODY', null), api(u, `${METHOD} ${PATH}`, { timeout: '10s' }));
  if (r.status === 0) neterr.add(1); else (by[r.status] || other).add(1);
  if (r.status < 200 || r.status >= 300) errAt.add(exec.instance.currentTestRunDuration / 1000);
}

export function handleSummary(data) {
  const m = data.metrics;
  const lines = [];
  for (const [k, v] of Object.entries(m)) if (k.startsWith('status_') && v.values.count) lines.push(`  status ${k.slice(7).padEnd(10)} ${v.values.count}`);
  const e = m.error_at_s;
  lines.push(e && e.values.max !== undefined
    ? `  errors seen from t=${e.values.min.toFixed(1)} s to t=${e.values.max.toFixed(1)} s (after the dependency is back, this should end within seconds)`
    : '  no errors seen (did the outage happen? is the dependency on the request path?)');
  return { stdout: lines.join('\n') + '\n' };
}
