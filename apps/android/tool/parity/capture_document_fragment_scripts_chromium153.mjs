import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';

const { chromium } = createRequire(import.meta.url)('playwright-core');
const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
});
try {
  if (browser.version() !== '153.0.8010.12') throw Error('Expected pinned Chromium');
  const page = await browser.newPage();
  await page.setContent('<div id="host"></div>');
  const result = await page.evaluate(() => {
    const host = document.querySelector('#host');
    const fragment = document.createDocumentFragment();
    const script = document.createElement('script');
    script.textContent = 'window.fragmentRuns = (window.fragmentRuns || 0) + 1';
    fragment.appendChild(script);
    host.appendChild(fragment);
    const connectedScriptRuns = window.fragmentRuns || 0;
    script.remove();
    host.appendChild(script);
    const reinsertedScriptRuns = window.fragmentRuns || 0;

    const holder = document.createElement('div');
    holder.insertAdjacentHTML('beforeend',
      '<script>window.markupRuns = (window.markupRuns || 0) + 1<\\/script>');
    document.body.appendChild(holder);
    const parsedScriptRuns = window.markupRuns || 0;
    const parsed = holder.querySelector('script');
    parsed.remove();
    document.body.appendChild(parsed);
    const reinsertedMarkupRuns = window.markupRuns || 0;
    return {
      connectedScriptRuns,
      reinsertedScriptRuns,
      fragmentWasEmptied: fragment.childNodes.length === 0,
      parsedScriptRuns,
      reinsertedMarkupRuns,
    };
  });
  const fixture = { schemaVersion: 1, browserVersion: browser.version(), result };
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-fragment-scripts-chromium153.json', import.meta.url),
    JSON.stringify(fixture) + '\n',
  );
  console.log(JSON.stringify(fixture));
} finally {
  await browser.close();
}
