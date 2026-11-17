/** V3: client x Gateway compatibility matrix.
 *
 * OLD = commit 645b262f (before the request-shape rule); NEW = this checkout.
 * The old Gateway/Node are built from a temporary detached worktree into
 * target/suites/compat-645b262f (kept, as the agreed build cache); the
 * worktree is removed at the end. Each Gateway gets its own fresh state.
 *
 *  Web cells  - the real web app (Vite dev server over apps/web of the tree)
 *               in the dedicated test browser; the app's own api modules are
 *               driven in the page, so the requests are the ones the app
 *               builds. Old-Web x new-Gateway also drives the real UI and
 *               records what the user sees.
 *  App cells  - the REAL PircApi.kt of each tree, compiled to JVM (no APK, no
 *               emulator) with the harness scripts/e2e/jvm/AppCompat.kt and run
 *               against the real binaries. Not an APK; not on a device.
 *
 * Expected: a JSON body works everywhere; a body-less write or a raw upload
 * from an OLD client is refused by the NEW Gateway (415 request_shape_required);
 * a NEW client works against both Gateways (the old one ignores the header).
 */
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import {
  Results,
  FakeLlm,
  binaries,
  buildCurrent,
  startStack,
  startAdapter,
  startWebApp,
  launchTestBrowser,
  makeTempDir,
  removeDir,
  seedMemory,
  seedProject,
  stopAllProcesses,
  repoRoot,
  coverage,
  git,
  encode,
} from './lib.mjs';
import { buildAppClient, runAppClient } from './jvm.mjs';

const OLD_COMMIT = '645b262f';
const OLD_TARGET = path.join(repoRoot, 'target/suites/compat-645b262f');
const results = new Results('V3');
const ARTIFACTS = process.env.PIRC_E2E_ARTIFACTS;

// Operation kinds decide what an old client gets from the new Gateway.
const kindOf = (name) =>
  /body-less|markRead|deleteSession|project remove|delete schedule/i.test(name)
    ? 'bodyless'
    : /upload|project file write|project upload/i.test(name)
      ? 'raw'
      : 'json';
const expectation = (clientIsOld, gatewayIsOld, kind) =>
  clientIsOld && !gatewayIsOld && kind !== 'json' ? 'refused' : 'ok';

function judge(cell, ops, clientIsOld, gatewayIsOld) {
  for (const op of ops) {
    const want = expectation(clientIsOld, gatewayIsOld, kindOf(op.name));
    const got = op.ok
      ? 'ok'
      : op.status === 415 && op.code === 'request_shape_required'
        ? 'refused'
        : 'other';
    results.check(
      `${cell} :: ${op.name} -> ${want === 'ok' ? '2xx' : '415 request_shape_required'}`,
      got === want,
      op.ok ? 'ok' : `status ${op.status} ${op.code}: ${op.message}`.slice(0, 220),
    );
  }
}

function ensureOldTree() {
  const dir = makeTempDir('oldtree');
  fs.rmSync(dir, { recursive: true, force: true });
  git('worktree', 'add', '--detach', dir, OLD_COMMIT);
  console.log(`old tree ${OLD_COMMIT} at ${dir}`);
  fs.mkdirSync(OLD_TARGET, { recursive: true });
  execFileSync('cargo', ['build', '--locked', '-p', 'pirc-gateway', '-p', 'pirc-node'], {
    cwd: dir,
    stdio: 'inherit',
    env: { ...process.env, CARGO_TARGET_DIR: OLD_TARGET },
  });
  return { dir, bins: binaries(OLD_TARGET) };
}

/** Fresh Gateway+Node, with the fixtures every client operation needs. */
async function fixture({ bins, llm, root }) {
  const stack = await startStack({ root, bins, llm, nodes: [{ id: 'chat', kind: 'chat' }] });
  const c = stack.client;
  const session = (await c.call('POST', '/api/sessions', { json: { workspaceId: 'chat:chats' } }))
    .json.session.id;
  const project = await seedProject(stack);
  let memory;
  try {
    memory = await seedMemory(stack, llm);
  } catch (error) {
    memory = { pendingB: 'missing-proposal', error: String(error) };
  }
  const device = await c.call('POST', '/api/devices', { json: { name: 'e2e app' } });
  return { stack, session, project, memory, token: device.json?.token };
}

/** The web app's own api modules, driven in the page. */
async function webOperations(page, f) {
  return page.evaluate(
    async ({ session, project, proposal }) => {
      const { api } = await import('/src/lib/api.ts');
      const { projectFilesApi } = await import('/src/lib/capabilities.ts');
      const { memoryApi } = await import('/src/lib/memory.ts');
      const out = [];
      const op = async (name, fn) => {
        try {
          await fn();
          out.push({ name, ok: true });
        } catch (error) {
          out.push({
            name,
            ok: false,
            status: error?.status,
            code: error?.code,
            message: String(error?.message ?? error),
          });
        }
      };
      let created;
      await op('create session (JSON POST)', async () => {
        created = await api.createSession({ workspaceId: 'chat:chats' });
      });
      await op('rename session (JSON PATCH)', () =>
        api.updateSession(session, { name: 'renamed by web' }),
      );
      await op('markRead (body-less POST)', () => api.markRead(session));
      await op('upload text file (raw POST)', () =>
        api.upload(session, new File(['hello from the web'], 'web.txt', { type: 'text/plain' })),
      );
      await op('upload image (raw POST)', () =>
        api.upload(
          session,
          new File([new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10])], 'web.png', {
            type: 'image/png',
          }),
        ),
      );
      await op('project file write (raw POST)', () =>
        projectFilesApi.upload(
          project,
          new File(['web bytes'], 'web-file.txt', { type: 'text/plain' }),
        ),
      );
      await op('project remove (body-less DELETE)', () =>
        projectFilesApi.remove(project, 'web-file.txt'),
      );
      await op('approve memory proposal (JSON POST)', () => memoryApi.approve(proposal));
      await op('deleteSession (body-less DELETE)', () =>
        api.deleteSession(created?.id ?? 'missing'),
      );
      return out;
    },
    { session: f.session, project: f.project.id, proposal: f.memory.pendingB },
  );
}

async function webCell({ label, webTree, bins, llm, clientIsOld, gatewayIsOld, drive }) {
  if (process.env.PIRC_E2E_V3_CELL && !label.includes(process.env.PIRC_E2E_V3_CELL)) return;
  const root = makeTempDir('v3w');
  let f, web, adapter, browser;
  try {
    f = await fixture({ bins, llm, root });
    web = await startWebApp({ tree: webTree, cacheDir: path.join(root, 'vite-cache') });
    adapter = await startAdapter({
      gateway: f.stack.base,
      fallback: (req, res) => {
        if (req.url === '/__e2e/blank.html') {
          res.writeHead(200, { 'content-type': 'text/html' });
          res.end('<!doctype html><title>blank</title>');
        } else web.handler(req, res);
      },
    });
    browser = await launchTestBrowser(path.join(root, 'profile'));
    const page = await browser.context.newPage();
    page.setDefaultTimeout(30000);
    await page.goto(`${adapter.url}/__e2e/blank.html`);
    const ops = await webOperations(page, f);
    judge(label, ops, clientIsOld, gatewayIsOld);
    if (drive) {
      try {
        await drive({ page, adapter, f, browser });
      } catch (error) {
        if (ARTIFACTS) {
          fs.mkdirSync(ARTIFACTS, { recursive: true });
          await page
            .screenshot({ path: path.join(ARTIFACTS, 'v3-ui-probe-failed.png') })
            .catch(() => {});
        }
        results.add(
          `${label} :: UI probe`,
          'not-run',
          String(error?.message ?? error).split('\n')[0],
        );
      }
    }
    return browser.version;
  } finally {
    await browser?.context.close().catch(() => {});
    await adapter?.stop().catch(() => {});
    await web?.stop().catch(() => {});
    await f?.stack.stop().catch(() => {});
    removeDir(root);
  }
}

/** Old Web x new Gateway: what the user sees. */
async function oldUiProbe({ page, adapter, f }) {
  const shots = [];
  const refused = [];
  page.on('response', (r) => {
    if (r.status() === 415) refused.push(`${r.request().method()} ${new URL(r.url()).pathname}`);
  });
  const shot = async (name) => {
    if (!ARTIFACTS) return;
    fs.mkdirSync(ARTIFACTS, { recursive: true });
    await page.screenshot({ path: path.join(ARTIFACTS, `v3-old-web-${name}.png`) });
  };
  const visible = async () =>
    (await page.evaluate(() => document.body.innerText)).replace(/\s+/g, ' ');
  const file = path.join(f.stack.root, 'ui-upload.txt');
  fs.writeFileSync(file, 'uploaded through the old UI\n');
  // (1) Project files: add a file on the project's Settings tab.
  await page.goto(`${adapter.url}/`);
  await page.getByLabel('Send message').waitFor();
  await page.getByText('Trip', { exact: true }).first().click();
  await page.getByRole('tab', { name: 'Settings' }).click();
  const input = page.locator('input[type=file]').first();
  await input.waitFor({ state: 'attached' });
  await input.setInputFiles(file);
  await page.waitForTimeout(2500);
  await shot('project-file-upload');
  const text1 = await visible();
  const at = text1.indexOf('ui-upload.txt');
  shots.push([
    'project file upload (raw POST)',
    at >= 0 ? text1.slice(Math.max(0, at - 20), at + 180) : '(no error text found)',
  ]);
  // (2) The composer's attach button in a chat.
  await page.goto(`${adapter.url}/?session=${encodeURIComponent(f.session)}`);
  await page.getByLabel('Send message').waitFor();
  const attach = page.locator('input[type=file]').first();
  await attach.waitFor({ state: 'attached' });
  await attach.setInputFiles(file);
  await page.waitForTimeout(2500);
  await shot('composer-attach');
  const text2 = await visible();
  const hit = text2.match(
    /(out of date[^]{0,140})|(State-changing[^]{0,160})|(Request failed[^]{0,120})|(ui-upload\.txt[^]{0,160})/,
  );
  shots.push([
    'composer attach (raw POST)',
    hit ? hit[0] : '(no error text and no attachment chip visible)',
  ]);
  // (3) Opening an unread chat sends the body-less "mark read" write.
  await page.goto(`${adapter.url}/?session=${encodeURIComponent(f.memory.sessionId)}`);
  await page.getByLabel('Send message').waitFor();
  await page.waitForTimeout(2500);
  await shot('unread-chat-opened');
  shots.push([
    'mark read (body-less POST, automatic)',
    'no message; refused silently, requests seen: ' +
      (refused.filter((r) => r.endsWith('/read')).length ? 'POST .../read -> 415' : 'none'),
  ]);
  shots.push(['all 415 responses during the UI probe', [...new Set(refused)].join('; ') || 'none']);
  return shots;
}

async function appCells({ newGw, oldGw, oldTree, llm }) {
  const clients = {
    new: buildAppClient(repoRoot, 'new'),
    old: buildAppClient(oldTree, 'old'),
  };
  console.log(`App clients compiled: new ${clients.new.key}, old ${clients.old.key}`);
  for (const [clientName, gatewayName] of [
    ['new', 'new'],
    ['new', 'old'],
    ['old', 'new'],
    ['old', 'old'],
  ]) {
    const root = makeTempDir('v3a');
    let f;
    try {
      f = await fixture({ bins: gatewayName === 'new' ? newGw : oldGw, llm, root });
      const ops = runAppClient(clients[clientName], [
        f.stack.base,
        f.token,
        f.session,
        f.project.id,
        f.memory.pendingB,
        'chat:chats',
      ]);
      judge(
        `App(${clientName}) x Gateway(${gatewayName})`,
        ops,
        clientName === 'old',
        gatewayName === 'old',
      );
    } finally {
      await f?.stack.stop().catch(() => {});
      removeDir(root);
    }
  }
}

async function main() {
  const info = coverage();
  console.log(
    'V3 coverage:',
    JSON.stringify({
      head: info.head,
      gateway: info.gatewayCommit,
      requestShape: info.requestShapeCommit,
      uncommitted: info.uncommitted,
    }),
  );
  const newBins = process.env.PIRC_E2E_SKIP_BUILD ? binaries() : buildCurrent();
  const llm = await new FakeLlm().start();
  const old = ensureOldTree();
  try {
    const only = (process.env.PIRC_E2E_V3_ONLY || 'web,app').split(',');
    if (only.includes('web')) {
      const common = { llm };
      const v = await webCell({
        ...common,
        label: 'Web(new) x Gateway(new)',
        webTree: repoRoot,
        bins: newBins,
        clientIsOld: false,
        gatewayIsOld: false,
      });
      console.log('browser version', v);
      await webCell({
        ...common,
        label: 'Web(new) x Gateway(old)',
        webTree: repoRoot,
        bins: old.bins,
        clientIsOld: false,
        gatewayIsOld: true,
      });
      await webCell({
        ...common,
        label: 'Web(old) x Gateway(new)',
        webTree: old.dir,
        bins: newBins,
        clientIsOld: true,
        gatewayIsOld: false,
        drive: async (ctx) => {
          const shown = await oldUiProbe(ctx);
          for (const [what, text] of shown)
            results.add(`Web(old) x Gateway(new) :: what the old UI shows: ${what}`, 'pass', text);
        },
      });
      await webCell({
        ...common,
        label: 'Web(old) x Gateway(old) [baseline]',
        webTree: old.dir,
        bins: old.bins,
        clientIsOld: true,
        gatewayIsOld: true,
      });
    }
    if (only.includes('app'))
      await appCells({ newGw: newBins, oldGw: old.bins, oldTree: old.dir, llm });
  } finally {
    await llm.stop().catch(() => {});
    await stopAllProcesses();
    try {
      git('worktree', 'remove', '--force', old.dir);
      console.log('removed the temporary old worktree');
    } catch (error) {
      console.log('could not remove the old worktree ' + old.dir + ': ' + error.message);
    }
    removeDir(old.dir);
  }
}

try {
  await main();
} catch (error) {
  results.add('V3 aborted', 'fail', String(error?.stack ?? error));
}
console.log(
  `V3: ${results.rows.filter((r) => r.status === 'pass').length} passed, ${results.failed.length} failed`,
);
process.exit(results.failed.length ? 1 : 0);
