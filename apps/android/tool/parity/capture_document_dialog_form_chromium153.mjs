import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';
import {
  dialogFormHTML,
  dialogFormActions,
  readDialogFormState,
  readDialogFormVisualState,
} from './document_dialog_form_fixture.mjs';
const { chromium } = createRequire(import.meta.url)('playwright-core');
const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
});
try {
  assert.equal(browser.version(), '153.0.8010.12');
  const page = await browser.newPage();
  const requests = [],
    errors = [];
  await page.route('**/*', (r) => {
    requests.push(r.request().url());
    return r.fulfill({ contentType: 'text/html', body: dialogFormHTML });
  });
  page.on('pageerror', (e) => errors.push(e.message));
  await page.goto('https://dialog.example/test');
  const states = [];
  let closed = 0;
  for (const action of dialogFormActions) {
    if (action.script) await page.evaluate(`(()=>{${action.script}})()`);
    if (
      [
        'accept',
        'skip-validation',
        'request-no-submitter',
        'direct-submit',
        'external-submitter',
        'close-manually',
        'close-undefined',
        'property-handler',
        'empty-return',
      ].includes(action.name)
    ) {
      closed++;
      await page.waitForFunction((count) => window.closedCount >= count, closed);
    }
    for (let i = 0; i < 3; i++) await page.evaluate(() => new Promise((r) => setTimeout(r, 0)));
    states.push({ name: action.name, result: await page.evaluate(readDialogFormState) });
  }
  assert.deepEqual(errors, []);
  assert.deepEqual(requests, ['https://dialog.example/test']);
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
          const p = await context.newPage(),
            calls = [];
          await p.route('**/*', (r) => {
            calls.push(r.request().url());
            return r.fulfill({ contentType: 'text/html', body: dialogFormHTML });
          });
          await p.goto('https://dialog.example/test');
          const steps = [];
          async function capture(name) {
            const value = await p.evaluate(readDialogFormVisualState);
            if (value.rect) {
              value.point = [value.rect[0] + 176, value.rect[1] + 92];
              const png = await p.screenshot();
              value.pixel = await p.evaluate(
                async ({ data, point, dpr }) => {
                  const bitmap = await createImageBitmap(
                    new Blob([Uint8Array.from(atob(data), (c) => c.charCodeAt(0))], {
                      type: 'image/png',
                    }),
                  );
                  const c = document.createElement('canvas');
                  c.width = bitmap.width;
                  c.height = bitmap.height;
                  const ctx = c.getContext('2d');
                  ctx.drawImage(bitmap, 0, 0);
                  bitmap.close();
                  return Array.from(
                    ctx.getImageData(Math.floor(point[0] * dpr), Math.floor(point[1] * dpr), 1, 1)
                      .data,
                  );
                },
                { data: png.toString('base64'), point: value.point, dpr },
              );
            }
            steps.push({ name, value });
          }
          await capture('initial');
          await p.locator('#open').click();
          await capture('open');
          await p.locator('#required').fill('草稿🙂');
          await p.locator('#yes').click();
          await p.waitForFunction(() => closedCount === 1);
          await capture('accepted');
          await p.locator('#open').click();
          await p.locator('#required').fill('');
          await p.locator('#yes').click();
          await capture('invalid');
          await p.locator('#skip').click();
          await p.waitForFunction(() => closedCount === 2);
          await capture('skip');
          await p.locator('#open').click();
          await p.locator('#required').fill('final');
          await p.locator('#external').click();
          await p.waitForFunction(() => closedCount === 3);
          await capture('external');
          assert.deepEqual(calls, ['https://dialog.example/test']);
          cases.push({ viewport, dpr, theme, steps });
        } finally {
          await context.close();
        }
      }
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-dialog-form-chromium153.json', import.meta.url),
    JSON.stringify(
      {
        browserVersion: browser.version(),
        html: dialogFormHTML,
        actions: dialogFormActions,
        states,
        cases,
      },
      null,
      2,
    ) + '\n',
  );
  console.log(`${states.length} independent Chromium dialog/form states captured`);
} finally {
  await browser.close();
}
