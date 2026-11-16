/** Real Web first-send/IndexedDB acceptance, driven by conversation_web_client.rs.
 * The fixture Gateway runs with PIRC_FIRST_SEND=1 (the server refuses new
 * first-send admission otherwise); the shipped default stays disabled.
 * A dedicated test executable and a new profile are mandatory. Never use Chrome.app.
 */
import assert from 'node:assert/strict';
import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { chromium } from 'playwright-core';
import { runClientRaces, runOfflineRace, runAllocationRecovery } from './first-send-races.mjs';
import { requireTestBrowserExecutable } from '../apps/android/tool/parity/test_browser.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const config = JSON.parse(await readFile(process.argv[2], 'utf8'));
assert.equal(new URL(config.gateway).hostname, '127.0.0.1');
assert.equal(config.owner, 'test@example.com');
assert.equal(config.host, 'test.example');
assert.equal(config.workspace, 'test:chats');
const directory = config.directory;
await mkdir(directory, { recursive: true });
const { createServer } = await import(
  pathToFileURL(path.join(root, 'apps/web/node_modules/vite/dist/node/index.js'))
);
const { svelte } = await import(
  pathToFileURL(path.join(root, 'apps/web/node_modules/@sveltejs/vite-plugin-svelte/src/index.js'))
);
const traffic = [];
let lostReply = false,
  replayResponse = false,
  capabilityChecks = 0,
  context,
  server;
const publish = async (name, value) => {
  const temporary = path.join(directory, name + '.pending');
  await writeFile(temporary, JSON.stringify(value));
  await rename(temporary, path.join(directory, name + '.json'));
};
const marker = async (name) => {
  const deadline = Date.now() + 60000;
  while (true) {
    try {
      return JSON.parse(await readFile(path.join(directory, name + '.json'), 'utf8'));
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    assert(Date.now() < deadline, 'Timed out waiting for ' + name);
    await new Promise((resolve) => setTimeout(resolve, 30));
  }
};
const cleanup = async () => {
  const closing = context;
  context = undefined;
  if (closing) await closing.close();
  if (server) await server.close();
};
process.once('SIGTERM', () => {
  void cleanup().finally(() => process.exit(1));
});

async function proxy(req, res) {
  const headers = {
    host: config.host,
    origin: config.origin,
    'x-pirc-user': config.owner,
    accept: 'application/json',
  };
  for (const key of ['content-type', 'x-pirc-account', 'x-pirc-first-send-contract'])
    if (req.headers[key]) headers[key] = req.headers[key];
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  if (
    config.mode === 'competition' &&
    req.method === 'POST' &&
    /\/race-(stop|delete|admit)\/dispatch$/.test(req.url)
  ) {
    const id = req.url.split('/')[3];
    await publish('held-' + id, JSON.parse(Buffer.concat(chunks)));
    await marker('release-' + id);
  }
  const reply = await new Promise((resolve, reject) => {
    const outgoing = http.request(
      new URL(req.url, config.gateway),
      { method: req.method, headers },
      (incoming) => {
        const parts = [];
        incoming.on('data', (part) => parts.push(part));
        incoming.on('end', () =>
          resolve({ status: incoming.statusCode, body: Buffer.concat(parts) }),
        );
        incoming.on('error', reject);
      },
    );
    outgoing.on('error', reject);
    outgoing.setTimeout(30000, () => outgoing.destroy(new Error('Fixture Gateway timeout')));
    outgoing.end(Buffer.concat(chunks));
  });
  traffic.push({ method: req.method, path: req.url, status: reply.status });
  if (req.url === '/api/conversation-submissions/capabilities' && reply.status === 200) {
    const value = JSON.parse(reply.body);
    assert.equal(value.canSubmit, true, 'The fixture Gateway must run with PIRC_FIRST_SEND=1');
    assert.equal(value.clientContract, 2);
    assert.equal(value.requiredClientContract, 2);
    capabilityChecks++;
  }
  if (
    !replayResponse &&
    req.url === '/api/conversation-submissions/transport-replay/dispatch' &&
    reply.status === 200
  ) {
    assert.equal(JSON.parse(reply.body).preparation.state, 'admitted');
    replayResponse = true;
    res.destroy(); // Chromium can transparently replay this POST on a fresh connection.
    return;
  }
  if (
    !lostReply &&
    req.url === '/api/conversation-submissions/reply-loss/dispatch' &&
    reply.status === 200
  ) {
    assert.equal(JSON.parse(reply.body).preparation.state, 'admitted');
    lostReply = true;
    // Lose an in-progress body, after the browser knows the server responded.
    res.writeHead(200, { 'content-type': 'application/json', 'content-length': reply.body.length });
    res.flushHeaders();
    res.write(reply.body.subarray(0, 1), () => res.destroy());
    return;
  }
  res.writeHead(reply.status, { 'content-type': 'application/json' });
  res.end(reply.body);
}
async function page() {
  const p = await context.newPage();
  p.setDefaultTimeout(30000);
  await p.goto(server.resolvedUrls.local[0] + '__first_send_acceptance');
  await p.evaluate(async () => {
    const { FirstSend, draftScope } = await import('/src/lib/first-send.ts');
    const { BrowserDraftStore } = await import('/src/lib/first-send-storage.ts');
    window.drafts = new BrowserDraftStore();
    window.flow = new FirstSend(window.drafts);
    window.scope = draftScope(location.origin, 'test@example.com');
  });
  return p;
}
try {
  server = await createServer({
    configFile: false,
    root: path.join(root, 'apps/web'),
    logLevel: 'error',
    plugins: [
      svelte(),
      {
        name: 'live-first-send-fixture',
        configureServer(vite) {
          vite.middlewares.use((req, res, next) => {
            if (req.url.startsWith('/api/')) {
              void proxy(req, res).catch((error) => {
                console.error(error);
                res.writeHead(500);
                res.end();
              });
            } else if (req.url === '/__first_send_acceptance') {
              res.setHeader('content-type', 'text/html');
              res.end('<!doctype html><title>First-send acceptance</title>');
            } else next();
          });
        },
      },
    ],
    resolve: { conditions: ['browser'] },
    cacheDir: path.join(directory, 'vite-cache'),
    server: { host: '127.0.0.1', port: 0 },
  });
  await server.listen();
  const options = { executablePath: requireTestBrowserExecutable(), headless: true };
  const profile = path.join(directory, 'profile');
  context = await chromium.launchPersistentContext(profile, options);
  if (['competition', 'offline', 'allocation'].includes(config.mode)) {
    const run = {
      competition: runClientRaces,
      offline: runOfflineRace,
      allocation: runAllocationRecovery,
    }[config.mode];
    await run({
      operationId: config.operationId,
      page,
      publish,
      marker,
      traffic,
      workspace: config.workspace,
      close: async () => {
        await context.close();
        context = undefined;
      },
      reopen: async () => {
        context = await chromium.launchPersistentContext(profile, options);
      },
    });
  } else {
    const editor = await page();
    const pending = [];
    for (const id of ['transport-replay', 'reply-loss', 'local-write-loss']) {
      const result = await editor.evaluate(
        async ({ id, workspace }) => {
          const blob = new Blob(['Original bytes for ' + id], { type: 'text/plain' });
          await window.flow.save(window.scope, 'test@example.com', id, {
            workspaceId: workspace,
            message: 'First message ' + id,
            model: { provider: 'fake', id: 'fake-model' },
            thinking: 'low',
            files: [
              {
                id: 'original-file',
                name: 'notes.txt',
                mimeType: blob.type,
                byteSize: blob.size,
                blob,
              },
            ],
          });
          let failedCommit = false;
          if (id === 'local-write-loss') {
            const update = window.drafts.update.bind(window.drafts);
            window.drafts.update = (scope, key, change) =>
              update(scope, key, (before) => {
                const after = change(before);
                // Real IndexedDB transaction abort, after a real admitted response.
                if (key === id && (failedCommit || after?.preparation?.state === 'admitted')) {
                  failedCommit = true;
                  throw new DOMException('Injected full local journal', 'QuotaExceededError');
                }
                return after;
              });
          }
          let error;
          try {
            await window.flow.run(window.scope, id);
          } catch (failure) {
            error = String(failure);
          }
          const row = await window.drafts.get(window.scope, id);
          if (id === 'transport-replay' && !error) {
            if (row.preparation?.state !== 'admitted')
              throw new Error('Replay did not reconcile its original command');
          } else {
            if (!error) throw new Error('Expected interrupted outcome for ' + id);
            if (row.preparation?.state !== 'ready' || !row.uncertain || !row.frozen)
              throw new Error(
                'Lost response must retain frozen, uncertain original: ' + JSON.stringify(row),
              );
          }
          return {
            id,
            session: row.preparation.sessionId,
            bytes: await row.files[0].blob.text(),
            failedCommit,
          };
        },
        { id, workspace: config.workspace },
      );
      pending.push(result);
    }
    assert.equal(lostReply, true);
    assert.equal(replayResponse, true);
    assert.equal(pending[2].failedCommit, true);
    assert.equal(capabilityChecks, 3);
    for (const op of pending) assert.equal(op.bytes, 'Original bytes for ' + op.id);
    await context.close();
    context = undefined;
    await publish('before-restart', { operations: pending, traffic });
    const deadline = Date.now() + 60000;
    while (true) {
      try {
        await readFile(path.join(directory, 'hosts-restarted.json'));
        break;
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
      }
      if (Date.now() >= deadline) throw new Error('Timed out waiting for fixture host restart');
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    const boundary = traffic.length;
    const dispatches = (id) =>
      traffic.filter(
        (request) => request.path === '/api/conversation-submissions/' + id + '/dispatch',
      ).length;
    const before = new Map(pending.map((op) => [op.id, dispatches(op.id)]));
    assert.equal(before.get('reply-loss'), 1);
    assert.equal(before.get('local-write-loss'), 1);
    assert(before.get('transport-replay') >= 1);
    context = await chromium.launchPersistentContext(profile, options);
    const first = await page(),
      second = await page();
    for (const op of pending) {
      for (const p of [first, second]) {
        assert.equal(
          await p.evaluate(
            async (id) => (await window.drafts.get(window.scope, id)).preparation.sessionId,
            op.id,
          ),
          op.session,
        );
      }
      const receipts = await Promise.all(
        [first, second].map((p) =>
          p.evaluate(async (id) => {
            const row = await window.flow.check(window.scope, id);
            return {
              session: row.preparation.sessionId,
              state: row.preparation.state,
              bytes: await row.files[0].blob.text(),
            };
          }, op.id),
        ),
      );
      for (const receipt of receipts)
        assert.deepEqual(receipt, { session: op.session, state: 'admitted', bytes: op.bytes });
      await first.evaluate((id) => window.flow.run(window.scope, id), op.id);
    }
    assert(
      traffic.slice(boundary).every((request) => request.method === 'GET'),
      'Reopening/reconciliation must never resend',
    );
    for (const op of pending) assert.equal(dispatches(op.id), before.get(op.id));
    await publish('result', { operations: pending, traffic, readOnlyAfterRestart: true });
    console.log(
      'PASS: real Web/IndexedDB + Gateway/Node/Agent; transport replay, lost reply and aborted local receipt; two-tab GET-only reconciliation after all hosts restart.',
    );
  }
} catch (error) {
  console.error('Fixture HTTP trace:', JSON.stringify(traffic));
  throw error;
} finally {
  await cleanup();
}
