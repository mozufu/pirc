import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { writeFile, mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { requireTestBrowserExecutable } from './test_browser.mjs';
import {
  scriptPickerLifetimeHTML,
  pickedFiles,
  readScriptPickerState,
} from './document_script_picker_lifetime_fixture.mjs';
const { chromium } = createRequire(import.meta.url)('playwright-core');
const directory = await mkdtemp(path.join(os.tmpdir(), 'pirc-script-picker-reference-'));
const filePaths = await Promise.all(
  pickedFiles.map(async (f) => {
    const target = path.join(directory, f.name);
    await writeFile(target, Buffer.from(f.bytes));
    return target;
  }),
);
const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
});
try {
  assert.equal(browser.version(), '153.0.8010.12');
  const cases = [];
  for (const viewport of [
    { width: 390, height: 796 },
    { width: 768, height: 976 },
  ])
    for (const dpr of [1, 3])
      for (const theme of ['light', 'dark']) {
        const context = await browser.newContext({
          viewport,
          deviceScaleFactor: dpr,
          colorScheme: theme,
        });
        try {
          let requests = 0;
          const errors = [];
          await context.route('**/*', (r) => {
            requests++;
            return r.fulfill({ contentType: 'text/html', body: scriptPickerLifetimeHTML });
          });
          const page = await context.newPage();
          page.on('pageerror', (e) => errors.push(e.message));
          await page.goto('https://picker.example/lifetime');
          const initial = await page.evaluate(readScriptPickerState);
          const waiting = page.waitForEvent('filechooser');
          await page.locator('#choose').click();
          const chooser = await waiting;
          await page.evaluate(() => (document.documentElement.style.display = 'none'));
          // Paths use the browser's chooser protocol. Buffer payloads use
          // Playwright-injected events and cannot establish isTrusted parity.
          await chooser.setFiles(filePaths);
          const hidden = await page.evaluate(readScriptPickerState);
          await page.evaluate(() => (document.documentElement.style.display = ''));
          const resumed = await page.evaluate(readScriptPickerState);
          assert.deepEqual(hidden, resumed);
          assert.deepEqual(resumed.files, pickedFiles);
          await page.locator('[type=reset]').click();
          const reset = await page.evaluate(readScriptPickerState);
          const freshPage = await context.newPage();
          await freshPage.goto('https://picker.example/lifetime');
          const fresh = await freshPage.evaluate(readScriptPickerState);
          assert.deepEqual(fresh, initial);
          assert.equal(requests, 2);
          assert.deepEqual(errors, []);
          cases.push({ viewport, dpr, theme, initial, hidden, resumed, reset, fresh });
        } finally {
          await context.close();
        }
      }
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-script-picker-lifetime-chromium153.json', import.meta.url),
    JSON.stringify(
      { browserVersion: browser.version(), html: scriptPickerLifetimeHTML, pickedFiles, cases },
      null,
      2,
    ) + '\n',
  );
  console.log(`${cases.length} script picker lifetime environments captured`);
} finally {
  await browser.close();
  await rm(directory, { recursive: true, force: true });
}
