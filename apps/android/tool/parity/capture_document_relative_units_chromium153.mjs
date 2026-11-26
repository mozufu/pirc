import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';
import {
  relativeUnitCases,
  relativeUnitHTML,
  relativeUnitCSS,
} from './document_relative_units_fixture.mjs';
const { chromium } = createRequire(import.meta.url)('playwright-core');
const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
});
try {
  if (browser.version() !== '153.0.8010.12') throw Error('Unexpected browser version');
  const cases = [];
  for (const size of [
    { width: 390, height: 844 },
    { width: 768, height: 1024 },
  ])
    for (const dpr of [1, 3])
      for (const theme of ['light', 'dark']) {
        const context = await browser.newContext({
          viewport: size,
          deviceScaleFactor: dpr,
          colorScheme: theme,
        });
        try {
          for (const spec of relativeUnitCases) {
            const page = await context.newPage(),
              requests = [],
              errors = [];
            try {
              await page.route('**/*', (r) => {
                requests.push(r.request().url());
                return r.fulfill({ contentType: 'text/html', body: relativeUnitHTML });
              });
              page.on('pageerror', (e) => errors.push(e.message));
              await page.goto('https://relative-units.example/test');
              await page.addStyleTag({ content: relativeUnitCSS(spec) });
              await page.evaluate(() => {
                window.clicks = 0;
                document.querySelector('#subject').addEventListener('click', (e) => {
                  e.preventDefault();
                  window.clicks++;
                });
              });
              await page.locator('input').fill('retained draft');
              const states = [];
              for (let phase = 0; phase < 3; phase++) {
                const viewport =
                  phase === 2 ? { width: size.width - 40, height: size.height - 80 } : size;
                await page.setViewportSize(viewport);
                const css = relativeUnitCSS(spec, phase);
                await page.evaluate((css) => {
                  document.querySelector('style').textContent = css;
                }, css);
                await page.evaluate(
                  () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))),
                );
                const result = await page.evaluate(() => {
                  const items = {};
                  for (const id of ['parent', 'subject', 'after']) {
                    const e = document.getElementById(id),
                      r = e.getBoundingClientRect(),
                      s = getComputedStyle(e);
                    items[id] = {
                      rect: [r.x, r.y, r.width, r.height],
                      offset: {
                        top: e.offsetTop,
                        left: e.offsetLeft,
                        parent: e.offsetParent?.id || e.offsetParent?.localName || null,
                      },
                      style: Object.fromEntries(
                        ['top', 'right', 'bottom', 'left', 'font-size'].map((k) => [
                          k,
                          s.getPropertyValue(k),
                        ]),
                      ),
                    };
                  }
                  const e = document.getElementById('subject');
                  e.style.position = 'static';
                  const r = e.getBoundingClientRect();
                  const original = [r.x + r.width / 2, r.y + r.height / 2];
                  e.style.position = '';
                  const box = items.subject.rect;
                  return {
                    items,
                    original,
                    hit: [box[0] + box[2] / 2, box[1] + box[3] / 2],
                    probes: [[box[0] + box[2] - 5, box[1] + box[3] - 5], original],
                    draft: document.querySelector('input').value,
                  };
                });
                const png = await page.screenshot();
                result.pixels = await page.evaluate(
                  async ({ data, points, dpr }) => {
                    const bytes = Uint8Array.from(atob(data), (c) => c.charCodeAt(0));
                    const bitmap = await createImageBitmap(
                      new Blob([bytes], { type: 'image/png' }),
                    );
                    const canvas = document.createElement('canvas');
                    canvas.width = bitmap.width;
                    canvas.height = bitmap.height;
                    const c = canvas.getContext('2d');
                    c.drawImage(bitmap, 0, 0);
                    bitmap.close();
                    return points.map(([x, y]) =>
                      Array.from(
                        c.getImageData(Math.floor(x * dpr), Math.floor(y * dpr), 1, 1).data,
                      ),
                    );
                  },
                  { data: png.toString('base64'), points: result.probes, dpr },
                );
                const before = await page.evaluate(() => window.clicks);
                await page.mouse.click(...result.original);
                const stale = await page.evaluate(() => window.clicks);
                await page.mouse.click(...result.hit);
                const hit = await page.evaluate(() => window.clicks);
                if (stale !== before || hit !== before + 1)
                  throw Error(JSON.stringify({ spec, phase, before, stale, hit }));
                states.push({ phase, viewport, css, result });
              }
              if (requests.length !== 1 || errors.length)
                throw Error(JSON.stringify({ spec, requests, errors }));
              cases.push({ spec, html: relativeUnitHTML, viewport: size, dpr, theme, states });
            } finally {
              await page.close();
            }
          }
          console.log('Captured', cases.length);
        } finally {
          await context.close();
        }
      }
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-relative-units-chromium153.json', import.meta.url),
    JSON.stringify({ browserVersion: browser.version(), cases }) + '\n',
  );
} finally {
  await browser.close();
}
