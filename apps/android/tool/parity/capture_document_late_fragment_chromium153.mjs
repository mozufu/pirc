import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';
import {
  lateFragmentModes,
  heldLateFragmentModes,
  lateFragmentHTML,
  lateFragmentResource,
} from './document_late_fragment_fixture.mjs';
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
          for (const mode of lateFragmentModes) {
            const page = await context.newPage(),
              html = lateFragmentHTML(mode),
              requests = [],
              errors = [];
            let release, requested;
            const gate = new Promise((r) => (release = r)),
              seen = new Promise((r) => (requested = r));
            await page.route('**/*', async (route) => {
              requests.push(route.request().url());
              if (route.request().url().endsWith('/late.js')) {
                requested();
                await gate;
                return route.fulfill({
                  contentType: 'text/javascript',
                  body: lateFragmentResource(),
                });
              }
              return route.fulfill({ contentType: 'text/html; charset=utf-8', body: html });
            });
            page.on('pageerror', (e) => errors.push(e.message));
            const navigating = page.goto(
              'https://gateway.example/late-fragment?mode=' + mode + '#target',
              { waitUntil: 'load' },
            );
            if (heldLateFragmentModes.has(mode)) {
              await seen;
              if (mode === 'async') await page.waitForLoadState('domcontentloaded');
            } else await navigating;
            const settle = () =>
              page.evaluate(
                () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))),
              );
            await settle();
            if (mode === 'parser-scroll') {
              await page.mouse.move(120, 300);
              await page.mouse.wheel(0, 240);
              await page.waitForTimeout(150);
            }
            const read = async () => ({
              top: await page.evaluate(() => scrollY),
              ...(await page.evaluate(() => window.readLateTarget())),
            });
            const before = await read();
            release();
            await navigating;
            await settle();
            const loaded = await read();
            await page.locator('#shift').click();
            await settle();
            const shifted = await read();
            if (errors.length || requests.length !== (heldLateFragmentModes.has(mode) ? 2 : 1))
              throw Error(JSON.stringify({ mode, errors, requests }));
            cases.push({
              mode,
              html,
              resource: lateFragmentResource(),
              screen,
              viewport,
              dpr,
              theme,
              result: { before, loaded, shifted },
            });
            await page.close();
          }
          console.log('Captured', cases.length);
        } finally {
          await context.close();
        }
      }
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-late-fragment-chromium153.json', import.meta.url),
    JSON.stringify({ browserVersion: browser.version(), cases }) + '\n',
  );
} finally {
  await browser.close();
}
