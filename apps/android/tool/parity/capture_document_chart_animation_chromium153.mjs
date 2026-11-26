import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { requireTestBrowserExecutable } from './test_browser.mjs';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright-core');
const vendor = new URL('./vendor/chart.js-4.5.1/', import.meta.url);
const library = await readFile(new URL('chart.umd.js', vendor), 'utf8');
const provenance = JSON.parse(await readFile(new URL('provenance.json', vendor), 'utf8'));
const sha256 = createHash('sha256').update(library).digest('hex');
if (sha256 !== provenance.assetSha256) throw new Error('Chart.js checksum mismatch');
const driverSource = await readFile(
  new URL('./document_chart_animation_driver.js', import.meta.url),
  'utf8',
);
const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
});
const cases = [];
try {
  const browserVersion = browser.version();
  if (browserVersion !== '153.0.8010.12') throw new Error('Expected pinned Chromium 153');
  for (const type of ['bar', 'line', 'pie', 'doughnut', 'scatter', 'bubble', 'radar', 'polarArea'])
    for (const viewport of [
      { width: 390, height: 844 },
      { width: 768, height: 1024 },
    ])
      for (const dpr of [1, 3])
        for (const theme of ['light', 'dark']) {
          const width = viewport.width - 40;
          const html =
            '<!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;padding:0}#chart-container{position:relative;margin-left:20px;width:' +
            width +
            'px;height:240px}#chart{display:block;box-sizing:border-box;width:' +
            width +
            'px;height:240px}</style></head><body><div id="chart-container"><canvas id="chart" width="' +
            width * dpr +
            '" height="' +
            240 * dpr +
            '" data-chart-type="' +
            type +
            '" data-dpr="' +
            dpr +
            '" data-width="' +
            width +
            '" style="display:block;box-sizing:border-box;width:' +
            width +
            'px;height:240px"></canvas></div><button id="update">Update data</button><button id="resize">Resize container</button><pre id="live">WAIT</pre><pre id="probe">WAIT</pre><script src="/chart.js"></script><script src="/chart-types-driver.js"></script></body></html>';
          const context = await browser.newContext({
            viewport,
            deviceScaleFactor: dpr,
            colorScheme: theme,
            hasTouch: true,
          });
          const requests = [],
            unexpectedRequests = [],
            pageErrors = [];
          try {
            await context.route('**/*', async (route) => {
              const url = new URL(route.request().url());
              requests.push(url.href);
              const routeMap = {
                '/page': ['text/html', html],
                '/chart.js': ['text/javascript', library],
                '/chart-types-driver.js': ['text/javascript', driverSource],
              };
              const resource =
                url.origin === 'http://chart-types.test' ? routeMap[url.pathname] : null;
              if (!resource) {
                unexpectedRequests.push(url.href);
                return route.abort();
              }
              return route.fulfill({ status: 200, contentType: resource[0], body: resource[1] });
            });
            const page = await context.newPage();
            page.on('pageerror', (e) => pageErrors.push(String(e)));
            await page.goto('http://chart-types.test/page');
            await page.waitForFunction(() =>
              document.getElementById('probe').textContent.startsWith('{'),
            );
            const steps = [];
            async function observation(name) {
              const state = JSON.parse(await page.locator('#probe').textContent());
              if (state.error) throw new Error(type + ' ' + name + ': ' + state.error);
              const pixels = await page.evaluate((state) => {
                const canvas = document.getElementById('chart'),
                  ctx = canvas.getContext('2d'),
                  dpr = state.chart.dpr;
                return state.paintPoints.map((point) => ({
                  name: point.name,
                  x: point.x,
                  y: point.y,
                  rgba: Array.from(
                    ctx.getImageData(Math.floor(point.x * dpr), Math.floor(point.y * dpr), 1, 1)
                      .data,
                  ),
                }));
              }, state);
              const strokes = await page.evaluate((state) => {
                const ctx = document.getElementById('chart').getContext('2d'),
                  dpr = state.chart.dpr;
                return state.strokePoints.map((point) => {
                  const bytes = ctx.getImageData(
                    Math.floor(point.x * dpr) - 2,
                    Math.floor(point.y * dpr) - 2,
                    5,
                    5,
                  ).data;
                  let found = false;
                  for (let i = 0; i < bytes.length; i += 4)
                    if (
                      Math.abs(bytes[i] - 37) <= 2 &&
                      Math.abs(bytes[i + 1] - 99) <= 2 &&
                      Math.abs(bytes[i + 2] - 235) <= 2 &&
                      bytes[i + 3] > 100
                    )
                      found = true;
                  if (!found) throw new Error('Browser line connection was not painted');
                  return { name: point.name, present: found };
                });
              }, state);
              steps.push({ name, state, pixels, strokes });
              return state;
            }
            async function changed(action, previous) {
              await action();
              await page.waitForFunction((serial) => {
                const state = JSON.parse(document.getElementById('probe').textContent);
                return state.error || state.serial > serial;
              }, previous.serial);
            }
            let state = await observation('initial');
            for (const [name, index] of [
              ['touchFirst', 0],
              ['touchSecond', 1],
            ]) {
              const point = state.items[index].center,
                rect = state.canvas.rect;
              await changed(() => page.touchscreen.tap(rect.x + point.x, rect.y + point.y), state);
              state = await observation(name);
            }
            await changed(() => page.touchscreen.tap(viewport.width - 5, 120), state);
            state = await observation('outside');
            for (const name of ['legendHide', 'legendShow']) {
              const box = state.legend[0],
                rect = state.canvas.rect;
              await changed(
                () =>
                  page.touchscreen.tap(
                    rect.x + box.left + box.width / 2,
                    rect.y + box.top + box.height / 2,
                  ),
                state,
              );
              state = await observation(name);
            }
            await changed(() => page.locator('#update').click(), state);
            state = await observation('updated');
            await changed(() => page.locator('#resize').click(), state);
            state = await observation('resized');
            const byName = Object.fromEntries(steps.map((step) => [step.name, step]));
            if (
              byName.touchFirst.state.chartActive[0]?.index !== 0 ||
              byName.touchSecond.state.chartActive[0]?.index !== 1 ||
              byName.outside.state.tooltip.opacity !== 0 ||
              byName.legendHide.state.items[0].visible !== false ||
              byName.legendShow.state.items[0].visible !== true ||
              byName.resized.state.chart.width !== width + 20 ||
              byName.updated.state.phase !== 'updated'
            )
              throw new Error('Missing real chart interaction: ' + type);
            const initialPixel = JSON.stringify(
              byName.initial.pixels.find((p) => p.name === 'initial-first').rgba,
            );
            if (
              JSON.stringify(
                byName.legendHide.pixels.find((p) => p.name === 'initial-first').rgba,
              ) === initialPixel ||
              JSON.stringify(
                byName.legendShow.pixels.find((p) => p.name === 'initial-first').rgba,
              ) !== initialPixel
            )
              throw new Error('Legend must remove and restore actual pixels: ' + type);
            if (unexpectedRequests.length || pageErrors.length)
              throw new Error(JSON.stringify({ unexpectedRequests, pageErrors }));
            cases.push({
              caseId: type + '_' + viewport.width + '_dpr' + dpr + '_' + theme,
              type,
              viewport,
              dpr,
              theme,
              html,
              steps,
              requests,
              unexpectedRequests,
              pageErrors,
            });
          } finally {
            await context.close();
          }
        }
  const fixture = {
    schemaVersion: 1,
    browserVersion,
    chartJs: { version: provenance.version, sha256 },
    driverSource,
    cases,
  };
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-chart-animation-chromium153.json', import.meta.url),
    JSON.stringify(fixture) + '\n',
  );
  console.log(
    JSON.stringify({
      cases: cases.length,
      types: [...new Set(cases.map((row) => row.type))],
      browserVersion,
      unexpectedRequests: 0,
      pageErrors: 0,
    }),
  );
} finally {
  await browser.close();
}
