/** V1: hostile forms in a real browser.
 *
 * Real pirc-gateway and pirc-node (a chat node and a directory node) with fresh
 * state, behind the local trusted-proxy adapter, serve the web app to the
 * dedicated test browser (fresh profile). A Markdown file in a workspace holds
 * forms that POST to the app's own memory approve/reject/forget routes and to
 * the project-file write route (urlencoded, multipart, text/plain, empty), and
 * to a local external receiver. The submit controls are clicked for real.
 *
 * Asserted through the API: proposals still pending, the entry still active,
 * the project file's bytes unchanged. Control: the receiver gets its fields
 * intact, and the same requests WITH the marker header do work.
 *
 * Two phases: (1) the forms as the app renders the previewed Markdown (what
 * the sanitiser leaves), (2) the same forms as raw HTML on a same-origin page,
 * which reach the Gateway whatever the sanitiser does.
 */
import fs from 'node:fs';
import path from 'node:path';
import {
  Results,
  FakeLlm,
  binaries,
  buildCurrent,
  startStack,
  startAdapter,
  startWebApp,
  startReceiver,
  launchTestBrowser,
  makeTempDir,
  removeDir,
  seedMemory,
  seedProject,
  memorySnapshot,
  coverage,
  stopAllProcesses,
  encode,
  sleep,
} from './lib.mjs';
import assert from 'node:assert/strict';

const results = new Results('V1');
const ENCODINGS = [
  ['urlencoded', 'application/x-www-form-urlencoded'],
  ['multipart', 'multipart/form-data'],
  ['text-plain', 'text/plain'],
  ['empty', 'application/x-www-form-urlencoded'],
];

/** The case list: every form is one submit button S<nn>. */
function buildCases({ origin, seed, project, receiver }) {
  const targets = [
    ['approve', `/api/memory/proposals/${seed.pendingB}/approve`],
    ['reject', `/api/memory/proposals/${seed.pendingC}/reject`],
    ['forget', `/api/memory/entries/${seed.entry}/forget`],
    ['project-write', project.route],
  ];
  const cases = [];
  let n = 0;
  const add = (c) => cases.push({ ...c, button: `S${String(++n).padStart(2, '0')}` });
  targets.forEach(([target, route], index) => {
    for (const [name, enctype] of ENCODINGS) {
      // The first of each target uses an absolute same-origin URL, the rest a relative one.
      const action = name === 'multipart' ? origin + route : route;
      add({
        kind: 'state',
        target,
        enc: name,
        enctype,
        action,
        fields:
          name === 'empty'
            ? []
            : [
                ['note', 'x'],
                ['targetRevision', '1'],
              ],
      });
    }
    // The text/plain trick that yields a body which parses as JSON.
    add({
      kind: 'state',
      target,
      enc: 'text-plain-json',
      enctype: 'text/plain',
      action: route,
      fields: [['{"targetRevision":1,"x":"', '"}']],
    });
    // A submit control that overrides the form's own action.
    add({
      kind: 'state',
      target,
      enc: 'formaction',
      enctype: 'application/x-www-form-urlencoded',
      action: '/',
      formaction: route,
      fields: [['note', 'x']],
    });
  });
  for (const [name, enctype] of ENCODINGS.slice(0, 3)) {
    add({
      kind: 'external',
      target: 'receiver',
      enc: name,
      enctype,
      action: receiver + '/submit',
      fields: [
        ['a', '1'],
        ['b', 'two words'],
      ],
    });
  }
  return cases;
}

const esc = (value) =>
  String(value).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');
function formHtml(c) {
  const inputs = c.fields
    .map(([n, v]) => `<input type="text" name="${esc(n)}" value="${esc(v)}">`)
    .join('');
  const attr = c.formaction ? ` formaction="${esc(c.formaction)}"` : '';
  return (
    `<form action="${esc(c.action)}" method="post" enctype="${esc(c.enctype)}">` +
    `${inputs}<button type="submit"${attr}>${c.button}</button></form>`
  );
}
const markdownFor = (cases) =>
  '# Release notes\n\nPlease review the items below.\n\n' +
  cases.map((c) => formHtml(c)).join('\n\n') +
  '\n';
const rawPageFor = (cases) =>
  `<!doctype html><meta charset="utf-8"><title>raw forms</title>${cases.map(formHtml).join('<br>')}`;

async function main() {
  const info = coverage();
  console.log('V1 coverage:', JSON.stringify(info, null, 1));
  const bins = process.env.PIRC_E2E_SKIP_BUILD ? binaries() : buildCurrent();
  const llm = await new FakeLlm().start();
  const root = makeTempDir('v1');
  let stack, web, adapter, receiver, browser;
  try {
    stack = await startStack({
      root,
      bins,
      llm,
      nodes: [
        { id: 'test', kind: 'directory' },
        { id: 'chat', kind: 'chat' },
      ],
    });
    const seed = await seedMemory(stack, llm);
    const project = await seedProject(stack);
    const directory = await stack.client.call('POST', '/api/sessions', {
      json: { workspaceId: 'test:test' },
    });
    assert.equal(directory.status, 201);
    const sessionId = directory.json.session.id;
    receiver = await startReceiver();
    web = await startWebApp({
      tree: process.env.PIRC_E2E_WEB_TREE || undefined,
      cacheDir: path.join(root, 'vite-cache'),
    });
    const rawPageHolder = { html: '' };
    const adapterLog = [];
    adapter = await startAdapter({
      gateway: stack.base,
      log: adapterLog,
      fallback: (req, res) => {
        if (req.url === '/__e2e/raw.html') {
          res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
          res.end(rawPageHolder.html);
        } else web.handler(req, res);
      },
    });
    const cases = buildCases({ origin: adapter.url, seed, project, receiver: receiver.url });
    fs.writeFileSync(path.join(stack.workspaceDirs.test, 'hostile.md'), markdownFor(cases));
    rawPageHolder.html = rawPageFor(cases);
    const before = await memorySnapshot(stack, seed, project);
    results.check(
      'setup: 2 proposals pending, 1 active entry, project file present',
      before.proposals[seed.pendingB] === 'pending' &&
        before.proposals[seed.pendingC] === 'pending' &&
        before.entries[seed.entry]?.startsWith('active') &&
        before.projectFileBytes === 'ORIGINAL PROJECT FILE v1\n',
      JSON.stringify({
        proposals: before.proposals,
        entries: before.entries,
        file: before.projectFileSha256.slice(0, 12),
      }),
    );

    browser = await launchTestBrowser(path.join(root, 'profile'));
    console.log(`browser: ${browser.executablePath} (${browser.version})`);
    const page = await browser.context.newPage();
    page.setDefaultTimeout(20000);

    // ---- Phase 1: the previewed Markdown, as the app renders it -------------
    const openPreview = async () => {
      await page.goto(`${adapter.url}/?session=${encodeURIComponent(sessionId)}`);
      // The side panel may start closed: open it once the page has settled.
      await page.getByLabel('Send message').waitFor();
      const show = page.getByLabel('Show side panel');
      if (await show.count()) await show.click();
      try {
        await page.getByText('hostile.md').click();
        await page.getByRole('button', { name: 'S01', exact: true }).waitFor();
      } catch (error) {
        if (process.env.PIRC_E2E_ARTIFACTS) {
          fs.mkdirSync(process.env.PIRC_E2E_ARTIFACTS, { recursive: true });
          await page.screenshot({
            path: path.join(process.env.PIRC_E2E_ARTIFACTS, 'v1-open-failed.png'),
          });
        }
        throw error;
      }
    };
    await openPreview();
    // What the app left of each form (action/enctype/formaction as rendered).
    const rendered = await page.evaluate(() =>
      [...document.querySelectorAll('form')].map((form) => ({
        button: form.querySelector('button')?.textContent,
        action: form.getAttribute('action'),
        enctype: form.getAttribute('enctype'),
        method: form.getAttribute('method'),
        formaction: form.querySelector('button')?.getAttribute('formaction'),
        target: form.getAttribute('target'),
      })),
    );
    const survivingActions = rendered.filter((r) => r.action || r.formaction).length;
    console.log(
      `phase 1: ${rendered.length} forms rendered, ${survivingActions} keep an action/formaction`,
    );
    const externalRendered = rendered.slice(-3);
    const post = { toGateway: 0, other: 0, statuses: {} };
    const sanitiserNote = JSON.stringify(
      rendered
        .filter((r) => r.button === 'S01' || r.button === 'S02' || r.button === 'S29')
        .slice(0, 3),
    );
    for (const c of cases) {
      if (
        !(await page
          .getByRole('button', { name: c.button, exact: true })
          .isVisible()
          .catch(() => false))
      )
        await openPreview();
      const mark = adapterLog.length;
      const responsePromise = page
        .waitForResponse((r) => r.request().method() === 'POST', { timeout: 10000 })
        .catch(() => null);
      await page.getByRole('button', { name: c.button, exact: true }).click();
      const response = await responsePromise;
      await sleep(150);
      const gatewayHits = adapterLog.slice(mark).filter((e) => e.method === 'POST');
      if (response) {
        const url = new URL(response.url());
        if (url.pathname.startsWith('/api/')) {
          post.toGateway++;
          post.statuses[response.status()] = (post.statuses[response.status()] ?? 0) + 1;
          if (response.status() < 400)
            results.add(
              `P1 ${c.button} ${c.target}/${c.enc}`,
              'fail',
              `reached the Gateway with ${response.status()}`,
            );
        } else post.other++;
      }
      void gatewayHits;
      await openPreview();
    }
    const afterPhase1 = await memorySnapshot(stack, seed, project);
    results.check(
      'P1 state unchanged after clicking every previewed form',
      JSON.stringify(afterPhase1) === JSON.stringify(before),
      `${cases.length} forms clicked; POSTs to /api: ${post.toGateway} ${JSON.stringify(post.statuses)}; to other URLs (page/receiver): ${post.other}; forms keeping an action: ${survivingActions}/${rendered.length}`,
    );
    results.add('P1 info: what the app rendered for S01/S02/S29', 'pass', sanitiserNote);

    // External receiver, as clicked through the preview.
    const got = receiver.received.filter((r) => r.method === 'POST');
    const find = (enc) => got.find((r) => r.contentType.toLowerCase().startsWith(enc));
    const urlenc = find('application/x-www-form-urlencoded');
    const multi = find('multipart/form-data');
    const plain = find('text/plain');
    results.check(
      'P1 external form (urlencoded): fields intact',
      urlenc &&
        new URLSearchParams(urlenc.body).get('a') === '1' &&
        new URLSearchParams(urlenc.body).get('b') === 'two words',
      urlenc
        ? urlenc.body
        : `received nothing (rendered action: ${JSON.stringify(externalRendered[0])})`,
    );
    results.check(
      'P1 external form (multipart): fields intact',
      multi &&
        /name="a"\r\n\r\n1\r\n/.test(multi.body) &&
        /name="b"\r\n\r\ntwo words\r\n/.test(multi.body),
      multi
        ? JSON.stringify(multi.body.slice(0, 200))
        : `received nothing (rendered action: ${JSON.stringify(externalRendered[1])})`,
    );
    results.check(
      'P1 external form (text/plain): fields intact',
      plain && plain.body === 'a=1\r\nb=two words\r\n',
      plain
        ? JSON.stringify(plain.body)
        : `received nothing (rendered action: ${JSON.stringify(externalRendered[2])})`,
    );

    // ---- Phase 2: the same forms as raw HTML on a same-origin page ----------
    const raw = { statuses: {}, codes: {}, reached: 0 };
    for (const c of cases.filter((x) => x.kind === 'state')) {
      await page.goto(`${adapter.url}/__e2e/raw.html`);
      const responsePromise = page
        .waitForResponse((r) => r.request().method() === 'POST', { timeout: 10000 })
        .catch(() => null);
      await page.getByRole('button', { name: c.button, exact: true }).click();
      const response = await responsePromise;
      if (!response) {
        results.add(`P2 ${c.button} ${c.target}/${c.enc}`, 'fail', 'no POST was made');
        continue;
      }
      raw.reached++;
      raw.statuses[response.status()] = (raw.statuses[response.status()] ?? 0) + 1;
      let code;
      try {
        code = (await response.json())?.error?.code;
      } catch {
        code = undefined;
      }
      raw.codes[code] = (raw.codes[code] ?? 0) + 1;
      if (response.status() !== 415 || code !== 'request_shape_required')
        results.add(
          `P2 ${c.button} ${c.target}/${c.enc}`,
          'fail',
          `status ${response.status()} code ${code}`,
        );
    }
    const afterPhase2 = await memorySnapshot(stack, seed, project);
    results.check(
      'P2 every raw form reached the Gateway and was refused 415 request_shape_required',
      raw.reached === cases.filter((x) => x.kind === 'state').length &&
        raw.statuses[415] === raw.reached &&
        raw.codes.request_shape_required === raw.reached,
      `POSTs: ${raw.reached}; statuses ${JSON.stringify(raw.statuses)}; codes ${JSON.stringify(raw.codes)}`,
    );
    results.check(
      'P2 state unchanged after the raw forms',
      JSON.stringify(afterPhase2) === JSON.stringify(before),
      JSON.stringify({
        proposals: afterPhase2.proposals,
        entries: afterPhase2.entries,
        sha: afterPhase2.projectFileSha256.slice(0, 12),
      }),
    );

    // ---- Controls: the same targets answer to a marked request --------------
    const c = stack.client;
    const approve = await c.call('POST', `/api/memory/proposals/${seed.pendingB}/approve`, {
      json: {},
    });
    const reject = await c.call('POST', `/api/memory/proposals/${seed.pendingC}/reject`, {
      json: {},
    });
    const forget = await c.call('POST', `/api/memory/entries/${seed.entry}/forget`, { json: {} });
    const write = await c.call('POST', project.route, {
      raw: 'REPLACED\n',
      contentType: 'text/plain',
    });
    results.check(
      'control: the same routes accept a marked request (so the refusals above are the request shape)',
      approve.status === 200 &&
        reject.status === 200 &&
        forget.status === 200 &&
        write.status === 201,
      `approve ${approve.status}, reject ${reject.status}, forget ${forget.status}, project write ${write.status}`,
    );
    const after = await memorySnapshot(stack, seed, project);
    results.check(
      'control: and they changed the state',
      !(seed.pendingB in after.proposals) &&
        !(seed.pendingC in after.proposals) &&
        after.userContents.includes('Prefers short answers.') &&
        !after.userContents.includes('Wants to be called Ice.') &&
        !String(after.entries[seed.entry]).startsWith('active') &&
        after.projectFileBytes === 'REPLACED\n',
      JSON.stringify({
        pending: after.proposals,
        user: after.userContents,
        entry: after.entries[seed.entry],
        file: after.projectFileBytes,
      }),
    );
  } finally {
    await browser?.context.close().catch(() => {});
    await adapter?.stop().catch(() => {});
    await web?.stop().catch(() => {});
    await receiver?.stop().catch(() => {});
    await stack?.stop().catch(() => {});
    await llm.stop().catch(() => {});
    removeDir(root);
    await stopAllProcesses();
  }
}

try {
  await main();
} catch (error) {
  results.add('V1 aborted', 'fail', String(error?.stack ?? error));
}
console.log(
  `V1: ${results.rows.length - results.failed.length} passed, ${results.failed.length} failed`,
);
process.exit(results.failed.length ? 1 : 0);
