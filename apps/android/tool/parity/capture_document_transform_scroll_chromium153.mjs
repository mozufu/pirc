import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';
import {
  transformScrollModes,
  transformScrollHTML,
  buildTransformScrollDriver,
  buildTransformScrollClickObserver,
} from './document_transform_scroll_fixture.mjs';
const { chromium } = createRequire(import.meta.url)('playwright-core');
const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
});
async function sample(page, dpr) {
  const r = await page.locator('#target').boundingBox(),
    point = { x: r.x + r.width / 2, y: r.y + r.height / 2 };
  const png = (await page.screenshot()).toString('base64');
  return page.evaluate(
    async ({ png, point, dpr }) => {
      const bitmap = await createImageBitmap(
          new Blob([Uint8Array.from(atob(png), (c) => c.charCodeAt(0))], { type: 'image/png' }),
        ),
        canvas = document.createElement('canvas');
      canvas.width = bitmap.width;
      canvas.height = bitmap.height;
      const ctx = canvas.getContext('2d');
      ctx.drawImage(bitmap, 0, 0);
      const rgba = Array.from(
        ctx.getImageData(Math.floor(point.x * dpr), Math.floor(point.y * dpr), 1, 1).data,
      );
      bitmap.close();
      return { ...point, rgba, hit: document.elementFromPoint(point.x, point.y)?.id || null };
    },
    { png, point, dpr },
  );
}
try {
  if (browser.version() !== '153.0.8010.12') throw Error('Unexpected browser version');
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
          const errors = [],
            network = [];
          await context.route('**/*', (r) => {
            network.push(r.request().url());
            return r.abort();
          });
          const page = await context.newPage();
          page.on('pageerror', (e) => errors.push(e.message));
          for (const mode of transformScrollModes) {
            const html = transformScrollHTML(mode),
              driverSource = buildTransformScrollDriver(),
              clickObserverSource = buildTransformScrollClickObserver();
            await page.setContent(
              html.replace(
                '</body>',
                `<script>${driverSource}${clickObserverSource}</script></body>`,
              ),
            );
            await page.evaluate(() => window.scrollTo({ top: 0, behavior: 'instant' }));
            const beforePixel = await sample(page, dpr);

            const clicks = {};
            await page.mouse.click(beforePixel.x, beforePixel.y);
            clicks.before = await page
              .locator('#probe')
              .evaluate((e) => Number(e.getAttribute('data-clicked') || 0));
            await page.locator('#run').click();
            await page.waitForFunction(() =>
              document.getElementById('probe').textContent.startsWith('{'),
            );
            const result = JSON.parse(await page.locator('#probe').textContent()),
              changedPixel = await sample(page, dpr);
            await page.mouse.click(changedPixel.x, changedPixel.y);
            clicks.changed = await page
              .locator('#probe')
              .evaluate((e) => Number(e.getAttribute('data-clicked') || 0));
            if (errors.length || network.length)
              throw Error(JSON.stringify({ errors, network, result }));
            cases.push({
              mode,
              viewport,
              dpr,
              theme,
              html,
              driverSource,
              clickObserverSource,
              clicks,
              tap: { x: beforePixel.x, y: beforePixel.y },
              result,
              pixels: { before: beforePixel, changed: changedPixel },
            });
          }
        } finally {
          await context.close();
        }
      }
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-transform-scroll-chromium153.json', import.meta.url),
    JSON.stringify({ browserVersion: browser.version(), cases }) + '\n',
  );
  console.log(`Captured ${cases.length} transformed scroll profiles`);
} finally {
  await browser.close();
}
