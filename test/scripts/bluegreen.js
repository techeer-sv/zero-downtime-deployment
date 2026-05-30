import http from 'k6/http';
import { check } from 'k6';
import { Counter, Rate } from 'k6/metrics';

if (!__ENV.TARGET_URL) {
  throw new Error('TARGET_URL is required. Example: TARGET_URL=http://192.168.0.10');
}

const targetUrl = __ENV.TARGET_URL.replace(/\/+$/, '');
const vus = Number(__ENV.K6_VUS || 10);
const duration = __ENV.K6_DURATION || '5m';
const rps = Number(__ENV.K6_RPS || 20);
const expectedVersion = __ENV.EXPECTED_VERSION || '';
const maxVus = Number(__ENV.K6_MAX_VUS || vus * 2);

export const blueResponses = new Counter('blue_responses');
export const greenResponses = new Counter('green_responses');
export const unknownResponses = new Counter('unknown_responses');
export const unexpectedVersionRate = new Rate('unexpected_version_rate');

export const options = {
  scenarios: {
    bluegreen_steady_load: {
      executor: 'constant-arrival-rate',
      rate: rps,
      timeUnit: '1s',
      duration,
      preAllocatedVUs: vus,
      maxVUs: maxVus,
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<500'],
    unexpected_version_rate: ['rate<0.01'],
  },
};

export default function () {
  const res = http.get(targetUrl + '/');
  const body = res.body || '';

  if (body.includes('version - v1.0.0')) {
    blueResponses.add(1);
  } else if (body.includes('version - v1.0.1')) {
    greenResponses.add(1);
  } else {
    unknownResponses.add(1);
  }

  const expectedVersionMatched =
    expectedVersion === '' || body.includes('version - ' + expectedVersion);

  unexpectedVersionRate.add(!expectedVersionMatched);

  check(res, {
    'status is 200': (r) => r.status === 200,
    'body has app version': () => body.includes('version - '),
    'expected version matched': () => expectedVersionMatched,
  });
}
