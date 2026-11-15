// Load test for poll: votes at a constant rate, 100/s for 5 minutes by
// default, after a warm-up ramp that gives the HPA time to scale out.
// Fails if the steady phase reaches a p99 of 500ms or more, or if more than
// 1% of the requests fail. WARMUP=0 skips the ramp.
import http from 'k6/http';
import { check } from 'k6';

const POLL_URL = __ENV.POLL_URL || 'https://poll.bernstein.local';
const RATE = Number(__ENV.RATE || 100);
const WARMUP = __ENV.WARMUP || '1m';
const VOTES = ['a', 'b', 'c', 'd'];

const steady = {
  executor: 'constant-arrival-rate',
  rate: RATE,
  timeUnit: '1s',
  duration: __ENV.DURATION || '5m',
  preAllocatedVUs: 50,
  maxVUs: 300,
};

const scenarios = { steady };
if (WARMUP !== '0') {
  scenarios.warmup = {
    executor: 'ramping-arrival-rate',
    startRate: 1,
    timeUnit: '1s',
    stages: [{ target: RATE, duration: WARMUP }],
    preAllocatedVUs: 50,
    maxVUs: 300,
  };
  steady.startTime = WARMUP;
}

export const options = {
  scenarios,
  thresholds: {
    'http_req_duration{scenario:steady}': ['p(99)<500'],
    'http_req_failed{scenario:steady}': ['rate<0.01'],
    checks: ['rate>0.99'],
  },
};

export default function () {
  const vote = VOTES[Math.floor(Math.random() * VOTES.length)];
  const res = http.post(`${POLL_URL}/`, { vote });
  check(res, { 'vote accepted': (r) => r.status === 200 });
}
