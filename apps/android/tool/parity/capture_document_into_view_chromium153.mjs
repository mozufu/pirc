import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';
import {
  intoViewModes,
  intoViewHTML,
  intoViewArgument,
  intoViewSetup,
  buildIntoViewDriver,
} from './document_into_view_fixture.mjs';
const { chromium } = createRequire(import.meta.url)('playwright-core');
const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
});
async function measure(page) {
  return page.evaluate(() => {
    const target = document.getElementById('target'),
      nodes = {
        root: document.documentElement,
        outer: document.getElementById('outer'),
        inner: document.getElementById('inner'),
        target,
      };
    const result = {};
    const fields = [
      'display',
      'position',
      'direction',
      'writing-mode',
      'scroll-behavior',
      ...['margin', 'padding'].flatMap((kind) =>
        ['top', 'right', 'bottom', 'left'].map((side) => `scroll-${kind}-${side}`),
      ),
    ];
    function axes(element) {
      const style = element.getAttribute('style'),
        probe = document.createElement('div');
      probe.style.cssText =
        'position:absolute;left:0;top:0;width:0;height:0;margin:0;padding:0;border:0;transform:none';
      if (getComputedStyle(element).position === 'static')
        element.style.setProperty('position', 'relative', 'important');
      element.appendChild(probe);
      const p0 = probe.getBoundingClientRect();
      probe.style.left = '1024px';
      const px = probe.getBoundingClientRect();
      probe.style.left = '0';
      probe.style.top = '1024px';
      const py = probe.getBoundingClientRect();
      probe.remove();
      if (style === null) element.removeAttribute('style');
      else element.setAttribute('style', style);
      return {
        origin: [p0.x, p0.y],
        axes: [
          (px.x - p0.x) / 1024,
          (px.y - p0.y) / 1024,
          (py.x - p0.x) / 1024,
          (py.y - p0.y) / 1024,
        ],
      };
    }
    for (const [name, e] of Object.entries(nodes)) {
      if (!e) {
        result[name] = null;
        continue;
      }
      const b = e.getBoundingClientRect(),
        style = getComputedStyle(e);
      result[name] = {
        rect: [b.x, b.y, b.width, b.height],
        style: Object.fromEntries(fields.map((k) => [k, style.getPropertyValue(k)])),
        width: e.clientWidth,
        height: e.clientHeight,
        scrollWidth: e.scrollWidth,
        scrollHeight: e.scrollHeight,
        ...axes(e),
      };
    }
    if (target && result.target.style.display !== 'none')
      for (const name of ['outer', 'inner']) {
        const port = result[name],
          a = port.axes,
          o = port.origin,
          det = a[0] * a[3] - a[1] * a[2],
          r = result.target.rect;
        const points = [
          [r[0], r[1]],
          [r[0] + r[2], r[1]],
          [r[0], r[1] + r[3]],
          [r[0] + r[2], r[1] + r[3]],
        ].map(([x, y]) => [
          (a[3] * (x - o[0]) - a[2] * (y - o[1])) / det,
          (-a[1] * (x - o[0]) + a[0] * (y - o[1])) / det,
        ]);
        const x = Math.min(...points.map((p) => p[0])),
          y = Math.min(...points.map((p) => p[1]));
        port.targetRect = [
          x,
          y,
          Math.max(...points.map((p) => p[0])) - x,
          Math.max(...points.map((p) => p[1])) - y,
        ];
      }
    return result;
  });
}
try {
  if (browser.version() !== '153.0.8010.12') throw Error('Unexpected browser');
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
          for (const mode of intoViewModes) {
            const html = intoViewHTML(mode),
              driverSource = buildIntoViewDriver(mode);
            await page.setContent(
              html.replace('</body>', `<script>${driverSource}</script></body>`),
            );
            await page.evaluate(() => scrollTo({ left: 0, top: 0, behavior: 'instant' }));
            const measurements = await measure(page);
            await page.locator('#run').click();
            await page.waitForFunction(() =>
              document.getElementById('probe').textContent.startsWith('{'),
            );
            const result = JSON.parse(await page.locator('#probe').textContent());
            if (errors.length || network.length)
              throw Error(JSON.stringify({ mode, errors, network }));
            cases.push({
              mode,
              viewport,
              dpr,
              theme,
              html,
              driverSource,
              argument: intoViewArgument(mode),
              setup: intoViewSetup(mode),
              measurements,
              result,
            });
          }
        } finally {
          await context.close();
        }
      }
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-into-view-chromium153.json', import.meta.url),
    JSON.stringify({ browserVersion: browser.version(), cases }) + '\n',
  );
  process.stdout.write(`Captured ${cases.length} scrollIntoView profiles\n`);
} finally {
  await browser.close();
}
