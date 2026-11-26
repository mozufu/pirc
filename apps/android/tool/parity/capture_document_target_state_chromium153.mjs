import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';
import {
  targetStateHTML,
  targetStateSteps,
  scriptedTargetStateSteps,
} from './document_target_state_fixture.mjs';
const { chromium } = createRequire(import.meta.url)('playwright-core');
const browser = await chromium.launch({
  headless: true,
  executablePath: requireTestBrowserExecutable(),
});
try {
  if (browser.version() !== '153.0.8010.12') throw Error(browser.version());
  const cases = [];
  for (const screen of [
    { width: 390, height: 844 },
    { width: 768, height: 1024 },
  ])
    for (const dpr of [1, 3])
      for (const theme of ['light', 'dark'])
        for (const scripted of [false, true]) {
          const viewport = { width: screen.width, height: screen.height - 48 };
          const context = await browser.newContext({
            viewport,
            deviceScaleFactor: dpr,
            colorScheme: theme,
          });
          try {
            const page = await context.newPage(),
              requests = [],
              errors = [],
              html = targetStateHTML(scripted);
            await page.route('**/*', (route) => {
              requests.push(route.request().url());
              return route.fulfill({
                status: 200,
                contentType: 'text/html; charset=utf-8',
                body: html,
              });
            });
            page.on('pageerror', (e) => errors.push(e.message));
            await page.goto('https://gateway.example/target-state#one');
            const results = [];
            for (const step of scripted ? scriptedTargetStateSteps : targetStateSteps) {
              if (step[0] === 'link' || step[0] === 'button')
                await page.locator('#' + step[1]).click();
              if (step[0] === 'back') await page.goBack();
              if (step[0] === 'forward') await page.goForward();
              await page.evaluate(
                () =>
                  new Promise((resolve) =>
                    requestAnimationFrame(() => requestAnimationFrame(resolve)),
                  ),
              );
              results.push(
                await page.evaluate(() => ({
                  hash: location.hash,
                  rootTop: scrollY,
                  target: Array.from(document.querySelectorAll(':target'), (e) => e.dataset.key),
                  styles: Array.from(document.querySelectorAll('.item'), (e) => {
                    const s = getComputedStyle(e),
                      r = e.getBoundingClientRect();
                    return [
                      e.dataset.key,
                      s.display,
                      s.color,
                      s.backgroundColor,
                      s.height,
                      s.borderLeftWidth,
                      [r.x, r.y, r.width, r.height],
                    ];
                  }),
                  script: window.readTargetState ? window.readTargetState() : null,
                })),
              );
            }
            if (requests.length !== 1 || errors.length)
              throw Error(JSON.stringify({ requests, errors }));
            cases.push({ screen, viewport, dpr, theme, scripted, html, results });
          } finally {
            await context.close();
          }
        }
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-target-state-chromium153.json', import.meta.url),
    JSON.stringify({ browserVersion: browser.version(), cases }) + '\n',
  );
  console.log('Captured', cases.length, 'profiles');
} finally {
  await browser.close();
}
