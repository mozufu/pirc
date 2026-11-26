import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
import { requireTestBrowserExecutable } from './test_browser.mjs';
import { detailsHTML, detailsActions, readDetailsState } from './document_details_fixture.mjs';
const { chromium } = createRequire(import.meta.url)('playwright-core');
const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
});
try {
  assert.equal(browser.version(), '153.0.8010.12');
  const context = await browser.newContext();
  const page = await context.newPage(),
    requests = [],
    errors = [];
  await page.route('**/*', (r) => {
    requests.push(r.request().url());
    return r.fulfill({ contentType: 'text/html', body: detailsHTML });
  });
  page.on('pageerror', (e) => errors.push(e.message));
  await page.goto('https://details.example/test');
  const states = [];
  for (const action of detailsActions) {
    if (action.script) await page.evaluate(`(()=>{${action.script}})()`);
    for (let i = 0; i < 3; i++) await page.evaluate(() => new Promise((r) => setTimeout(r, 0)));
    states.push({ name: action.name, result: await page.evaluate(readDetailsState) });
  }
  assert.deepEqual(errors, []);
  assert.deepEqual(requests, ['https://details.example/test']);
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-details-chromium153.json', import.meta.url),
    JSON.stringify(
      { browserVersion: browser.version(), html: detailsHTML, actions: detailsActions, states },
      null,
      2,
    ) + '\n',
  );
  console.log(`${states.length} Chromium details states captured`);
} finally {
  await browser.close();
}
