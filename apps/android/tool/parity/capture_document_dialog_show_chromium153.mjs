import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';
import {
  dialogShowHTML,
  dialogShowCases,
  runDialogShowCase,
  readDialogShowState,
  readDialogShowVisualState,
} from './document_dialog_show_fixture.mjs';
const { chromium } = createRequire(import.meta.url)('playwright-core');
const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
});
try {
  assert.equal(browser.version(), '153.0.8010.12');
  const page = await browser.newPage(),
    requests = [],
    errors = [];
  await page.route('**/*', (r) => {
    requests.push(r.request().url());
    return r.fulfill({ contentType: 'text/html', body: dialogShowHTML });
  });
  page.on('pageerror', (e) => errors.push(e.message));
  const states = [];
  for (const row of dialogShowCases) {
    await page.goto('https://dialog-show.example/test');
    const synchronous = await page.evaluate(
      `(()=>{${runDialogShowCase(row)};return ${readDialogShowState};})()`,
    );
    await page.waitForTimeout(60);
    states.push({ name: row.name, synchronous, result: await page.evaluate(readDialogShowState) });
  }
  assert.deepEqual(errors, []);
  assert.equal(requests.length, dialogShowCases.length);
  assert.ok(requests.every((u) => u === 'https://dialog-show.example/test'));
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
            calls = [];
          p.on('pageerror', (e) => errors.push(e.message));
          await p.route('**/*', (r) => {
            calls.push(r.request().url());
            return r.fulfill({ contentType: 'text/html', body: dialogShowHTML });
          });
          await p.goto('https://dialog-show.example/test');
          const steps = [];
          async function capture(name) {
            await p.waitForTimeout(60);
            const value = await p.evaluate(readDialogShowVisualState);
            if (value.rect) {
              value.point = [value.rect[0] + 236, value.rect[1] + 124];
              const png = await p.screenshot();
              value.pixel = await p.evaluate(
                async ({ data, point, dpr }) => {
                  const bitmap = await createImageBitmap(
                    new Blob([Uint8Array.from(atob(data), (c) => c.charCodeAt(0))], {
                      type: 'image/png',
                    }),
                  );
                  const canvas = document.createElement('canvas');
                  canvas.width = bitmap.width;
                  canvas.height = bitmap.height;
                  const ctx = canvas.getContext('2d');
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
          await p.locator('#draft').fill('草稿🙂');
          await p.locator('#save').click();
          await capture('saved');
          await p.locator('#open').click();
          await capture('reopen');
          await p.locator('#outside').click();
          await capture('outside');
          await p.locator('#close').click();
          await capture('close-outside');
          await p.locator('#empty').click();
          await capture('empty');
          await p.locator('#close').click();
          await capture('close-empty');
          assert.deepEqual(calls, ['https://dialog-show.example/test']);
          profiles.push({ viewport, dpr, theme, steps });
        } finally {
          await context.close();
        }
      }
  assert.deepEqual(errors, []);
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-dialog-show-chromium153.json', import.meta.url),
    JSON.stringify(
      {
        browserVersion: browser.version(),
        html: dialogShowHTML,
        cases: dialogShowCases,
        states,
        profiles,
      },
      null,
      2,
    ) + '\n',
  );
  console.log(`${states.length} dialog opening/focus references captured`);
} finally {
  await browser.close();
}
