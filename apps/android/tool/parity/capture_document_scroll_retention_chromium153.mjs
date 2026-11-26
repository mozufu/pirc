import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';
import {
  scrollRetentionHTML,
  scrollRetentionDriver,
  setScrollRetentionOffsets,
  readScrollRetentionState,
} from './document_scroll_retention_fixture.mjs';
const { chromium } = createRequire(import.meta.url)('playwright-core');
const server = createServer((request, response) => {
  response.writeHead(200, {
    'content-type': 'text/html; charset=utf-8',
    'cache-control': 'max-age=3600',
  });
  response.end(
    request.url.startsWith('/other')
      ? '<!doctype html><body>Other document'
      : scrollRetentionHTML.replace('</body>', `<script>${scrollRetentionDriver}</script></body>`),
  );
});
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
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
          hasTouch: true,
        });
        try {
          const errors = [],
            externalRequests = [];
          await context.route('**/*', (route) => {
            if (
              route
                .request()
                .url()
                .startsWith(origin + '/')
            )
              return route.continue();
            externalRequests.push(route.request().url());
            return route.abort();
          });
          const page = await context.newPage();
          page.on('pageerror', (error) => errors.push(error.message));
          await page.goto(origin + '/document');
          const frames = () =>
            page.evaluate(
              () =>
                new Promise((resolve) =>
                  requestAnimationFrame(() => requestAnimationFrame(resolve)),
                ),
            );
          const states = [];
          const sample = async (name) => {
            await frames();
            states.push({ name, ...(await page.evaluate(readScrollRetentionState)) });
          };
          await page.evaluate(setScrollRetentionOffsets, 1);
          await sample('first');
          await page.evaluate(() => history.pushState({}, '', '#two'));
          await page.evaluate(setScrollRetentionOffsets, 2);
          await sample('second');
          await page.goBack();
          await sample('back-auto');
          await page.goForward();
          await sample('forward-auto');
          await page.evaluate(() => {
            history.scrollRestoration = 'manual';
            history.pushState({}, '', '#three');
          });
          await page.evaluate(setScrollRetentionOffsets, 3);
          await sample('third');
          await page.goBack();
          await sample('back-manual');
          await page.goBack();
          await sample('back-first-auto');
          await page.goto(origin + '/other');
          await page.goBack();
          await sample('fresh-response');
          if (errors.length || externalRequests.length)
            throw Error(JSON.stringify({ errors, externalRequests }));
          await page.goto(origin + '/document#outer');
          await page.evaluate(setScrollRetentionOffsets, 1);
          await page.evaluate(() => scrollTo(0, 160));
          await frames();
          const retainedEntry = await page.evaluate(readScrollRetentionState);
          await page.goto(origin + '/document#top');
          await frames();
          const movedEntry = await page.evaluate(readScrollRetentionState);
          cases.push({ viewport, dpr, theme, states, retainedEntry, movedEntry });
        } finally {
          await context.close();
        }
      }
  const result = {
    browserVersion: browser.version(),
    html: scrollRetentionHTML,
    driverSource: scrollRetentionDriver,
    cases,
  };
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-scroll-retention-chromium153.json', import.meta.url),
    JSON.stringify(result) + '\n',
  );
  console.log(`Captured ${cases.length} scroll history profiles`);
} finally {
  await browser.close();
  await new Promise((resolve) => server.close(resolve));
}
