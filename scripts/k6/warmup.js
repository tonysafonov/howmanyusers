// warmup.js: one pass over every test user so they exist in the DB (and caches, pools and the JIT are warm) before
// anything is measured. Uses journey.js's warmUser(token). Gentle by default: a cold app is at its most fragile.
//   k6 run -e BASE_URL=... -e N=1500 -e VUS=4 warmup.js
import exec from 'k6/execution';
import { SharedArray } from 'k6/data';
import { warmUser } from './journey.js';
import { envNum } from './lib.js';

const users = new SharedArray('users', () => JSON.parse(open('./data/users.json')));
export const options = {
  scenarios: { warm: { executor: 'shared-iterations', vus: envNum('VUS', 4), iterations: Math.min(envNum('N', 1000), users.length), maxDuration: '30m' } },
};
export default function () {
  warmUser(users[exec.scenario.iterationInTest]);
}
