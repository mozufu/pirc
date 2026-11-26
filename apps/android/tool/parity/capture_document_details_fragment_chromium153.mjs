import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';
import {
  detailsFragmentCases,
  detailsFragmentHTML,
  readDetailsFragmentState,
} from './document_details_fragment_fixture.mjs';
const { chromium } = createRequire(import.meta.url)('playwright-core');
const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
});
try {
  assert.equal(browser.version(), '153.0.8010.12');
  const cases = [];
  for (const screen of [
    { width: 390, height: 844 },
    { width: 768, height: 1024 },
  ])
    for (const dpr of [1, 3])
      for (const theme of ['light', 'dark'])
        for (const spec of detailsFragmentCases)
          for (const initial of [false, true]) {
            const viewport = { width: screen.width, height: screen.height - 48 };
            const context = await browser.newContext({
              viewport,
              deviceScaleFactor: dpr,
              colorScheme: theme,
            });
            const page = await context.newPage(),
              requests = [],
              errors = [];
            const html = detailsFragmentHTML(spec, { scripted: true });
            try {
              page.on('pageerror', (e) => errors.push(e.message));
              await page.route('**/*', (r) => {
                requests.push(r.request().url());
                return r.fulfill({ contentType: 'text/html', body: html });
              });
              await page.goto(
                `https://details-fragment.example/test${initial ? '#' + spec.target : ''}`,
              );
              async function settle() {
                for (let i = 0; i < 3; i++)
                  await page.evaluate(() => new Promise((r) => requestAnimationFrame(r)));
              }
              await settle();
              const states = [
                { name: 'loaded', result: await page.evaluate(readDetailsFragmentState) },
              ];
              if (!initial) {
                await page.locator('#jump').click();
                await settle();
                states.push({
                  name: 'click',
                  result: await page.evaluate(readDetailsFragmentState),
                });
              }
              await page.evaluate(() => {
                document.getElementById('outer').open = false;
                document.getElementById('outerSummary').focus({ preventScroll: true });
                scrollTo(0, 0);
              });
              await settle();
              states.push({
                name: 'closed',
                result: await page.evaluate(readDetailsFragmentState),
              });
              await page.locator('#jump').click();
              await settle();
              states.push({
                name: 'repeat',
                result: await page.evaluate(readDetailsFragmentState),
              });
              // Rewriting the URL does not reveal ancestors. Browser traversal reselects
              // the fragment while retaining the saved root reading position.
              await page.evaluate(() => {
                document.getElementById('outer').open = false;
                document.getElementById('outerSummary').focus({ preventScroll: true });
                scrollTo(0, 0);
              });
              await settle();
              await page.evaluate(() => history.pushState({}, '', '#other-route'));
              await settle();
              await page.evaluate(() => history.back());
              await settle();
              states.push({
                name: 'history',
                result: await page.evaluate(readDetailsFragmentState),
              });
              assert.deepEqual(errors, []);
              assert.equal(requests.length, 1);
              cases.push({ spec, initial, screen, viewport, dpr, theme, html, states });
            } finally {
              await context.close();
            }
          }
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-details-fragment-chromium153.json', import.meta.url),
    JSON.stringify({ browserVersion: browser.version(), cases }, null, 2) + '\n',
  );
  console.log(`${cases.length} profiles captured`);
} finally {
  await browser.close();
}
