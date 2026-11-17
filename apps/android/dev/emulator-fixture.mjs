// Local servers for integration_test/content_boundary_emulator_test.dart.
//
//   node apps/android/dev/emulator-fixture.mjs
//
// Two stand-in Gateways (A on 18701, B on 18702) and an external receiver
// (18703), all on 0.0.0.0 so an emulator reaches them as 10.0.2.2. Every server
// records what actually arrives (method, path, the headers that matter, the
// body) and serves it on GET /__log; GET /__reset clears it. The Gateways keep
// the one piece of state the test needs, a counter that moves only for a
// request that carries the device token AND the request-shape header, which is
// what the real Gateway demands of a state-changing request.
//
// This is a test double for the wire contract, not the real Gateway.
import { createServer } from 'node:http';

const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
);
const seen = { A: [], B: [], R: [] };
const state = { A: { applied: 0 }, B: { applied: 0 } };
let started = Date.now();
let sequence = 0;

const keep = (request, body) => ({
  n: ++sequence,
  at: Date.now() - started,
  method: request.method,
  path: request.url,
  authorization: request.headers['authorization'] ?? null,
  shape: request.headers['x-pirc-request'] ?? null,
  cookie: request.headers['cookie'] ?? null,
  referer: request.headers['referer'] ?? null,
  origin: request.headers['origin'] ?? null,
  contentType: request.headers['content-type'] ?? null,
  body: body.length > 4096 ? `${body.length} bytes` : body.toString('utf8'),
});

const json = (response, status, value) => {
  response.writeHead(status, { 'content-type': 'application/json' });
  response.end(JSON.stringify(value));
};

function listen(name, port, handler) {
  createServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const body = Buffer.concat(chunks);
    const url = new URL(request.url, 'http://x');
    if (url.pathname === '/__log')
      return json(response, 200, { log: seen[name], state: state[name] ?? null });
    if (url.pathname === '/__reset') {
      for (const key of Object.keys(seen)) seen[key] = [];
      for (const key of Object.keys(state)) state[key] = { applied: 0 };
      started = Date.now();
      return json(response, 200, { ok: true });
    }
    seen[name].push(keep(request, body));
    return handler(request, response, url, body);
  }).listen(port, '0.0.0.0', () => console.log(`${name} listening on ${port}`));
}

function gateway(name, port, token) {
  listen(name, port, (request, response, url) => {
    const authorized = request.headers['authorization'] === `Bearer ${token}`;
    if (url.pathname.startsWith('/api/') && !authorized) {
      return json(response, 401, {
        error: { code: 'unauthorized', message: 'Device token is not valid' },
      });
    }
    if (url.pathname === '/api/sessions' && request.method === 'GET') {
      return json(response, 200, {
        sessions: [{ id: 's1', workspaceId: 'w', name: `Fixture ${name}` }],
      });
    }
    if (
      request.method !== 'GET' &&
      request.method !== 'HEAD' &&
      request.headers['x-pirc-request'] !== '1' &&
      !String(request.headers['content-type'] ?? '').startsWith('application/json')
    ) {
      return json(response, 415, {
        error: { code: 'request_shape_required', message: 'Wrong request shape' },
      });
    }
    if (url.pathname === '/api/sessions/s1/uploads' && request.method === 'POST') {
      return json(response, 200, {
        upload: { id: `u-${name}`, mimeType: 'image/png', byteSize: 1, kind: 'image' },
      });
    }
    if (url.pathname.startsWith('/api/memory/') && request.method === 'POST') {
      state[name].applied++;
      return json(response, 200, { status: 'applied' });
    }
    // Pages the Gateway serves to a browser-like request (a form that targets it).
    if (request.method === 'GET' || request.method === 'POST') {
      response.writeHead(200, { 'content-type': 'text/html' });
      return response.end('<!doctype html><title>pirc</title><p>gateway page</p>');
    }
    return json(response, 404, { error: { code: 'not_found', message: 'No route' } });
  });
}

gateway('A', 18701, `pirc_dev_${'a'.repeat(43)}`);
gateway('B', 18702, `pirc_dev_${'b'.repeat(43)}`);
listen('R', 18703, (request, response, url) => {
  if (url.pathname.endsWith('.png')) {
    response.writeHead(200, { 'content-type': 'image/png' });
    return response.end(PNG);
  }
  response.writeHead(200, { 'content-type': 'text/html' });
  response.end('<!doctype html><title>receiver</title><p>received</p>');
});
