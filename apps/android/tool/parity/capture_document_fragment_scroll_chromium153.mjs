import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';
import { fragmentScrollModes, fragmentScrollHTML } from './document_fragment_scroll_fixture.mjs';
const { chromium } = createRequire(import.meta.url)('playwright-core'),
  browser = await chromium.launch({
    headless: true,
    executablePath: requireTestBrowserExecutable(),
  });
const url = 'https://gateway.example/fragment-scroll';
const settle = (page, smooth) =>
  !smooth
    ? page.evaluate(
        () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))),
      )
    : page.evaluate(
        () =>
          new Promise((resolve) => {
            let first = null;
            function check(t) {
              if (first == null) first = t;
              if (t - first < 800) requestAnimationFrame(check);
              else resolve();
            }
            requestAnimationFrame(check);
          }),
      );
const read = (page) =>
  page.evaluate(() => {
    const target = document.getElementById('target'),
      box = target.getBoundingClientRect();
    return {
      viewport: { width: innerWidth, height: innerHeight },
      positions: {
        root: { left: scrollX, top: scrollY },
        outer: {
          left: document.getElementById('outer').scrollLeft,
          top: document.getElementById('outer').scrollTop,
        },
        inner: {
          left: document.getElementById('inner').scrollLeft,
          top: document.getElementById('inner').scrollTop,
        },
      },
      rect: [box.x, box.y, box.width, box.height].map((v) => +v.toFixed(4)),
      hash: location.hash,
      length: history.length,
    };
  });
try {
  if (browser.version() !== '153.0.8010.12') throw Error(browser.version());
  const cases = [];
  for (const screen of [
    { width: 390, height: 844 },
    { width: 768, height: 1024 },
  ])
    for (const dpr of [1, 3])
      for (const theme of ['light', 'dark']) {
        const viewport = { width: screen.width, height: screen.height - 48 },
          context = await browser.newContext({
            viewport,
            deviceScaleFactor: dpr,
            colorScheme: theme,
          });
        try {
          for (const mode of fragmentScrollModes)
            for (const scripted of [false, true]) {
              if (mode === 'dynamic-margin' && !scripted) continue;
              const html = fragmentScrollHTML(mode, scripted),
                page = await context.newPage(),
                requests = [],
                errors = [];
              await page.route('**/*', (route) => {
                requests.push(route.request().url());
                return route.request().url() === url
                  ? route.fulfill({
                      status: 200,
                      contentType: 'text/html; charset=utf-8',
                      body: html,
                    })
                  : route.abort();
              });
              page.on('pageerror', (e) => errors.push(e.message));
              await page.goto(url + '#target');
              await settle(page, mode === 'css-smooth');
              const initial = await read(page);
              await page.evaluate((url) => {
                document.activeElement?.blur();
                history.replaceState(null, '', url);
                for (const name of ['outer', 'inner'])
                  document.getElementById(name).scrollTo({ left: 0, top: 0, behavior: 'instant' });
              }, url);
              await page.evaluate(() => scrollTo({ top: 240, behavior: 'instant' }));
              const before = await read(page);
              await page.locator('#jump').click();
              await settle(page, mode === 'css-smooth');
              const first = await read(page);
              await page.evaluate(() => {
                scrollTo({ top: 480, behavior: 'instant' });
                for (const name of ['outer', 'inner'])
                  document.getElementById(name).scrollTo({ left: 0, top: 0, behavior: 'instant' });
              });
              await page.locator('#jump').click();
              await settle(page, mode === 'css-smooth');
              const repeated = await read(page);
              if (requests.length !== 1 || errors.length)
                throw Error(JSON.stringify({ mode, requests, errors }));
              cases.push({
                mode,
                scripted,
                screen,
                viewport,
                dpr,
                theme,
                html,
                result: { initial, before, first, repeated, requestCount: requests.length },
              });
              await page.close();
            }
          process.stdout.write(`Captured ${cases.length} profiles\n`);
        } finally {
          await context.close();
        }
      }
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-fragment-scroll-chromium153.json', import.meta.url),
    JSON.stringify({ browserVersion: browser.version(), cases }) + '\n',
  );
} finally {
  await browser.close();
}
