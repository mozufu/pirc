/** Shared helpers of the cross-layer checks (scripts/e2e/README.md).
 *
 * Everything here starts real executables (pirc-gateway, pirc-node) with fresh
 * temporary state, behind a local trusted-proxy adapter. Nothing touches the
 * everyday browser, the network beyond 127.0.0.1, or any state outside the
 * temporary directory of a run.
 */
import { spawn, execFileSync } from 'node:child_process';
import { createServer, request as httpRequest } from 'node:http';
import net from 'node:net';
import {
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
  openSync,
  closeSync,
  readFileSync,
  existsSync,
  realpathSync,
} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
export const USER = 'test@example.com';
export const HOST = 'test.example';
export const ORIGIN = 'https://test.example';
export const NODE_TOKEN = 'e2e-node-token-0123456789abcdef0123';
export const PROXY_SECRET = 'e2e-proxy-secret-0123456789abcdef';
export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export const git = (...args) =>
  execFileSync('git', args, { cwd: repoRoot, encoding: 'utf8' }).trim();
export const headSha = () => git('rev-parse', '--short=12', 'HEAD');

/** A pass/fail recorder; `report()` prints a table and returns false on failure. */
export class Results {
  constructor(name) {
    this.name = name;
    this.rows = [];
  }
  /** status: 'pass' | 'fail' | 'not-run' */
  add(id, status, evidence = '') {
    this.rows.push({ id, status, evidence });
    const mark = { pass: 'PASS', fail: 'FAIL', 'not-run': 'SKIP' }[status];
    console.log(`  [${mark}] ${id}${evidence ? ' -- ' + evidence : ''}`);
  }
  check(id, condition, evidence = '') {
    this.add(id, condition ? 'pass' : 'fail', evidence);
    return !!condition;
  }
  get failed() {
    return this.rows.filter((row) => row.status === 'fail');
  }
}

export function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
    server.on('error', reject);
  });
}

/** A fresh run directory. It must stay SHORT: the nodes bind a Unix socket
 * below it, and macOS limits such a path to about 100 characters, so the
 * default base is /tmp rather than a deep scratch directory. */
export function makeTempDir(label) {
  const base = process.env.PIRC_E2E_TMP || (process.platform === 'win32' ? os.tmpdir() : '/tmp');
  mkdirSync(base, { recursive: true });
  return mkdtempSync(path.join(base, `pe-${label}-`));
}
export function removeDir(dir) {
  if (dir && existsSync(dir)) rmSync(dir, { recursive: true, force: true });
}

/** The directories of the compiled executables: `{gateway, node}` for the
 * current tree (target/debug) or an alternative CARGO_TARGET_DIR. */
export function binaries(targetDir = path.join(repoRoot, 'target')) {
  const dir = path.join(targetDir, 'debug');
  return { gateway: path.join(dir, 'pirc-gateway'), node: path.join(dir, 'pirc-node'), dir };
}
export function buildCurrent() {
  execFileSync('cargo', ['build', '--locked', '-p', 'pirc-gateway', '-p', 'pirc-node'], {
    cwd: repoRoot,
    stdio: 'inherit',
  });
  return binaries();
}

// ---------------------------------------------------------------------------
// Child processes

const children = new Set();
export function spawnLogged(name, program, args, { cwd, env, logDir }) {
  const log = path.join(logDir, `${name}.log`);
  const fd = openSync(log, 'w');
  const child = spawn(program, args, {
    cwd,
    env,
    stdio: ['ignore', fd, fd],
  });
  closeSync(fd);
  const handle = { name, child, log, exited: false };
  child.on('exit', () => {
    handle.exited = true;
    children.delete(handle);
  });
  children.add(handle);
  return handle;
}
export async function stopProcess(handle) {
  if (!handle || handle.exited) return;
  handle.child.kill('SIGTERM');
  for (let i = 0; i < 100 && !handle.exited; i++) await sleep(30);
  if (!handle.exited) {
    handle.child.kill('SIGKILL');
    for (let i = 0; i < 100 && !handle.exited; i++) await sleep(30);
  }
}
export async function stopAllProcesses() {
  await Promise.all([...children].map(stopProcess));
}
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.once(signal, () => {
    void stopAllProcesses().finally(() => process.exit(130));
  });
}

// ---------------------------------------------------------------------------
// HTTP

/** One request with exactly the given headers (Node's http, so `host` and
 * `origin` are sent as given). Returns {status, headers, body (Buffer), text, json}. */
export function http(method, url, { headers = {}, body, timeout = 30000 } = {}) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const outgoing = httpRequest(
      {
        method,
        hostname: target.hostname,
        port: target.port,
        path: target.pathname + target.search,
        headers,
        timeout,
      },
      (response) => {
        const parts = [];
        response.on('data', (part) => parts.push(part));
        response.on('end', () => {
          const buffer = Buffer.concat(parts);
          const text = buffer.toString('utf8');
          let json;
          try {
            json = JSON.parse(text);
          } catch {
            json = undefined;
          }
          resolve({
            status: response.statusCode,
            headers: response.headers,
            body: buffer,
            text,
            json,
          });
        });
      },
    );
    outgoing.on('timeout', () => outgoing.destroy(new Error(`timeout: ${method} ${url}`)));
    outgoing.on('error', reject);
    outgoing.end(body);
  });
}

/** A client of the Gateway as the trusted proxy would present it. */
export function gatewayClient(base, extra = {}) {
  const identity = {
    host: HOST,
    origin: ORIGIN,
    'x-pirc-user': USER,
    ...extra,
  };
  const call = (method, route, { json, raw, contentType, headers = {}, marker = true } = {}) => {
    const h = { ...identity, ...headers };
    let body;
    if (json !== undefined) {
      body = Buffer.from(JSON.stringify(json));
      h['content-type'] = 'application/json';
    } else if (raw !== undefined) {
      body = Buffer.from(raw);
      if (contentType) h['content-type'] = contentType;
    }
    if (body) h['content-length'] = String(body.length);
    if (marker && method !== 'GET' && method !== 'HEAD' && method !== 'OPTIONS')
      h['x-pirc-request'] = '1';
    return http(method, base + route, { headers: h, body });
  };
  return { call, base };
}

// ---------------------------------------------------------------------------
// A scripted OpenAI-compatible model server (the only provider the Gateway knows)

export class FakeLlm {
  constructor() {
    this.queue = [];
    this.requests = [];
  }
  async start() {
    this.server = createServer(async (req, res) => {
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      if (req.method === 'GET' && req.url.startsWith('/v1/models')) {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ object: 'list', data: [] }));
        return;
      }
      if (req.method === 'POST' && req.url.startsWith('/v1/chat/completions')) {
        try {
          this.requests.push(JSON.parse(Buffer.concat(chunks).toString('utf8')));
        } catch {
          this.requests.push(null);
        }
        const reply = this.queue.shift() ?? { text: 'default reply' };
        const event = (delta, finish = null) =>
          `data: ${JSON.stringify({ choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`;
        let body = '';
        if (reply.tool) {
          const args = JSON.stringify(reply.tool.args);
          body += event({
            tool_calls: [
              {
                index: 0,
                id: reply.tool.id,
                type: 'function',
                function: { name: reply.tool.name, arguments: '' },
              },
            ],
          });
          body += event({ tool_calls: [{ index: 0, function: { arguments: args } }] });
          body += event({}, 'tool_calls');
        } else {
          body += event({ content: reply.text });
          body += event({}, 'stop');
        }
        body += `data: ${JSON.stringify({ choices: [], usage: { prompt_tokens: 100, completion_tokens: 10, total_tokens: 110 } })}\n\n`;
        body += 'data: [DONE]\n\n';
        res.writeHead(200, { 'content-type': 'text/event-stream' });
        res.end(body);
        return;
      }
      res.writeHead(404);
      res.end();
    });
    await new Promise((resolve) => this.server.listen(0, '127.0.0.1', resolve));
    this.url = `http://127.0.0.1:${this.server.address().port}`;
    return this;
  }
  get baseUrl() {
    return `${this.url}/v1`;
  }
  push(...replies) {
    this.queue.push(...replies);
  }
  async stop() {
    await new Promise((resolve) => this.server.close(resolve));
  }
}

// ---------------------------------------------------------------------------
// Gateway + nodes

const FAKE_SRT = `#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    --settings|--control-fd) shift 2 ;;
    *) shift ;;
  esac
done
if [ -e /dev/fd/3 ]; then
  cat <&3 >> "$(dirname "$0")/fake-srt-control.log" &
fi
exec "$@"
`;

/** Start a Gateway and its nodes with fresh state under `root`.
 *
 * `nodes`: [{ id, kind: 'directory' | 'chat' }]. A directory node serves one
 * workspace `<id>:<id>` backed by `<root>/workspace-<id>`. `bins` selects the
 * executables (current tree or the compat build). */
export async function startStack({
  root,
  bins,
  llm,
  nodes = [{ id: 'test', kind: 'directory' }],
  gatewayEnv = {},
  proxySecret,
}) {
  const logDir = path.join(root, 'logs');
  mkdirSync(logDir, { recursive: true });
  const port = await freePort();
  const sub = (name) => {
    const dir = path.join(root, name);
    mkdirSync(dir, { recursive: true });
    return dir;
  };
  const modelsFile = path.join(root, 'gateway-models.json');
  writeFileSync(
    modelsFile,
    JSON.stringify({
      providers: {
        fake: {
          api: 'openai-completions',
          baseUrl: llm.baseUrl,
          apiKey: 'test-key',
          models: [{ id: 'fake-model', reasoning: true, contextWindow: 100000, maxTokens: 1000 }],
        },
      },
      defaultModel: { provider: 'fake', id: 'fake-model', thinking: 'low' },
    }),
  );
  const tokenOf = (id) => `${NODE_TOKEN}-${id}`;
  const tokens = Object.fromEntries(nodes.map((n) => [n.id, tokenOf(n.id)]));
  const baseEnv = { PATH: process.env.PATH ?? '' };
  const gatewayHome = sub('gateway-home');
  const gateway = spawnLogged('gateway', bins.gateway, [], {
    cwd: root,
    logDir,
    env: {
      ...baseEnv,
      HOME: gatewayHome,
      PIRC_HOST: '127.0.0.1',
      PIRC_PORT: String(port),
      PIRC_STATE_DIR: sub('gateway-state'),
      PIRC_TRUSTED_PROXIES: '127.0.0.1,::1',
      PIRC_IDENTITY_HEADER: 'x-pirc-user',
      PIRC_ALLOWED_USERS: USER,
      PIRC_ALLOWED_ORIGINS: ORIGIN,
      PIRC_ALLOWED_HOSTS: HOST,
      PIRC_NODE_TOKENS: JSON.stringify(tokens),
      PIRC_MODELS_FILE: modelsFile,
      PIRC_CONFIG_DIR: sub('gateway-config'),
      PIRC_TIMEZONE: 'UTC',
      ...(proxySecret
        ? { PIRC_PROXY_SECRET: proxySecret }
        : { PIRC_PROXY_SECRET_REQUIRED: 'false' }),
      ...gatewayEnv,
    },
  });
  const stack = {
    root,
    port,
    base: `http://127.0.0.1:${port}`,
    gateway,
    nodeProcesses: [],
    workspaceDirs: {},
    stateDir: (id) => path.join(root, `ns-${id}`),
    llm,
    async stop() {
      for (const node of [...this.nodeProcesses].reverse()) await stopProcess(node);
      await stopProcess(this.gateway);
    },
    logs() {
      return [gateway, ...this.nodeProcesses].map((p) => `${p.name}: ${p.log}`).join('\n');
    },
  };
  const srt = path.join(root, 'fake-srt.sh');
  writeFileSync(srt, FAKE_SRT, { mode: 0o755 });
  for (const node of nodes) {
    const config = sub(`node-config-${node.id}`);
    writeFileSync(
      path.join(config, 'config.json'),
      JSON.stringify({
        features: { sessionTitle: { enabled: false }, autoMode: { useModel: false } },
      }),
    );
    const env = {
      ...baseEnv,
      HOME: sub(`node-home-${node.id}`),
      PIRC_NODE_ID: node.id,
      PIRC_NODE_TOKEN: tokenOf(node.id),
      PIRC_DAEMON_URL: `ws://127.0.0.1:${port}`,
      PIRC_ALLOWED_USERS: USER,
      PIRC_STATE_DIR: sub(`ns-${node.id}`),
      PIRC_CONFIG_DIR: config,
      PIRC_SANDBOX_SRT: srt,
      PIRC_BROWSER: 'false',
      PIRC_SHUTDOWN_GRACE_MS: '200',
      ...(node.env ?? {}),
    };
    if (node.kind === 'directory') {
      const workspace = sub(`workspace-${node.id}`);
      writeFileSync(path.join(workspace, 'README.md'), 'e2e\n');
      stack.workspaceDirs[node.id] = workspace;
      env.PIRC_WORKSPACES = JSON.stringify([
        { id: node.id, path: workspace, displayName: 'Test', defaults: {} },
      ]);
    }
    stack.nodeProcesses.push(
      spawnLogged(`node-${node.id}`, bins.node, node.kind === 'chat' ? ['chat'] : [], {
        cwd: root,
        logDir,
        env,
      }),
    );
  }
  // Ready: the Gateway answers and lists every node.
  const client = gatewayClient(
    stack.base,
    proxySecret ? { 'x-pirc-proxy-secret': proxySecret } : {},
  );
  const deadline = Date.now() + 40000;
  for (;;) {
    if (gateway.exited)
      throw new Error('the gateway exited during startup:\n' + readFileSync(gateway.log, 'utf8'));
    try {
      const health = await client.call('GET', '/api/health');
      if (health.status === 200 && (health.json?.nodes ?? 0) >= nodes.length) break;
    } catch {
      /* not listening yet */
    }
    if (Date.now() > deadline) {
      await stack.stop();
      throw new Error('the stack did not become ready\n' + stack.logs());
    }
    await sleep(100);
  }
  stack.client = client;
  return stack;
}

// ---------------------------------------------------------------------------
// The local trusted-proxy adapter

/** A reverse proxy in front of the Gateway.
 *
 * It behaves like a typical deployment: it strips client-supplied identity and
 * proxy-secret headers, sets the fixture identity (user, Host, Origin) and the
 * secret, and forwards everything else (including X-Pirc-Request) unchanged,
 * WebSocket upgrades included. Requests outside `/api/` and `/node/` go to
 * `fallback` (the web app) when given. Options:
 *  - `dropHeaders`: extra request headers to drop (to model a hostile hop);
 *  - `log`: array receiving { method, path, status, shape }.
 */
export async function startAdapter({
  gateway,
  fallback,
  identity = { user: USER, host: HOST, origin: ORIGIN },
  proxySecret,
  dropHeaders = [],
  log = [],
  rewriteHostOrigin = true,
}) {
  const target = new URL(gateway);
  const strip = new Set([
    'x-pirc-user',
    'x-pirc-proxy-secret',
    'x-pirc-management-proxy',
    ...dropHeaders,
  ]);
  const headersFor = (original) => {
    const out = {};
    for (const [name, value] of Object.entries(original)) {
      if (strip.has(name.toLowerCase())) continue;
      if (['connection', 'keep-alive', 'transfer-encoding', 'upgrade'].includes(name.toLowerCase()))
        continue;
      out[name] = value;
    }
    out['x-pirc-user'] = identity.user;
    if (rewriteHostOrigin) {
      out.host = identity.host;
      if (original.origin) out.origin = identity.origin;
    }
    if (proxySecret) out['x-pirc-proxy-secret'] = proxySecret;
    return out;
  };
  const server = createServer((req, res) => {
    if (!/^\/(api|node)\//.test(req.url) && fallback) return fallback(req, res);
    const headers = headersFor(req.headers);
    const outgoing = httpRequest(
      { hostname: target.hostname, port: target.port, method: req.method, path: req.url, headers },
      (incoming) => {
        log.push({
          method: req.method,
          path: req.url,
          status: incoming.statusCode,
          marker: req.headers['x-pirc-request'],
          contentType: req.headers['content-type'],
        });
        res.writeHead(incoming.statusCode, incoming.headers);
        incoming.pipe(res);
      },
    );
    outgoing.on('error', () => {
      res.writeHead(502);
      res.end();
    });
    req.pipe(outgoing);
  });
  server.on('upgrade', (req, socket, head) => {
    if (!/^\/(api|node)\//.test(req.url)) return socket.destroy();
    const upstream = net.connect(Number(target.port), target.hostname, () => {
      const headers = headersFor(req.headers);
      headers.connection = 'Upgrade';
      headers.upgrade = req.headers.upgrade;
      let text = `${req.method} ${req.url} HTTP/1.1\r\n`;
      for (const [name, value] of Object.entries(headers)) text += `${name}: ${value}\r\n`;
      upstream.write(text + '\r\n');
      if (head?.length) upstream.write(head);
      socket.pipe(upstream);
      upstream.pipe(socket);
    });
    upstream.on('error', () => socket.destroy());
    socket.on('error', () => upstream.destroy());
    socket.on('close', () => upstream.destroy());
    upstream.on('close', () => socket.destroy());
  });
  const sockets = new Set();
  server.on('connection', (socket) => {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  return {
    port,
    url: `http://127.0.0.1:${port}`,
    log,
    async stop() {
      for (const socket of sockets) socket.destroy();
      await new Promise((resolve) => server.close(resolve));
    },
  };
}

// ---------------------------------------------------------------------------
// Chat fixture: a chat project, a chat session, a memory proposal

export const encode = encodeURIComponent;

/** Poll `fn` until it returns a truthy value. */
export async function until(fn, what, ms = 30000) {
  const deadline = Date.now() + ms;
  for (;;) {
    const value = await fn();
    if (value) return value;
    if (Date.now() > deadline) throw new Error('timed out waiting for ' + what);
    await sleep(100);
  }
}

// ---------------------------------------------------------------------------
// The web app (a Vite dev server over a checkout's apps/web)

/** Serve `<tree>/apps/web` with Vite on 127.0.0.1. `tree` may be another
 * checkout (the compat run's old tree); its `node_modules` are then linked to
 * this tree's, which have the same locked dependencies. Returns a request
 * handler for the adapter's `fallback`. */
export async function startWebApp({ tree = repoRoot, cacheDir }) {
  const { pathToFileURL } = await import('node:url');
  // Vite compares real paths: a symlinked /tmp would put every file outside its allow list.
  tree = realpathSync(tree);
  const { createServer: createVite } = await import(
    pathToFileURL(path.join(repoRoot, 'apps/web/node_modules/vite/dist/node/index.js'))
  );
  const { svelte } = await import(
    pathToFileURL(
      path.join(repoRoot, 'apps/web/node_modules/@sveltejs/vite-plugin-svelte/src/index.js'),
    )
  );
  const webRoot = path.join(tree, 'apps/web');
  if (tree !== realpathSync(repoRoot)) {
    const { symlinkSync, lstatSync } = await import('node:fs');
    for (const [from, to] of [
      [path.join(tree, 'apps/web/node_modules'), path.join(repoRoot, 'apps/web/node_modules')],
      [path.join(tree, 'node_modules'), path.join(repoRoot, 'node_modules')],
    ]) {
      try {
        lstatSync(from);
      } catch {
        symlinkSync(to, from);
      }
    }
  }
  const vite = await createVite({
    configFile: false,
    root: webRoot,
    logLevel: 'error',
    plugins: [svelte()],
    cacheDir,
    server: {
      host: '127.0.0.1',
      port: await freePort(),
      strictPort: true,
      hmr: false,
      ws: false,
      fs: { allow: [tree, repoRoot] },
    },
  });
  await vite.listen();
  const address = vite.httpServer.address();
  const target = { hostname: '127.0.0.1', port: address.port };
  return {
    port: address.port,
    handler(req, res) {
      const outgoing = httpRequest(
        {
          ...target,
          method: req.method,
          path: req.url,
          headers: { ...req.headers, host: `127.0.0.1:${address.port}` },
        },
        (incoming) => {
          res.writeHead(incoming.statusCode, incoming.headers);
          incoming.pipe(res);
        },
      );
      outgoing.on('error', () => {
        res.writeHead(502);
        res.end();
      });
      req.pipe(outgoing);
    },
    async stop() {
      await vite.close();
    },
  };
}

/** The dedicated test browser (never the everyday Chrome) with a fresh profile. */
export async function launchTestBrowser(profileDir) {
  const { chromium } = await import('playwright-core');
  const { requireTestBrowserExecutable } = await import(
    path.join(repoRoot, 'apps/android/tool/parity/test_browser.mjs')
  );
  const executablePath = requireTestBrowserExecutable();
  const context = await chromium.launchPersistentContext(profileDir, {
    executablePath,
    headless: true,
  });
  const version = context.browser()?.version() ?? 'unknown';
  return { context, executablePath, version };
}

/** A local server that records every request it receives (an "external" site). */
export async function startReceiver() {
  const received = [];
  const server = createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    received.push({
      method: req.method,
      url: req.url,
      contentType: req.headers['content-type'] ?? '',
      body: Buffer.concat(chunks).toString('utf8'),
    });
    res.writeHead(200, { 'content-type': 'text/html' });
    res.end('<!doctype html><title>receiver</title><p>received</p>');
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return {
    received,
    url: `http://127.0.0.1:${server.address().port}`,
    async stop() {
      server.closeAllConnections?.();
      await new Promise((resolve) => server.close(resolve));
    },
  };
}

// ---------------------------------------------------------------------------
// Legitimate fixture data (created through the real API, with the marker header)

const ptcPropose = (id, content, quote) => ({
  tool: {
    id,
    name: 'ptc',
    args: {
      code: `const r = await tools.call('memory_propose_user', ${JSON.stringify({ action: 'add', content, quote })}); return JSON.stringify(r);`,
    },
  },
});

/** Through the real chat node, driven by the scripted model: three memory
 * proposals (A, B, C); A is then approved so that it is an active entry.
 * Returns { sessionId, entry, pendingB, pendingC } (ids). */
export async function seedMemory(stack, llm) {
  const c = stack.client;
  const created = await c.call('POST', '/api/sessions', { json: { workspaceId: 'chat:chats' } });
  if (created.status !== 201) throw new Error('create chat: ' + created.text);
  const sessionId = created.json.session.id;
  const lease = await c.call('POST', `/api/sessions/${sessionId}/control/acquire`, {
    json: { clientId: 'e2e' },
  });
  llm.push(
    ptcPropose('a', 'Wants to be called Ice.', 'call me Ice'),
    ptcPropose('b', 'Prefers short answers.', 'keep it short'),
    ptcPropose('c', 'Lives in Taipei.', 'I live in Taipei'),
    { text: 'Proposed three things.' },
  );
  const prompt = await c.call('POST', `/api/sessions/${sessionId}/commands`, {
    json: {
      commandId: 'seed-1',
      clientId: 'e2e',
      generation: lease.json.lease.generation,
      payload: {
        type: 'prompt',
        message: 'Please call me Ice. Also keep it short. And I live in Taipei.',
      },
    },
  });
  if (prompt.status !== 202) throw new Error('prompt: ' + prompt.text);
  const view = await until(async () => {
    const memory = (await c.call('GET', '/api/memory')).json;
    return memory?.proposals?.length >= 3 ? memory : null;
  }, 'three memory proposals');
  const byContent = (text) => view.proposals.find((p) => p.content === text);
  const [a, b, cc] = [
    byContent('Wants to be called Ice.'),
    byContent('Prefers short answers.'),
    byContent('Lives in Taipei.'),
  ];
  if (!a || !b || !cc) throw new Error('missing proposals: ' + JSON.stringify(view.proposals));
  const approved = await c.call('POST', `/api/memory/proposals/${a.id}/approve`, { json: {} });
  if (approved.status !== 200) throw new Error('approve A: ' + approved.text);
  const entry = approved.json.user.find((e) => e.content === 'Wants to be called Ice.');
  return { sessionId, entry: entry.id, pendingB: b.id, pendingC: cc.id };
}

/** A chat project with one project file; returns where the node keeps it. */
export async function seedProject(
  stack,
  name = 'target.txt',
  content = 'ORIGINAL PROJECT FILE v1\n',
) {
  const c = stack.client;
  const created = await c.call('POST', '/api/workspaces', {
    json: { nodeId: 'chat', kind: 'chat', displayName: 'Trip' },
  });
  if (created.status !== 201) throw new Error('create project: ' + created.text);
  const id = created.json.workspace.id;
  const local = id.replace(/^chat:/, '');
  const uploaded = await c.call(
    'POST',
    `/api/workspaces/${encode(id)}/files?filename=${encode(name)}`,
    {
      raw: content,
      contentType: 'text/plain',
    },
  );
  if (uploaded.status !== 201) throw new Error('project file: ' + uploaded.text);
  return {
    id,
    name,
    file: path.join(stack.stateDir('chat'), 'chat', local, 'files', name),
    route: `/api/workspaces/${encode(id)}/files?filename=${encode(name)}`,
  };
}

/** What the memory and the project file look like now, for before/after. */
export async function memorySnapshot(stack, seed, project) {
  const view = (await stack.client.call('GET', '/api/memory')).json;
  const { createHash } = await import('node:crypto');
  const bytes = existsSync(project.file) ? readFileSync(project.file) : Buffer.alloc(0);
  const files = (await stack.client.call('GET', `/api/workspaces/${encode(project.id)}/files`))
    .json;
  return {
    proposals: Object.fromEntries(view.proposals.map((p) => [p.id, p.status])),
    entries: Object.fromEntries(
      [...view.user, ...view.notes].map((e) => [e.id, `${e.status}@${e.revision}`]),
    ),
    removed: view.removed.map((e) => e.id),
    userContents: view.user.map((e) => e.content),
    projectFileSha256: createHash('sha256').update(bytes).digest('hex'),
    projectFileBytes: bytes.toString('utf8'),
    projectFiles: files.files?.map((f) => `${f.name}:${f.byteSize}:${f.modifiedAt}`),
    seed: { entry: seed.entry, pendingB: seed.pendingB, pendingC: seed.pendingC },
  };
}

/** Provenance of a run, for the reports. */
export function coverage() {
  const run = (...args) => {
    try {
      return git(...args);
    } catch {
      return '?';
    }
  };
  const dirty = (pathspec) => run('status', '--short', '--', pathspec).split('\n').filter(Boolean);
  return {
    head: run('rev-parse', '--short=12', 'HEAD'),
    sanitiserCommit: run('log', '-1', '--format=%h %s', '--', 'apps/web/src/lib/markdown.ts'),
    gatewayCommit: run('log', '-1', '--format=%h %s', '--', 'crates/pirc-gateway'),
    requestShapeCommit: run(
      'log',
      '-1',
      '--format=%h %s',
      '--',
      'crates/pirc-gateway/src/request_shape.rs',
    ),
    uncommitted: {
      web: dirty('apps/web'),
      gateway: dirty('crates'),
      android: dirty('apps/android'),
    },
  };
}
