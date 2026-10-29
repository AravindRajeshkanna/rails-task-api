// Load test for the Task API: a realistic read-heavy mix (85% browsing, 15% writing) at a fixed
// arrival rate. Open-model on purpose: users arrive whether or not the server keeps up, which is
// how real traffic behaves and the only way latency under overload shows up honestly.
//
//   k6 run -e BASE_URL=http://localhost:3100 -e RATE=20 -e DURATION=60s loadtest/k6/api.js
//
// Needs tmp/loadtest/tokens.json from `bin/rails loadtest:seed` (see loadtest/README.md).
import http from 'k6/http';
import { check, sleep } from 'k6';
import { SharedArray } from 'k6/data';
import exec from 'k6/execution';

const BASE = __ENV.BASE_URL || 'http://localhost:3000';
const RATE = parseInt(__ENV.RATE || '20', 10); // iterations (user visits) per second
const DURATION = __ENV.DURATION || '60s';

const seed = JSON.parse(open('../../tmp/loadtest/tokens.json'));
const tokens = new SharedArray('tokens', () => seed.tokens);

const ENDPOINTS = [
  'projects_index', 'tasks_index', 'tasks_whale', 'tasks_cursor', 'tasks_filtered', 'tasks_search', 'tasks_fulltext', 'search', 'task_show', 'analytics', 'activity',
  'task_create', 'task_update', 'comment_create',
];

// k6 only reports a sub-metric that some threshold mentions. `max>=0` always passes: it exists so
// every endpoint gets its own latency line in the summary (--summary-export) without gating on it.
const perEndpoint = Object.fromEntries(ENDPOINTS.map((name) => [`http_req_duration{name:${name}}`, ['max>=0']]));

export const options = {
  scenarios: {
    visits: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: Math.max(20, RATE * 2),
      maxVUs: Math.max(100, RATE * 6),
    },
  },
  thresholds: {
    ...perEndpoint,
    http_req_failed: ['rate<0.01'],
    checks: ['rate>0.99'],
    'http_req_duration{kind:read}': ['p(95)<400', 'p(99)<1000'],
    'http_req_duration{kind:write}': ['p(95)<600'],
    // The expensive endpoints get their own line, so a regression there is not averaged away.
    'http_req_duration{name:tasks_whale}': ['p(95)<500', 'max>=0'],
    'http_req_duration{name:search}': ['p(95)<600', 'max>=0'],
    'http_req_duration{name:analytics}': ['p(95)<800', 'max>=0'],
  },
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

function get(path, headers, name, kind = 'read') {
  return http.get(`${BASE}/api/v1${path}`, { headers, tags: { name, kind } });
}

function send(method, path, body, headers, name) {
  return http.request(method, `${BASE}/api/v1${path}`, JSON.stringify(body), {
    headers: Object.assign({ 'Content-Type': 'application/json' }, headers),
    tags: { name, kind: 'write' },
  });
}

const ok = (res, label) => check(res, { [`${label} 2xx`]: (r) => r.status >= 200 && r.status < 300 });
const pick = (list) => list[Math.floor(Math.random() * list.length)];
// The seed vocabulary is 26 words, so every term matches a large share of rows: the worst case for ranked
// full-text search (it must score every match). Real text has rare words and is much cheaper.
const SEARCHES = ['billing', 'billing+invoice', '%22deploy+review%22', 'audit+-backup', 'migrating'];

export default function () {
  const useWhale = Math.random() < 0.2; // one huge project is where slow queries hide
  const token = useWhale ? tokens[0] : pick(tokens);
  const headers = { Authorization: `Bearer ${token}` };

  const projects = get('/projects?limit=25', headers, 'projects_index');
  if (!ok(projects, 'projects')) return;
  const project = useWhale ? { id: seed.whale_project_id } : pick(projects.json('data'));
  if (!project) return;

  const listName = useWhale ? 'tasks_whale' : 'tasks_index';
  const tasks = get(`/projects/${project.id}/tasks?limit=25`, headers, listName);
  ok(tasks, 'tasks');
  if (tasks.status === 200 && Math.random() < 0.3) { // scrolling: the first page by cursor, then the next one
    const first = get(`/projects/${project.id}/tasks?cursor=&limit=25`, headers, 'tasks_cursor');
    const next = ok(first, 'cursor') ? first.json('meta.next_cursor') : null;
    if (next) ok(get(`/projects/${project.id}/tasks?cursor=${encodeURIComponent(next)}&limit=25`, headers, 'tasks_cursor'), 'cursor next');
  }
  sleep(Math.random() * 0.5);

  if (Math.random() < 0.85) { // browse
    ok(get(`/projects/${project.id}/tasks?status=todo,in_progress&sort=-priority,due_on&limit=25`, headers, 'tasks_filtered'), 'filtered');
    ok(get(`/projects/${project.id}/tasks?q=billing&limit=25`, headers, 'tasks_search'), 'search');
    ok(get(`/projects/${project.id}/tasks?search=${pick(SEARCHES)}&limit=25`, headers, 'tasks_fulltext'), 'full-text');
    ok(get(`/search?q=${pick(SEARCHES)}&limit=25`, headers, 'search'), 'cross-project search');
    const first = tasks.status === 200 ? tasks.json('data.0') : null;
    if (first) ok(get(`/tasks/${first.id}`, headers, 'task_show'), 'show');
    ok(get(`/projects/${project.id}/analytics`, headers, 'analytics'), 'analytics');
    ok(get('/activity?limit=25', headers, 'activity'), 'activity');
  } else { // write
    const created = send('POST', `/projects/${project.id}/tasks`, { title: `Load test ${exec.vu.idInTest}-${exec.scenario.iterationInTest}`, priority: 'medium' }, headers, 'task_create');
    if (ok(created, 'create')) {
      const id = created.json('data.id');
      ok(send('PATCH', `/tasks/${id}`, { status: 'in_progress' }, headers, 'task_update'), 'update');
      ok(send('POST', `/tasks/${id}/comments`, { body: 'Looking into it' }, headers, 'comment_create'), 'comment');
    }
  }
  sleep(Math.random() * 0.5);
}
