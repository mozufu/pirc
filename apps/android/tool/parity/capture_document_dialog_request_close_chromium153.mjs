import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';
import {
  dialogRequestHTML,
  dialogRequestCases,
  runDialogRequestCase,
  readDialogRequestState,
  readDialogRequestVisualState,
} from './document_dialog_request_close_fixture.mjs';
const { chromium } = createRequire(import.meta.url)('playwright-core');
const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
});
try {
  assert.equal(browser.version(), '153.0.8010.12');
  const errors = [],
    states = [];
  const page = await browser.newPage();
  const calls = [];
  await page.route('**/*', (r) => {
    calls.push(r.request().url());
    return r.fulfill({ contentType: 'text/html', body: dialogRequestHTML });
  });
  page.on('pageerror', (e) => errors.push(e.message));
  for (const row of dialogRequestCases) {
    await page.goto('https://dialog-request.example/test');
    const synchronous = await page.evaluate(
      `(()=>{${runDialogRequestCase(row)};return ${readDialogRequestState}})()`,
    );
    await page.waitForTimeout(60);
    states.push({
      name: row.name,
      synchronous,
      result: await page.evaluate(readDialogRequestState),
    });
  }
  assert.equal(calls.length, dialogRequestCases.length);
  assert.ok(calls.every((u) => u === 'https://dialog-request.example/test'));
  const profiles = [];
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
          const p = await context.newPage(),
            requests = [];
          p.on('pageerror', (e) => errors.push(e.message));
          await p.route('**/*', (r) => {
            requests.push(r.request().url());
            return r.fulfill({ contentType: 'text/html', body: dialogRequestHTML });
          });
          await p.goto('https://dialog-request.example/test');
          const steps = [];
          async function capture(name) {
            await p.waitForTimeout(60);
            steps.push({ name, value: await p.evaluate(readDialogRequestVisualState) });
          }
          await capture('initial');
          await p.locator('#open').click();
          await capture('open');
          await p.locator('#draft').fill('草稿🙂');
          await p.locator('#request').click();
          await capture('blocked');
          await p.locator('#allow').click();
          await capture('allowed');
          await p.locator('#request').click();
          await capture('closed');
          await p.locator('#open').click();
          await capture('reopen');
          await p.locator('#force').click();
          await capture('forced');
          assert.deepEqual(requests, ['https://dialog-request.example/test']);
          profiles.push({ viewport, dpr, theme, steps });
        } finally {
          await context.close();
        }
      }
  assert.deepEqual(errors, []);
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-dialog-request-close-chromium153.json', import.meta.url),
    JSON.stringify({
      browserVersion: browser.version(),
      html: dialogRequestHTML,
      cases: dialogRequestCases,
      states,
      profiles,
    }) + '\n',
  );
  console.log(
    `${states.length} close-request cases and ${profiles.length} native interaction reference profiles captured`,
  );
} finally {
  await browser.close();
}
