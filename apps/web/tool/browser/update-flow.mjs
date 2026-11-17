// node apps/web/tool/browser/update-flow.mjs
//
// Real-browser check of how an open page learns about a new release and how the
// service worker's shell is replaced. Two real builds (A, then B with a changed
// bundle) are served in turn from one origin, like a deployment being replaced:
//   1. page loads build A, its service worker installs and controls the page;
//   2. the server now serves build B; the page's periodic update check runs;
//   3. the page offers "Update ready"; clicking Update reloads it into build B
//      and the worker's cached shell is B's.
// Control: the same replacement where sw.js is byte-identical (a build that does not
// stamp it) is NOT noticed by the open page.
import assert from 'node:assert/strict';
import { cp, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import http from 'node:http';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { freePort, launchTestBrowser, webRoot } from './harness.mjs';

const { build } = await import(pathToFileURL(path.join(webRoot, 'node_modules/vite/dist/node/index.js')));
const base = await mkdtemp(path.join(tmpdir(), 'pirc-update-flow-'));
const dir = { a: path.join(base, 'a'), b: path.join(base, 'b'), same: path.join(base, 'same') };
await build({ root: webRoot, logLevel: 'error', build: { outDir: dir.a, emptyOutDir: true } });
await build({
  root: webRoot,
  logLevel: 'error',
  build: { outDir: dir.b, emptyOutDir: true },
  plugins: [
    {
      // A changed source file: the entry chunk (and its hashed name) differs in release B.
      name: 'release-b',
      transform: (code, id) =>
        id.endsWith('/src/main.ts') ? `${code}\nconsole.debug('release B');\n` : null,
    },
  ],
});
// The same release B, but with the worker file of build A: what a build that leaves sw.js alone looks like.
await cp(dir.b, dir.same, { recursive: true });
await writeFile(path.join(dir.same, 'sw.js'), await readFile(path.join(dir.a, 'sw.js')));

const swId = async (d) => /BUILD_ID = '([0-9a-f]{16})'/.exec(await readFile(path.join(d, 'sw.js'), 'utf8'))?.[1];
const entryOf = async (d) => /src="\/assets\/(index-[^"]+\.js)"/.exec(await readFile(path.join(d, 'index.html'), 'utf8'))?.[1];
const [idA, idB] = [await swId(dir.a), await swId(dir.b)];
assert.ok(idA && idB && idA !== idB, `sw.js build identifiers: ${idA} / ${idB}`);
assert.ok(!(await readFile(path.join(dir.a, 'sw.js'), 'utf8')).includes('__PIRC_BUILD_ID__'));
console.log(`build A: sw id ${idA}, entry ${await entryOf(dir.a)}`);
console.log(`build B: sw id ${idB}, entry ${await entryOf(dir.b)}`);

let current = dir.a;
const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.webmanifest': 'application/manifest+json' };
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x.invalid');
  if (url.pathname.startsWith('/api/')) {
    res.writeHead(503, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: { code: 'unavailable', message: 'no gateway in this check' } }));
    return;
  }
  let file = path.join(current, decodeURIComponent(url.pathname));
  if (!existsSync(file) || file === current + path.sep) file = path.join(current, 'index.html');
  try {
    const body = await readFile(file);
    res.writeHead(200, { 'content-type': types[path.extname(file)] ?? 'application/octet-stream', 'cache-control': 'no-cache' });
    res.end(body);
  } catch {
    res.writeHead(404);
    res.end();
  }
});
const port = await freePort();
await new Promise((resolve) => server.listen(port, '127.0.0.1', resolve));
const origin = `http://127.0.0.1:${port}`;

const browser = await launchTestBrowser();
console.log(`browser: ${browser.executablePath} (${browser.version})`);
const results = [];
const check = (id, ok, detail = '') => {
  results.push({ id, ok });
  console.log(`  [${ok ? 'pass' : 'FAIL'}] ${id}${detail ? ' -- ' + detail : ''}`);
};

/** Open the app on build A with its worker controlling the page. */
async function openControlled(context = browser.context) {
  current = dir.a;
  const page = await context.newPage();
  await page.goto(origin + '/');
  await page.evaluate(() => navigator.serviceWorker.ready.then(() => true));
  await page.reload();
  await page.waitForFunction(() => !!navigator.serviceWorker.controller);
  return page;
}
const shellEntry = (page) =>
  page.evaluate(async () => {
    const cache = await caches.open('relay-shell-v1');
    const response = await cache.match('/');
    return response ? /src="\/assets\/(index-[^"]+\.js)"/.exec(await response.text())?.[1] : null;
  });
const workerId = (page) =>
  page.evaluate(async () => /BUILD_ID = '([0-9a-f]{16})'/.exec(await (await fetch('/sw.js', { cache: 'no-store' })).text())?.[1]);

try {
  // 1-3: the stamped worker.
  let page = await openControlled();
  check('A: the page is controlled by build A\'s worker and its cached shell is build A\'s', (await shellEntry(page)) === (await entryOf(dir.a)), String(await shellEntry(page)));
  current = dir.b; // the deployment is replaced
  await page.evaluate(() => navigator.serviceWorker.getRegistration().then((r) => r.update()));
  await page.locator('.update-toast', { hasText: 'Update ready' }).waitFor({ timeout: 15000 });
  check('B deployed: the open page offers "Update ready" after its update check', true);
  check('the page is still build A until the user acts', (await page.evaluate(() => document.querySelector('script[src*="/assets/index-"]')?.getAttribute('src'))) === `/assets/${await entryOf(dir.a)}`);
  await Promise.all([
    page.waitForEvent('load'),
    page.locator('.update-toast button', { hasText: 'Update' }).first().click(),
  ]);
  await page.waitForFunction(() => !!navigator.serviceWorker.controller);
  const loaded = await page.evaluate(() => document.querySelector('script[src*="/assets/index-"]')?.getAttribute('src'));
  check('after Update the page runs build B', loaded === `/assets/${await entryOf(dir.b)}`, loaded);
  check('the worker file now served and active is build B\'s', (await workerId(page)) === idB);
  // The shell cache is rewritten from the network on the visit.
  await page.waitForFunction(async (entry) => {
    const cache = await caches.open('relay-shell-v1');
    const response = await cache.match('/');
    return !!response && (await response.text()).includes(entry);
  }, await entryOf(dir.b));
  check('the cached shell is build B\'s (an offline start uses the new shell)', (await shellEntry(page)) === (await entryOf(dir.b)));
  await page.close();

  // Control, in a fresh profile: a release whose sw.js bytes did not change is not noticed.
  const fresh = await launchTestBrowser();
  try {
    page = await openControlled(fresh.context);
    current = dir.same;
    await page.evaluate(() => navigator.serviceWorker.getRegistration().then((r) => r.update()));
    await page.waitForTimeout(2500);
    check('control: with an unchanged sw.js the open page sees no update', (await page.locator('.update-toast').count()) === 0);
  } finally {
    await fresh.close();
  }
} finally {
  await browser.close();
  server.close();
  await rm(base, { recursive: true, force: true });
}
const failed = results.filter((r) => !r.ok);
console.log(`\n${results.length} checks, ${failed.length} failed`);
process.exit(failed.length ? 1 : 0);
