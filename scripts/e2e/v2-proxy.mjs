/** V2(a): a reverse proxy forwards X-Pirc-Request.
 *
 * A minimal Node reverse proxy (scripts/e2e/lib.mjs `startAdapter`) behaves
 * like a typical deployment: it strips any client-supplied identity and
 * proxy-secret headers, adds the fixture identity and the proxy secret, sets
 * Host/Origin, and forwards every other header and the body unchanged. The
 * Gateway has PIRC_PROXY_SECRET set, as the deployment docs ask.
 *
 * NOT a real nginx, Caddy or Traefik: none is installed here, and installing
 * one needs the owner's approval. The static review of the shipped nginx
 * module and of the documented nginx/Traefik examples is v2-proxy-config.mjs.
 */
import {
  Results,
  FakeLlm,
  binaries,
  buildCurrent,
  startStack,
  startAdapter,
  gatewayClient,
  makeTempDir,
  removeDir,
  seedProject,
  stopAllProcesses,
  http,
  encode,
  PROXY_SECRET,
  coverage,
} from './lib.mjs';

const results = new Results('V2a');
const PNG = Buffer.from(
  '89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d49444154789c6360000000000200010005fe02fe0000000049454e44ae426082',
  'hex',
);

async function main() {
  console.log('V2a coverage:', JSON.stringify(coverage()));
  const bins = process.env.PIRC_E2E_SKIP_BUILD ? binaries() : buildCurrent();
  const llm = await new FakeLlm().start();
  const root = makeTempDir('v2');
  let stack, proxy, lossy;
  try {
    stack = await startStack({
      root,
      bins,
      llm,
      nodes: [{ id: 'chat', kind: 'chat' }],
      proxySecret: PROXY_SECRET,
    });
    const log = [];
    proxy = await startAdapter({ gateway: stack.base, proxySecret: PROXY_SECRET, log });
    // A hop that drops the header (a misconfigured proxy), to show the symptom.
    lossy = await startAdapter({
      gateway: stack.base,
      proxySecret: PROXY_SECRET,
      dropHeaders: ['x-pirc-request'],
    });
    const direct = gatewayClient(stack.base);
    const through = (adapter) => {
      // The client as a browser or the App would be: no identity, no secret.
      const call = (method, route, { json, raw, contentType, marker, headers = {} } = {}) => {
        // A browser sends its own Origin on writes; the proxy passes it on.
        const h = { origin: adapter.url, ...headers };
        let body;
        if (json !== undefined) {
          body = Buffer.from(JSON.stringify(json));
          h['content-type'] = 'application/json';
        } else if (raw !== undefined) {
          body = Buffer.from(raw);
          if (contentType) h['content-type'] = contentType;
        }
        if (body) h['content-length'] = String(body.length);
        if (marker !== undefined) h['x-pirc-request'] = marker;
        h.accept = 'application/json';
        return http(method, adapter.url + route, { headers: h, body });
      };
      return { call };
    };
    const client = through(proxy);
    const lossyClient = through(lossy);

    const s = await client.call('POST', '/api/sessions', { json: { workspaceId: 'chat:chats' } });
    results.check(
      'JSON write through the proxy (no marker): create session',
      s.status === 201,
      `status ${s.status}`,
    );
    const id = s.json?.session?.id;
    const project = await (async () => {
      // seedProject talks to the Gateway directly; the project route is then exercised through the proxy.
      return seedProject(stack);
    })();

    const row = async (label, expectedStatus, promise, expectedCode) => {
      const r = await promise;
      results.check(
        label,
        r.status === expectedStatus && (!expectedCode || r.json?.error?.code === expectedCode),
        `status ${r.status}${r.json?.error?.code ? ' ' + r.json.error.code : ''}`,
      );
      return r;
    };

    // JSON bodies
    await row(
      'JSON PATCH (no marker) -> 200',
      200,
      client.call('PATCH', `/api/sessions/${id}`, { json: { name: 'renamed' } }),
    );
    await row(
      'JSON PATCH (with marker) -> 200',
      200,
      client.call('PATCH', `/api/sessions/${id}`, { json: { name: 'renamed 2' }, marker: '1' }),
    );
    // Body-less writes
    await row(
      'body-less POST read, with marker -> 2xx',
      200,
      client.call('POST', `/api/sessions/${id}/read`, { marker: '1' }),
    );
    await row(
      'body-less POST read, without marker -> 415',
      415,
      client.call('POST', `/api/sessions/${id}/read`),
      'request_shape_required',
    );
    await row(
      'body-less POST read, marker "0" -> 415',
      415,
      client.call('POST', `/api/sessions/${id}/read`, { marker: '0' }),
      'request_shape_required',
    );
    await row(
      'body-less POST read, marker in other case (X-PIRC-REQUEST) -> 2xx',
      200,
      client.call('POST', `/api/sessions/${id}/read`, { headers: { 'X-PIRC-REQUEST': '1' } }),
    );
    await row(
      'body-less POST read, marker sent twice -> 415',
      415,
      client.call('POST', `/api/sessions/${id}/read`, {
        headers: { 'x-pirc-request': ['1', '1'] },
      }),
      'request_shape_required',
    );
    // Raw uploads
    const up = `/api/sessions/${id}/uploads?filename=notes.txt`;
    await row(
      'raw text upload with marker -> 201',
      201,
      client.call('POST', up, { raw: 'hello upload', contentType: 'text/plain', marker: '1' }),
    );
    await row(
      'raw text upload without marker -> 415',
      415,
      client.call('POST', up, { raw: 'hello upload', contentType: 'text/plain' }),
      'request_shape_required',
    );
    const img = await row(
      'raw image upload with marker -> 201',
      201,
      client.call('POST', `/api/sessions/${id}/uploads?filename=p.png`, {
        raw: PNG,
        contentType: 'image/png',
        marker: '1',
      }),
    );
    await row(
      'raw image upload without marker -> 415',
      415,
      client.call('POST', `/api/sessions/${id}/uploads?filename=p.png`, {
        raw: PNG,
        contentType: 'image/png',
      }),
      'request_shape_required',
    );
    void img;
    await row(
      'project file write with marker -> 201',
      201,
      client.call('POST', project.route, {
        raw: 'v2 bytes',
        contentType: 'text/plain',
        marker: '1',
      }),
    );
    await row(
      'project file write without marker -> 415',
      415,
      client.call('POST', project.route, { raw: 'nope', contentType: 'text/plain' }),
      'request_shape_required',
    );
    await row(
      'form-style write (urlencoded) without marker -> 415',
      415,
      client.call('POST', project.route, {
        raw: 'a=1',
        contentType: 'application/x-www-form-urlencoded',
      }),
      'request_shape_required',
    );
    await row(
      'DELETE with marker -> 204',
      204,
      client.call(
        'DELETE',
        `/api/workspaces/${encode(project.id)}/files?name=${encode(project.name)}`,
        { marker: '1' },
      ),
    );
    // Identity and proxy hygiene
    await row(
      'a client-supplied identity header is replaced by the proxy (spoofed user does not break the request)',
      200,
      client.call('POST', `/api/sessions/${id}/read`, {
        marker: '1',
        headers: { 'x-pirc-user': 'intruder@example.com' },
      }),
    );
    const noSecret = await direct.call('POST', `/api/sessions/${id}/read`, { marker: true });
    results.check(
      'control: bypassing the proxy (no secret) is refused by the Gateway',
      noSecret.status === 401 || noSecret.status === 403,
      `status ${noSecret.status}`,
    );
    // A hop that drops X-Pirc-Request
    await row(
      'lossy hop (drops the header): JSON write -> 200',
      200,
      lossyClient.call('PATCH', `/api/sessions/${id}`, {
        json: { name: 'via lossy' },
        marker: '1',
      }),
    );
    await row(
      'lossy hop: body-less write -> 415 (the symptom of a proxy that drops the header)',
      415,
      lossyClient.call('POST', `/api/sessions/${id}/read`, { marker: '1' }),
      'request_shape_required',
    );
    await row(
      'lossy hop: raw upload -> 415',
      415,
      lossyClient.call('POST', up, { raw: 'x', contentType: 'text/plain', marker: '1' }),
      'request_shape_required',
    );
    // The proxy really forwarded the header (the Gateway-visible request is what the log saw).
    const marked = log.filter((e) => e.method !== 'GET' && e.marker === '1').length;
    results.check(
      'the proxy log shows the marker on the forwarded writes',
      marked >= 6,
      `${marked} marked writes forwarded`,
    );
  } finally {
    await lossy?.stop().catch(() => {});
    await proxy?.stop().catch(() => {});
    await stack?.stop().catch(() => {});
    await llm.stop().catch(() => {});
    removeDir(root);
    await stopAllProcesses();
  }
}
try {
  await main();
} catch (error) {
  results.add('V2a aborted', 'fail', String(error?.stack ?? error));
}
console.log(
  `V2a: ${results.rows.length - results.failed.length} passed, ${results.failed.length} failed`,
);
process.exit(results.failed.length ? 1 : 0);
