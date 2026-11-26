import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';
import { elementAnchorModes, buildElementAnchorPage } from './document_element_anchor_fixture.mjs';
const { chromium } = createRequire(import.meta.url)('playwright-core');
const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
});
try {
  if (browser.version() !== '153.0.8010.12') throw Error('Unexpected browser version');
  const cases = [];
  for (const mode of elementAnchorModes)
    for (const viewport of [
      { width: 390, height: 844 },
      { width: 768, height: 1024 },
    ])
      for (const dpr of [1, 3])
        for (const theme of ['light', 'dark']) {
          const { html, driverSource } = buildElementAnchorPage(mode);
          const context = await browser.newContext({
            viewport,
            deviceScaleFactor: dpr,
            colorScheme: theme,
            hasTouch: true,
          });
          const errors = [],
            requests = [];
          try {
            await context.route('**/*', (route) => {
              requests.push(route.request().url());
              return route.abort();
            });
            const page = await context.newPage();
            page.on('pageerror', (e) => errors.push(e.message));
            await page.setContent(
              html.replace('</body>', `<script>${driverSource}</script></body>`),
            );
            const states = [];
            for (let phase = 0; phase < 4; phase++) {
              if (phase) await page.locator('#advance').tap();
              await page.waitForFunction((p) => {
                try {
                  return JSON.parse(document.getElementById('probe').textContent).phase === p;
                } catch {
                  return false;
                }
              }, phase);
              await page.evaluate(
                () =>
                  new Promise((resolve) =>
                    requestAnimationFrame(() => requestAnimationFrame(resolve)),
                  ),
              );
              const snapshot = await page.evaluate(() => ({
                state: JSON.parse(document.getElementById('probe').textContent),
                html: document.documentElement.outerHTML,
              }));
              const point = { x: 30, y: 60 },
                png = (await page.screenshot()).toString('base64');
              const rgba = await page.evaluate(
                async ({ png, dpr, point }) => {
                  const bitmap = await createImageBitmap(
                    new Blob([Uint8Array.from(atob(png), (c) => c.charCodeAt(0))], {
                      type: 'image/png',
                    }),
                  );
                  const canvas = document.createElement('canvas');
                  canvas.width = bitmap.width;
                  canvas.height = bitmap.height;
                  const ctx = canvas.getContext('2d');
                  ctx.drawImage(bitmap, 0, 0);
                  bitmap.close();
                  return [...ctx.getImageData(point.x * dpr, point.y * dpr, 1, 1).data];
                },
                { png, dpr, point },
              );
              states.push({ ...snapshot, point, rgba });
            }
            if (errors.length || requests.length) throw Error(JSON.stringify({ errors, requests }));
            cases.push({
              mode,
              viewport,
              dpr,
              theme,
              html,
              driverSource,
              states,
              errors,
              requests,
            });
          } finally {
            await context.close();
          }
        }
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-element-anchor-chromium153.json', import.meta.url),
    JSON.stringify({ schemaVersion: 1, browserVersion: browser.version(), cases }) + '\n',
  );
  console.log(
    JSON.stringify({
      cases: cases.length,
      browserVersion: browser.version(),
      offsets: cases
        .filter((r) => r.viewport.width === 390 && r.dpr === 1 && r.theme === 'light')
        .map((r) => ({ mode: r.mode, scrollY: r.states.map((s) => s.state.scrollY) })),
    }),
  );
} finally {
  await browser.close();
}
