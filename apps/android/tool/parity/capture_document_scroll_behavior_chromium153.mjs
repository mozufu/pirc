import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';
import {
  scrollBehaviorModes,
  scrollBehaviorHTML,
  buildScrollBehaviorDriver,
} from './document_scroll_behavior_fixture.mjs';
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
          for (const target of ['root', 'element'])
            for (const mode of scrollBehaviorModes) {
              const driverSource = buildScrollBehaviorDriver(mode, target);
              await page.setContent(
                scrollBehaviorHTML(mode).replace(
                  '</body>',
                  `<script>${driverSource}</script></body>`,
                ),
              );
              await page.evaluate(() => {
                window.scrollTo({ left: 0, top: 0, behavior: 'instant' });
                document.getElementById('port').scrollTo({ left: 0, top: 0, behavior: 'instant' });
              });
              await page.locator('#run').click();
              await page.waitForFunction(() =>
                document.getElementById('probe').textContent.startsWith('{'),
              );
              const result = JSON.parse(await page.locator('#probe').textContent());
              if (errors.length || network.length) throw Error(JSON.stringify({ errors, network }));
              cases.push({
                mode,
                target,
                viewport,
                dpr,
                theme,
                html: scrollBehaviorHTML(mode),
                requestBehavior: mode === 'instant' ? 'instant' : mode === 'auto' ? 'auto' : 'auto',
                driverSource,
                result,
              });
            }
        } finally {
          await context.close();
        }
      }
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-scroll-behavior-chromium153.json', import.meta.url),
    JSON.stringify({ browserVersion: browser.version(), cases }) + '\n',
  );
  console.log(`Captured ${cases.length} CSS scroll behavior profiles`);
} finally {
  await browser.close();
}
