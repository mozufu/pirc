import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';
import { fragmentScenes, fragmentHTML } from './document_fragment_fixture.mjs';
const { chromium } = createRequire(import.meta.url)('playwright-core');
const browser = await chromium.launch({
  headless: true,
  executablePath: requireTestBrowserExecutable(),
});
const base = 'https://gateway.example/fragment';
async function open(context, url, html) {
  const page = await context.newPage(),
    requests = [];
  await page.route('**/*', (route) => {
    requests.push(route.request().url());
    return route.request().url() === base
      ? route.fulfill({ status: 200, contentType: 'text/html; charset=utf-8', body: html })
      : route.abort();
  });
  await page.goto(url);
  return { page, requests };
}
const settle = (page) =>
  page.evaluate(
    () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))),
  );
const read = (page) =>
  page.evaluate(() => ({
    root: scrollY,
    hash: location.hash,
    length: history.length,
    target: document.querySelector(':target')?.getAttribute('data-target') ?? null,
  }));
try {
  if (browser.version() !== '153.0.8010.12') throw Error(browser.version());
  const cases = [];
  for (const viewport of [
    { width: 390, height: 844 },
    { width: 768, height: 1024 },
  ])
    for (const dpr of [1, 3])
      for (const theme of ['light', 'dark']) {
        const context = await browser.newContext({
          viewport,
          deviceScaleFactor: dpr,
          colorScheme: theme,
        });
        try {
          for (const [mode, scene] of Object.entries(fragmentScenes)) {
            process.stdout.write(`Capture ${viewport.width}/${dpr}/${theme}/${mode}\n`);
            const html = fragmentHTML(mode),
              firstLoad = await open(context, base + scene.hash, html);
            await settle(firstLoad.page);
            const initial = await read(firstLoad.page);
            if (firstLoad.requests.length !== 1) throw Error(JSON.stringify(firstLoad.requests));
            await firstLoad.page.close();
            const { page, requests } = await open(context, base, html);
            await page.evaluate(() => scrollTo(0, 240));
            const before = await read(page);
            await page.locator('#jump').click();
            await settle(page);
            const first = await read(page);
            await page.evaluate(() => scrollTo(0, 480));
            await page.locator('#jump').click();
            await settle(page);
            const repeated = await read(page);
            if (requests.length !== 1) throw Error(JSON.stringify(requests));
            cases.push({
              mode,
              viewport,
              dpr,
              theme,
              html,
              hash: scene.hash,
              result: { initial, before, first, repeated, requestCount: requests.length },
            });
            await page.close();
          }
        } finally {
          await context.close();
        }
      }
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-fragment-chromium153.json', import.meta.url),
    JSON.stringify({ browserVersion: browser.version(), cases }) + '\n',
  );
  process.stdout.write(`Captured ${cases.length} fragment profiles\n`);
} finally {
  await browser.close();
}
