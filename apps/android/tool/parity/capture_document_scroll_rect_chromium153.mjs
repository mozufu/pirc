import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';
import {
  scrollRectModes,
  scrollRectHTML,
  buildScrollRectDriver,
} from './document_scroll_rect_fixture.mjs';
const { chromium } = createRequire(import.meta.url)('playwright-core');
const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
});
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
          for (const mode of scrollRectModes) {
            const html = scrollRectHTML(mode),
              driverSource = buildScrollRectDriver(mode);
            await page.setContent(
              html.replace('</body>', `<script>${driverSource}</script></body>`),
            );
            await page.evaluate(() => window.scrollTo({ top: 0, left: 0, behavior: 'instant' }));
            const before = await page.evaluate(() => {
              const boxes = {};
              for (const id of ['outer', 'inner']) {
                const e = document.getElementById(id);
                boxes[id] = {
                  width: e.scrollWidth,
                  height: e.scrollHeight,
                  clientWidth: e.clientWidth,
                  clientHeight: e.clientHeight,
                };
              }
              return boxes;
            });
            const paint = await page.evaluate(() => {
              const ids = ['outer', 'inner', 'target', 'outside', 'fixed'],
                rects = {};
              for (const id of ids) {
                const e = document.getElementById(id),
                  r = e.getBoundingClientRect();
                rects[id] = [r.x, r.y, r.width, r.height];
              }
              const target = document.getElementById('target'),
                base = target.getBoundingClientRect(),
                axes = {};
              for (const id of ['outer', 'inner']) {
                const e = document.getElementById(id);
                e.scrollLeft = 1;
                const x = target.getBoundingClientRect();
                e.scrollLeft = 0;
                e.scrollTop = 1;
                const y = target.getBoundingClientRect();
                e.scrollTop = 0;
                axes[id] = [base.x - x.x, base.y - x.y, base.x - y.x, base.y - y.y];
              }
              return { rects, axes };
            });
            let tap;
            if (['canvas', 'self-canvas'].includes(mode)) {
              const b = await page.locator('#target').boundingBox();
              tap = { x: b.x + b.width / 2, y: b.y + b.height / 2 };
            }
            await page
              .locator(['canvas', 'self-canvas'].includes(mode) ? '#target' : '#run')
              .click();
            await page.waitForFunction(() =>
              document.getElementById('probe').textContent.startsWith('{'),
            );
            const result = JSON.parse(await page.locator('#probe').textContent());
            if (errors.length || network.length) throw Error(JSON.stringify({ errors, network }));
            cases.push({
              mode,
              target: 'scrollRect',
              viewport,
              dpr,
              theme,
              html,
              driverSource,
              scrollports: before,
              paint,
              ...(tap ? { tap } : {}),
              result,
            });
          }
        } finally {
          await context.close();
        }
      }
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-scroll-rect-chromium153.json', import.meta.url),
    JSON.stringify({ browserVersion: browser.version(), cases }) + '\n',
  );
  console.log(`Captured ${cases.length} scroll rectangle profiles`);
} finally {
  await browser.close();
}
