import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';
import { initialHistoryCases, initialHistoryHTML } from './document_initial_history_fixture.mjs';
const { chromium } = createRequire(import.meta.url)('playwright-core');
const browser = await chromium.launch({
  headless: true,
  executablePath: requireTestBrowserExecutable(),
});
try {
  if (browser.version() !== '153.0.8010.12') throw Error(browser.version());
  const cases = [];
  for (const screen of [
    { width: 390, height: 844 },
    { width: 768, height: 1024 },
  ])
    for (const dpr of [1, 3])
      for (const theme of ['light', 'dark']) {
        const viewport = { width: screen.width, height: screen.height - 48 },
          context = await browser.newContext({
            viewport,
            deviceScaleFactor: dpr,
            colorScheme: theme,
          });
        try {
          for (const spec of initialHistoryCases) {
            const page = await context.newPage(),
              html = initialHistoryHTML(spec),
              requests = [],
              errors = [];
            await page.route('**/*', (route) => {
              requests.push(route.request().url());
              return route.fulfill({ contentType: 'text/html; charset=utf-8', body: html });
            });
            page.on('pageerror', (e) => errors.push(e.message));
            await page.goto(
              'https://gateway.example/initial-history?case=' + spec.id + spec.initialHash,
            );
            const settle = () =>
              page.evaluate(
                () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))),
              );
            const read = () =>
              page.evaluate(() => ({ top: scrollY, ...window.readInitialHistory() }));
            await settle();
            const loaded = await read();
            await page.locator('#rewrite').click();
            await settle();
            const rewritten = await read();
            let back = null,
              forward = null;
            if (loaded.growth > 0) {
              await page.goBack();
              await settle();
              back = await read();
              await page.goForward();
              await settle();
              forward = await read();
            }

            if (requests.length !== 1 || errors.length)
              throw Error(JSON.stringify({ spec, requests, errors }));
            cases.push({
              spec,
              html,
              screen,
              viewport,
              dpr,
              theme,
              result: { loaded, rewritten, back, forward },
            });
            await page.close();
          }
          console.log('Captured', cases.length);
        } finally {
          await context.close();
        }
      }
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-initial-history-chromium153.json', import.meta.url),
    JSON.stringify({ browserVersion: browser.version(), cases }) + '\n',
  );
} finally {
  await browser.close();
}
