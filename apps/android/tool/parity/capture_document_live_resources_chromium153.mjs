import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';
import {
  liveResourceHTML,
  liveResourcePayload,
  liveResourceExtraScript,
  readLiveResourceState,
} from './document_live_resource_fixture.mjs';
const { chromium } = createRequire(import.meta.url)('playwright-core');
const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
});
try {
  assert.equal(browser.version(), '153.0.8010.12');
  const cases = [];
  for (const viewport of [
    { width: 390, height: 796 },
    { width: 768, height: 976 },
  ])
    for (const dpr of [1, 3])
      for (const theme of ['light', 'dark']) {
        const context = await browser.newContext({
          viewport,
          deviceScaleFactor: dpr,
          colorScheme: theme,
        });
        try {
          const waiting = [],
            requests = [],
            errors = [];
          await context.route('**/*', (route) => {
            const url = new URL(route.request().url());
            requests.push(url.pathname);
            if (url.pathname === '/payload' || url.pathname === '/extra.js') {
              waiting.push(route);
              return;
            }
            return route.fulfill({ contentType: 'text/html', body: liveResourceHTML });
          });
          const page = await context.newPage();
          page.on('pageerror', (e) => errors.push(e.message));
          await page.goto('https://resources.example/test');
          const initial = await page.evaluate(readLiveResourceState);
          await page.locator('#load').click();
          await page.waitForFunction(() => probe.phase === 'loading');
          const loading = await page.evaluate(readLiveResourceState);
          await page.evaluate(() => (document.documentElement.style.display = 'none'));
          assert.equal(waiting.length, 1);
          await waiting[0].fulfill({
            contentType: 'application/json',
            body: JSON.stringify(liveResourcePayload),
          });
          await page.waitForFunction(() => probe.phase === 'loaded');
          await page.evaluate(() => (document.documentElement.style.display = ''));
          const resumed = await page.evaluate(readLiveResourceState);
          await page.locator('#extra').click();
          await page.waitForFunction(() => document.querySelector('script[src]') != null);
          for (let attempt = 0; attempt < 10000 && waiting.length < 2; attempt++) {
            await new Promise((resolve) => setTimeout(resolve, 1));
          }
          assert.equal(waiting.length, 2, 'external script request');
          await waiting[1].fulfill({
            contentType: 'application/javascript',
            body: liveResourceExtraScript,
          });
          await page.waitForFunction(() => probe.phase === 'extended');
          const extended = await page.evaluate(readLiveResourceState);
          await page.locator('#load').click();
          await page.waitForFunction(() => probe.phase === 'loading');
          await page.locator('#abort').click();
          await page.waitForFunction(() => probe.phase === 'cancelled');
          const cancelled = await page.evaluate(readLiveResourceState);
          assert.equal(resumed.probe.boots, 1);
          assert.equal(waiting.length, 3);
          assert.deepEqual(errors, []);
          assert.deepEqual(requests, ['/test', '/payload', '/extra.js', '/payload']);
          cases.push({ viewport, dpr, theme, initial, loading, resumed, extended, cancelled });
        } finally {
          await context.close();
        }
      }
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-live-resources-chromium153.json', import.meta.url),
    JSON.stringify(
      {
        browserVersion: browser.version(),
        html: liveResourceHTML,
        payload: liveResourcePayload,
        extraScript: liveResourceExtraScript,
        cases,
      },
      null,
      2,
    ) + '\n',
  );
  console.log(`${cases.length} live resource environments captured`);
} finally {
  await browser.close();
}
