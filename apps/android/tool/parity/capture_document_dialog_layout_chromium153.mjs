import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';
import { dialogLayoutHTML, readDialogLayout } from './document_dialog_layout_fixture.mjs';
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
          const p = await context.newPage(),
            requests = [],
            errors = [];
          await p.route('**/*', (r) => {
            requests.push(r.request().url());
            return r.fulfill({ contentType: 'text/html', body: dialogLayoutHTML });
          });
          p.on('pageerror', (e) => errors.push(e.message));
          await p.goto('https://dialog-layout.example/test');
          const steps = [];
          async function capture(name) {
            await p.waitForTimeout(30);
            const value = await p.evaluate(readDialogLayout);
            if (value.rect) {
              value.points = [
                [1, 1],
                [8, 8],
                [130, 50],
              ].map(([x, y]) => [x + value.rect[0], y + value.rect[1]]);
              const png = await p.screenshot();
              value.pixels = await p.evaluate(
                async ({ data, points, dpr }) => {
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
                  return points.map(([x, y]) =>
                    Array.from(
                      ctx.getImageData(Math.floor(x * dpr), Math.floor(y * dpr), 1, 1).data,
                    ),
                  );
                },
                { data: png.toString('base64'), points: value.points, dpr },
              );
            }
            steps.push({ name, value });
          }
          await capture('closed');
          await p.locator('#open').click();
          await capture('open');
          await p.locator('#close').click();
          await capture('close');
          await p.locator('#open').click();
          await capture('reopen');
          await p.locator('#tint').click();
          await capture('author-color');
          assert.deepEqual(errors, []);
          assert.deepEqual(requests, ['https://dialog-layout.example/test']);
          cases.push({ viewport, dpr, theme, steps });
        } finally {
          await context.close();
        }
      }
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-dialog-layout-chromium153.json', import.meta.url),
    JSON.stringify({ browserVersion: browser.version(), html: dialogLayoutHTML, cases }, null, 2) +
      '\n',
  );
  console.log(`${cases.length} default-dialog profiles captured`);
} finally {
  await browser.close();
}
