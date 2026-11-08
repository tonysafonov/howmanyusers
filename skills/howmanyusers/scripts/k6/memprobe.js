// memprobe.js: the journey's app-open (warmUser in journey.js) in a tight loop with no think time, to watch the app's
// memory under a burst. Run it through memprobe.sh, which samples docker stats and RestartCount around it.
//
//   k6 run -e BASE_URL=http://10.0.0.2:8000 -e VUS=4 -e DURATION=60s memprobe.js
//
// Env: VUS (default 2), DURATION (default 60s), N (how many of data/users.json to cycle through, default all).
// The run aborts (exit 99) when fewer than 99.9 % of responses are 2xx: an app that is being OOM-killed answers
// with errors, and an error is not a flat memory curve.
import { SharedArray } from 'k6/data';
import { warmUser } from './journey.js';
import { env, envNum, checksThreshold } from './lib.js';

const users = new SharedArray('users', () => JSON.parse(open('./data/users.json')));
const N = Math.min(envNum('N', users.length), users.length);

export const options = {
  scenarios: { mem: { executor: 'constant-vus', vus: envNum('VUS', 2), duration: env('DURATION', '60s') } },
  thresholds: checksThreshold,
};

export default function () {
  warmUser(users[Math.floor(Math.random() * N)]);
}
