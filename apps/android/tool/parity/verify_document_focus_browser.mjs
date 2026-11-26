import { requireTestBrowserExecutable } from './test_browser.mjs';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {createServer} from 'node:http';
import {existsSync, readFileSync} from 'node:fs';
import {mkdir, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';

const scriptPath = fileURLToPath(import.meta.url);
const scriptDirectory = path.dirname(scriptPath);
const repositoryRoot = path.resolve(scriptDirectory, '../../../..');
const require = createRequire(import.meta.url);
const {chromium} = require(require.resolve('playwright-core', {
  paths: [path.join(repositoryRoot, 'apps/gateway')],
}));
const fixturePath = path.join(
  repositoryRoot,
  'apps/android/integration_test/document_focus_fixture.dart',
);
const fixtureSource = readFileSync(fixturePath, 'utf8');
const fixtureMatch = fixtureSource.match(
  /const documentFocusFixture\s*=\s*r'''([\s\S]*?)''';/,
);
assert.ok(fixtureMatch, 'Could not extract documentFocusFixture.');
const fixtureHtml = fixtureMatch[1];
const sha256 = source => createHash('sha256').update(source).digest('hex');
const fixtureSha256 = sha256(fixtureSource);
const runnerSha256 = sha256(readFileSync(scriptPath));
const fixturePathOut = path.join(
  repositoryRoot,
  'packages/pirc_render/test/fixtures/parity/document-focus-chrome155.json',
);
const browserExecutable = [
  requireTestBrowserExecutable(),
  chromium.executablePath(),
].find(existsSync);
assert.ok(browserExecutable, 'No local Chrome or Chromium executable was found.');

const caseIds = [
  'input-focus-blur',
  'textarea-focus-blur',
  'select-focus-blur',
  'button-focus-blur',
  'checkbox-focus-blur',
  'range-focus-blur',
  'file-focus-blur',
  'same-element-repeat',
  'focus-switch',
  'listener-snapshot',
  'focus-event-flags',
  'focus-prevent-default',
  'blur-prevent-default',
  'disabled-property',
  'disabled-fieldset',
  'disabled-first-legend',
  'hidden-attribute',
  'display-none-ancestor',
  'visibility-hidden',
  'readonly-input',
  'detached-element',
  'plain-div',
  'tabindex-negative',
  'link-href',
  'blur-nonactive',
  'focus-prevent-scroll',
  'reentrant-blur-handler-focus',
  'reentrant-focus-handler-redirect',
  'dirty-user-edit-script-focus',
];
const requests = [];
const unexpectedLocalRequests = [];
const blockedExternalRequests = [];
let origin = '';
const server = createServer((request, response) => {
  const url = new URL(request.url ?? '/', origin || 'http://127.0.0.1');
  requests.push({method: request.method ?? '', path: url.pathname, query: url.search});
  if (request.method === 'GET' && url.pathname === '/fixture') {
    response.writeHead(200, {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
    });
    response.end(fixtureHtml);
    return;
  }
  if (request.method === 'GET' && url.pathname === '/favicon.ico') {
    response.writeHead(204);
    response.end();
    return;
  }
  unexpectedLocalRequests.push({method: request.method ?? '', path: url.pathname});
  response.writeHead(404, {'content-type': 'text/plain; charset=utf-8'});
  response.end('unexpected local request');
});

await new Promise((resolve, reject) => {
  server.once('error', reject);
  server.listen(0, '127.0.0.1', resolve);
});
const address = server.address();
assert.ok(address && typeof address === 'object');
origin = 'http://127.0.0.1:' + address.port;
const browser = await chromium.launch({
  headless: true,
  executablePath: browserExecutable,
  args: ['--disable-gpu'],
});

async function guard(context) {
  await context.route('**/*', async route => {
    const url = new URL(route.request().url());
    if (url.protocol === 'http:' && url.port === String(address.port) &&
        (url.hostname === '127.0.0.1' || url.hostname === 'localhost')) {
      await route.continue();
    } else {
      blockedExternalRequests.push(url.href);
      await route.abort();
    }
  });
}

async function readResult(page) {
  if (page.isClosed()) return null;
  try {
    return await page.evaluate(() => window.documentFocusResult ?? null);
  } catch (_) {
    return null;
  }
}

async function runCase(caseId) {
  const requestStart = requests.length;
  const context = await browser.newContext({viewport: {width: 1280, height: 720}});
  await guard(context);
  const page = await context.newPage();
  const pageErrors = [];
  page.on('pageerror', error => pageErrors.push(error.message));
  try {
    await page.goto(origin + '/fixture?case=' + encodeURIComponent(caseId), {
      waitUntil: 'domcontentloaded',
    });
    const initialCapture = await page.evaluate(id =>
      window.prepareDocumentFocusCase(id), caseId);
    const beforeInvocation = await page.evaluate(() => window.documentFocusResult);
    if (caseId === 'dirty-user-edit-script-focus') {
      await page.evaluate(() => window.beginDocumentFocusUserEdit());
      await page.keyboard.type('x');
    }
    await page.locator('[data-case="' + caseId + '"]').click();
    await page.waitForFunction(id => {
      const result = window.documentFocusResult;
      return result && result.caseId === id && result.status === 'DONE';
    }, caseId, {timeout: 3000});
    const fixtureResult = await readResult(page);
    return {
      caseId,
      invocation: 'trusted-visible-button',
      initialCapture,
      beforeInvocation,
      fixtureResult,
      requests: requests.slice(requestStart),
      pageErrors,
    };
  } finally {
    await context.close();
  }
}

try {
  assert.ok(browser.version().startsWith('155.'),
    'Expected local Chrome 155; got ' + browser.version());
  const cases = [];
  for (const caseId of caseIds) cases.push(await runCase(caseId));
  const byId = Object.fromEntries(cases.map(item => [item.caseId, item]));

  assert.equal(cases.length, 29);
  assert.deepEqual(cases.map(item => item.caseId), caseIds);
  assert.deepEqual(unexpectedLocalRequests, []);
  assert.deepEqual(blockedExternalRequests, []);
  assert.deepEqual(cases.flatMap(item => item.pageErrors), []);
  assert.ok(cases.every(item => item.fixtureResult?.status === 'DONE'));
  assert.ok(cases.every(item => item.initialCapture?.activeElement?.id ===
    (item.caseId === 'dirty-user-edit-script-focus' ? 'target' : 'origin')));
  assert.ok(cases.every(item => item.beforeInvocation?.activeElement?.id ===
    (item.caseId === 'dirty-user-edit-script-focus' ? 'target' : 'origin')),
  'The visible case-button click should not steal focus before invoking the case.');

  const uniqueEvents = events => Array.from(new Map(
    events.map(event => [event.dispatchId, event]),
  ).values());
  const order = caseId => uniqueEvents(byId[caseId].fixtureResult.events)
    .map(event => event.type + ':' + event.targetId);
  assert.deepEqual(order('input-focus-blur'), [
    'blur:origin', 'focusout:origin', 'focus:target', 'focusin:target',
    'blur:target', 'focusout:target',
  ]);
  assert.deepEqual(order('same-element-repeat'), [
    'blur:origin', 'focusout:origin', 'focus:target', 'focusin:target',
    'blur:target', 'focusout:target',
  ], 'A repeated focus() on the active target must not add another focus dispatch.');
  assert.deepEqual(order('reentrant-blur-handler-focus'), [
    'blur:origin', 'focus:redirect', 'focusin:redirect', 'focusout:origin',
  ]);
  assert.deepEqual(order('reentrant-focus-handler-redirect'), [
    'blur:origin', 'focusout:origin', 'focus:target', 'blur:target',
    'focusout:target', 'focus:redirect', 'focusin:redirect',
  ]);
  assert.equal(byId['disabled-first-legend'].fixtureResult.target.focused, true);
  assert.equal(byId['readonly-input'].fixtureResult.target.focused, true);
  assert.equal(byId['tabindex-negative'].fixtureResult.target.focused, true);
  assert.equal(byId['link-href'].fixtureResult.target.focused, true);
  assert.equal(byId['focus-prevent-default'].fixtureResult.preventDefaultSeen.defaultPrevented, false);
  assert.equal(byId['focus-prevent-default'].fixtureResult.operations[0].activeElement.id, 'target');
  assert.equal(byId['blur-prevent-default'].fixtureResult.preventDefaultSeen.defaultPrevented, false);
  assert.equal(byId['focus-prevent-scroll'].fixtureResult.activeElement.id, 'target');
  assert.equal(byId['focus-prevent-scroll'].fixtureResult.operations.at(-1).scroll.y, 0);
  assert.equal(byId['blur-nonactive'].fixtureResult.activeElement.id, 'origin');
  for (const caseId of ['disabled-property', 'disabled-fieldset', 'hidden-attribute',
    'display-none-ancestor', 'visibility-hidden', 'detached-element', 'plain-div']) {
    assert.equal(byId[caseId].fixtureResult.activeElement.id, 'origin', caseId);
    assert.equal(byId[caseId].fixtureResult.events.length, 0, caseId);
  }
  const dirtyEvents = byId['dirty-user-edit-script-focus'].fixtureResult.events;
  const dirtyInputIndex = dirtyEvents.findIndex(event => event.type === 'input');
  const dirtyBlurIndex = dirtyEvents.findIndex(event => event.type === 'blur' && event.targetId === 'target');
  assert.ok(dirtyInputIndex >= 0 && dirtyBlurIndex > dirtyInputIndex,
    'The trusted user edit should be observed before the script-driven blur.');
  assert.equal(dirtyEvents[dirtyInputIndex].isTrusted, true);

  const evidence = {
    browserVersion: browser.version(),
    browserExecutable,
    checkedAt: new Date().toISOString(),
    oracle: 'Local Google Chrome over a loopback-only page served from 127.0.0.1',
    fixture: 'apps/android/integration_test/document_focus_fixture.dart#documentFocusFixture',
    fixtureSha256,
    runner: 'apps/android/tool/parity/verify_document_focus_browser.mjs',
    runnerSha256,
    loopbackOrigin: origin,
    invocation: 'A visible per-case button is clicked after page.evaluate records initial focus. Its mousedown default is canceled so the trigger does not change activeElement.',
    cases,
    requests,
    unexpectedLocalRequests,
    blockedExternalRequests,
    knownDifferences: [
      'The dirty-edit case uses Playwright keyboard.type to send real key input through Chrome; the resulting trusted input event is followed by the fixture script calling focus() on the redirect field.',
      'Computed styles are not queried; the fixture records hidden, authored inline display, and authored inline visibility so the shared HTML can be consumed by the runtime host.',
    ],
  };
  await mkdir(path.dirname(fixturePathOut), {recursive: true});
  await writeFile(fixturePathOut, JSON.stringify(evidence, null, 2) + '\n');
  process.stdout.write(JSON.stringify({
    browserVersion: browser.version(),
    caseCount: cases.length,
    fixturePath: fixturePathOut,
    fixtureSha256,
    runnerSha256,
    cases: cases.map(item => ({
      caseId: item.caseId,
      initialActive: item.initialCapture.activeElement.id,
      beforeInvocationActive: item.beforeInvocation.activeElement.id,
      finalActive: item.fixtureResult.activeElement.id,
      targetFocused: item.fixtureResult.target.focused,
      eventDispatchCount: uniqueEvents(item.fixtureResult.events).length,
      handlerActions: item.fixtureResult.handlerActions,
    })),
  }, null, 2) + '\n');
} finally {
  await browser.close();
  await new Promise(resolve => server.close(resolve));
}
