import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';
const { chromium } = createRequire(import.meta.url)('playwright-core');
const mutations = {
  replace: 'target.textContent="new\\nnext";',
  character: 'target.firstChild.data="new\\nnext";',
  append: 'target.appendChild(document.createTextNode("\\nnext"));',
  remove: 'target.removeChild(target.firstChild);',
  replace_children: 'target.replaceChildren("new", "\\nnext");',
  hidden: 'document.getElementById("storage").textContent="new";',
};
function driver(mutation) {
  return `(function(){
 var target=document.getElementById('target'),probe=document.getElementById('probe'),live=getComputedStyle(target);
 function style(){return {color:live.color,font:live.fontFamily,size:live.fontSize,pointer:live.pointerEvents,whiteSpace:live.whiteSpace,theme:live.getPropertyValue('--Theme')};}
 function rect(){var r=target.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height};}
 requestAnimationFrame(function(){probe.textContent=JSON.stringify({phase:'ready',style:style()});});
 document.getElementById('change').onclick=function(){${mutation}
  var synchronous=style();
  requestAnimationFrame(function(){probe.textContent=JSON.stringify({phase:'updated',synchronous:synchronous,settled:style(),rect:rect()});});
 };
})();`;
}
const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
});
try {
  if (browser.version() !== '153.0.8010.12') throw Error('Expected pinned Chromium');
  const cases = [];
  for (const [mode, mutation] of Object.entries(mutations))
    for (const viewport of [
      { width: 390, height: 844 },
      { width: 768, height: 1024 },
    ])
      for (const dpr of [1, 3])
        for (const theme of ['light', 'dark']) {
          const source = driver(mutation);
          const html =
            '<!doctype html><html><head><style>html,body{margin:0;padding:0;font:16px/20px monospace}#target{width:100px;white-space:pre;pointer-events:none;color:rgb(1,2,3);--Theme:night}#probe,#storage{display:none}</style></head><body><div id="target">before</div><button id="change" type="button">Change text</button><pre id="storage">old</pre><pre id="probe">WAIT</pre></body></html>';
          const context = await browser.newContext({
            viewport,
            deviceScaleFactor: dpr,
            colorScheme: theme,
            hasTouch: true,
          });
          const requests = [],
            errors = [];
          try {
            await context.route('**/*', (r) => {
              requests.push(r.request().url());
              return r.abort();
            });
            const page = await context.newPage();
            page.on('pageerror', (e) => errors.push(String(e)));
            await page.setContent(
              html.replace('</body>', '<script>' + source + '</script></body>'),
            );
            await page.waitForFunction(() =>
              document.getElementById('probe').textContent.startsWith('{'),
            );
            const initial = JSON.parse(await page.locator('#probe').textContent());
            await page.locator('#change').tap();
            await page.waitForFunction(
              () => JSON.parse(document.getElementById('probe').textContent).phase === 'updated',
            );
            const result = JSON.parse(await page.locator('#probe').textContent());
            if (errors.length || requests.length) throw Error(JSON.stringify({ errors, requests }));
            cases.push({
              mode,
              viewport,
              dpr,
              theme,
              html,
              driverSource: source,
              initial,
              result,
              errors,
              requests,
            });
          } finally {
            await context.close();
          }
        }
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-text-style-chromium153.json', import.meta.url),
    JSON.stringify({ schemaVersion: 1, browserVersion: browser.version(), cases }) + '\n',
  );
  console.log(
    JSON.stringify({
      cases: cases.length,
      browserVersion: browser.version(),
      errors: 0,
      requests: 0,
    }),
  );
} finally {
  await browser.close();
}
