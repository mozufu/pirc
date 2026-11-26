import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';
const { chromium } = createRequire(import.meta.url)('playwright-core');
const modes = [
  {
    name: 'default_to_pixels',
    style: '',
    actions: [
      "child.style.display='block'",
      "child.style.boxSizing='border-box'",
      "child.style.height='240px'",
      "child.style.width='350px'",
      'child.width=700',
      'child.height=480',
    ],
  },
  {
    name: 'bitmap_auto',
    style: '',
    actions: [
      "child.style.display='block'",
      'child.width=420',
      'child.height=210',
      "child.removeAttribute('width')",
      "child.removeAttribute('height')",
    ],
  },
  {
    name: 'width_auto_height',
    style: 'width:200px',
    actions: [
      "child.style.display='block'",
      'child.width=600',
      'child.height=300',
      "child.style.width='250px'",
    ],
  },
  {
    name: 'height_auto_width',
    style: 'height:100px',
    actions: [
      "child.style.display='block'",
      'child.width=450',
      'child.height=300',
      "child.style.height='200px'",
      "child.style.width='450px'",
    ],
  },
  {
    name: 'percent_axes',
    style: 'width:50%;height:50%',
    actions: [
      "child.style.display='block'",
      "child.style.width='125%'",
      "child.style.height='25%'",
      "child.style.width='480px'",
      "child.style.height='160px'",
    ],
  },
  {
    name: 'zero_natural_width',
    style: '',
    attrs: 'width="0" height="150"',
    actions: [
      "child.style.display='block'",
      "child.style.height='120px'",
      "child.style.width='80px'",
      "child.style.height='auto'",
      'child.width=160',
      'child.height=80',
    ],
  },
  {
    name: 'pixels_to_auto',
    style: 'width:350px;height:240px',
    actions: [
      "child.style.display='block'",
      "child.style.width='auto'",
      "child.style.height='auto'",
      'child.width=400',
      'child.height=200',
      "child.style.width='250px'",
    ],
  },
  {
    name: 'fractional_ratio',
    style: 'width:201.25px',
    attrs: 'width="355" height="233"',
    actions: [
      "child.style.display='block'",
      'child.height=177',
      "child.style.width='321.5px'",
      "child.style.height='125.25px'",
    ],
  },
  {
    name: 'narrow_parent',
    style: '',
    parentWidth: 200,
    parentHeight: 120,
    actions: [
      "child.style.display='block'",
      'child.width=420',
      "child.style.height='120px'",
      "child.style.width='250px'",
    ],
  },
];
const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
});
try {
  const browserVersion = browser.version();
  if (browserVersion !== '153.0.8010.12') throw new Error('Expected pinned Chromium 153');
  const cases = [];
  for (const mode of modes)
    for (const viewport of [
      { width: 390, height: 844 },
      { width: 768, height: 1024 },
    ])
      for (const dpr of [1, 3])
        for (const theme of ['light', 'dark']) {
          const parentSize = { width: mode.parentWidth ?? 350, height: mode.parentHeight ?? 240 };
          const html = `<!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;padding:0}</style></head><body><div id="parent" style="width:${parentSize.width}px;height:${parentSize.height}px"><canvas id="child" style="${mode.style}" ${mode.attrs ?? ''}></canvas></div><button id="start">Resize Canvas</button><pre id="probe">WAIT</pre><script>
  document.getElementById('start').onclick=async function(){
   var child=document.getElementById('child'),parent=document.getElementById('parent'),declaration=getComputedStyle(child),ctx=child.getContext('2d');
   ctx.fillStyle='#ef4444';ctx.fillRect(0,0,20,20);
   function rect(element){var r=element.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height}}
   function state(){return {style:{width:declaration.width,height:declaration.height,display:declaration.display,boxSizing:declaration.boxSizing},axes:{width:child.style.width||'auto',height:child.style.height||'auto'},bitmap:{width:child.width,height:child.height},parentRect:rect(parent),fillStyle:ctx.fillStyle}}
   var checkpoints=[{name:'initial',synchronous:state()}];
   ${mode.actions.map((action, index) => `{${action};var item={name:${JSON.stringify(index + ': ' + action)},synchronous:state()};await new Promise(requestAnimationFrame);item.settled={state:state(),childRect:rect(child)};checkpoints.push(item);}`).join('\n')}
   document.getElementById('probe').textContent=JSON.stringify({checkpoints:checkpoints});
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
            cases.push({
              mode: mode.name,
              viewport,
              dpr,
              theme,
              parentSize,
              html,
              result,
              networkRequests,
              pageErrors,
            });
          } finally {
            await context.close();
          }
        }
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-canvas-sizing-chromium153.json', import.meta.url),
    JSON.stringify({ browserVersion, cases }) + '\n',
  );
  console.log(
    JSON.stringify({ browserVersion, cases: cases.length, networkRequests: 0, pageErrors: 0 }),
  );
} finally {
  await browser.close();
}
