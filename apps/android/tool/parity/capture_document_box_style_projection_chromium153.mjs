import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright-core');
const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
});
try {
  const browserVersion = browser.version();
  if (browserVersion !== '153.0.8010.12') throw new Error('Expected pinned Chromium 153.0.8010.12');
  const cases = [];
  for (const mode of ['fixed', 'percent', 'block_to_inline', 'restored'])
    for (const viewport of [
      { width: 390, height: 844 },
      { width: 768, height: 1024 },
    ])
      for (const dpr of [1, 3])
        for (const theme of ['light', 'dark']) {
          const initialStyle = `width:${mode === 'percent' ? '100%' : '350px'};height:240px${mode === 'block_to_inline' ? ';display:block' : ''}`;
          const html = `<!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;padding:0}</style></head><body><div id="parent" style="width:350px;height:240px"><canvas id="child" style="${initialStyle}"></canvas></div><button id="start">Change box style</button><pre id="probe">WAIT</pre><script>
  document.getElementById('start').onclick=function(){
   var parent=document.getElementById('parent'),child=document.getElementById('child');
   var declaration=getComputedStyle(child);
   child.style.display=${JSON.stringify(mode === 'block_to_inline' ? 'inline' : 'block')};
   child.style.boxSizing='border-box';
   child.style.width='350px';child.width=700;child.height=480;
   ${mode === 'restored' ? "child.style.display='inline';child.style.boxSizing='content-box';" : ''}
   function rect(e){var r=e.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height}}
   function style(){return {display:declaration.display,boxSizing:declaration.boxSizing,width:declaration.width,height:declaration.height}}
   var synchronous={style:style(),parentRect:rect(parent),parentWidth:getComputedStyle(parent).width};
   requestAnimationFrame(function(){document.getElementById('probe').textContent=JSON.stringify({synchronous:synchronous,settled:{style:style(),parentRect:rect(parent),childRect:rect(child)}})});
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
            page.on('pageerror', (error) => pageErrors.push(String(error)));
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
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-box-style-projection-chromium153.json', import.meta.url),
    JSON.stringify({ browserVersion, cases }) + '\n',
  );
  console.log(
    JSON.stringify({ browserVersion, cases: cases.length, networkRequests: 0, pageErrors: 0 }),
  );
} finally {
  await browser.close();
}
