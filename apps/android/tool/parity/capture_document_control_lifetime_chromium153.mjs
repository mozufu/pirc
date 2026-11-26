import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';
import {
  controlLifetimeHTML,
  editedControlValues,
  readControlLifetimeState,
} from './document_control_lifetime_fixture.mjs';
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
          }),
          page = await context.newPage(),
          errors = [],
          requests = [];
        try {
          page.on('pageerror', (e) => errors.push(e.message));
          await context.route('**/*', (r) => {
            requests.push(r.request().url());
            return r.fulfill({ contentType: 'text/html', body: controlLifetimeHTML });
          });
          await page.goto('https://controls.example/lifetime');
          const initial = await page.evaluate(readControlLifetimeState);
          for (const id of ['text', 'off', 'password', 'notes', 'date'])
            await page.locator('#' + id).fill(editedControlValues[id]);
          await page.locator('#check').check();
          await page.locator('#radioB').check();
          await page.locator('#select').selectOption('b');
          await page.locator('#range').evaluate((e) => (e.value = '73'));
          await page
            .locator('#file')
            .setInputFiles({
              name: 'fixture.bin',
              mimeType: 'application/octet-stream',
              buffer: Buffer.from([0, 127, 128, 255]),
            });
          await page.locator('#text').evaluate((e) => e.setSelectionRange(1, 4));
          const edited = await page.evaluate(readControlLifetimeState);
          // The browsing context and DOM stay alive while their embedding UI hides
          // them, matching a retained native document whose Flutter view is removed.
          await page.evaluate(() => (document.documentElement.style.display = 'none'));
          await page.setViewportSize({ width: viewport.width - 40, height: viewport.height - 80 });
          await page.evaluate(() => (document.documentElement.style.display = ''));
          await page.setViewportSize(viewport);
          const resumed = await page.evaluate(readControlLifetimeState);
          assert.deepEqual(resumed, edited);
          await page.locator('button').click();
          const reset = await page.evaluate(readControlLifetimeState);
          const fresh = await context.newPage();
          await fresh.goto('https://controls.example/lifetime');
          const freshState = await fresh.evaluate(readControlLifetimeState);
          await fresh.close();
          assert.deepEqual(errors, []);
          assert.deepEqual(requests, [
            'https://controls.example/lifetime',
            'https://controls.example/lifetime',
          ]);
          cases.push({ viewport, dpr, theme, initial, edited, resumed, reset, fresh: freshState });
        } finally {
          await context.close();
        }
      }
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-control-lifetime-chromium153.json', import.meta.url),
    JSON.stringify(
      {
        browserVersion: browser.version(),
        html: controlLifetimeHTML,
        editedValues: editedControlValues,
        cases,
      },
      null,
      2,
    ) + '\n',
  );
  console.log(`${cases.length} retained-control environments captured`);
} finally {
  await browser.close();
}
