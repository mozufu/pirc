import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright-core');
const modes = [
  ['plain', 'width:350px', false],
  ['content_box', 'width:300px;padding:8px;border:3px solid;box-sizing:content-box', false],
  ['border_box', 'width:300px;padding:8px;border:3px solid;box-sizing:border-box', false],
  ['nested', 'width:350px', true],
];
const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
});
try {
  const browserVersion = browser.version();
  if (!browserVersion.startsWith('153.')) throw new Error('Expected Chromium 153');
  const cases = [];
  for (const [mode, parentStyle, nested] of modes)
    for (const viewport of [
      { width: 390, height: 844 },
      { width: 768, height: 1024 },
    ])
      for (const dpr of [1, 3])
        for (const theme of ['light', 'dark']) {
          const child = '<div id="child" style="width:100px;height:40px;background:#3b82f6"></div>';
          const html = `<!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;padding:0}</style></head><body><div id="parent" style="${parentStyle}">${nested ? '<div>' + child + '</div>' : child}</div><button id="start">Resize descendant</button><pre id="probe">WAIT</pre><script>
  document.getElementById('start').onclick=function(){
   var parent=document.getElementById('parent'),child=document.getElementById('child');
   var before=parent.clientWidth;
   child.style.width='425px';child.style.height='90px';
   var after=parent.clientWidth;
   requestAnimationFrame(function(){
    function rect(e){var r=e.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height}}
    document.getElementById('probe').textContent=JSON.stringify({synchronous:{before:before,after:after},settled:{parentClientWidth:parent.clientWidth,parentRect:rect(parent),childRect:rect(child)}});
   });
  };</script></body></html>`;
          const context = await browser.newContext({
            viewport,
            deviceScaleFactor: dpr,
            colorScheme: theme,
          });
          const networkRequests = [],
            pageErrors = [];
          try {
            await context.route('**/*', (route) => {
              networkRequests.push(route.request().url());
              return route.abort();
            });
            const page = await context.newPage();
            page.on('pageerror', (e) => pageErrors.push(String(e)));
            await page.setContent(html);
            await page.locator('#start').click();
            await page.waitForFunction(() =>
              document.getElementById('probe').textContent.startsWith('{'),
            );
            const result = JSON.parse(await page.locator('#probe').textContent());
            if (networkRequests.length || pageErrors.length)
              throw new Error(JSON.stringify({ networkRequests, pageErrors }));
            cases.push({ mode, viewport, dpr, theme, html, result, networkRequests, pageErrors });
          } finally {
            await context.close();
          }
        }
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-layout-dependencies-chromium153.json', import.meta.url),
    JSON.stringify({ browserVersion, cases }) + '\n',
  );
  console.log(
    JSON.stringify({ browserVersion, cases: cases.length, networkRequests: 0, pageErrors: 0 }),
  );
} finally {
  await browser.close();
}
