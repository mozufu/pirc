import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';
const { chromium } = createRequire(import.meta.url)('playwright-core');
const child = (policy, extra = '') =>
  `<div id="child" style="width:90px;height:40px;${policy == null ? '' : 'pointer-events:' + policy + ';'}${extra}"></div>`;
const modes = [
  { name: 'none', policy: 'none' },
  { name: 'auto', policy: 'auto' },
  { name: 'inherited_none', policy: 'none', body: child(null), points: [{ selector: '#child' }] },
  {
    name: 'restore_block',
    policy: 'none',
    body: child('auto'),
    points: [{ selector: '#child' }, { x: 190, y: 110 }],
  },
  {
    name: 'restore_inline',
    policy: 'none',
    body: '<span id="child" style="pointer-events:auto">AA<span id="nested" style="pointer-events:none">BB</span>CC</span>',
    points: [
      { selector: '#child', first: true },
      { selector: '#nested', first: true },
      { x: 190, y: 110 },
    ],
  },
  {
    name: 'inline_none',
    policy: 'auto',
    body: '<span id="child" style="pointer-events:none">AA</span>',
    points: [{ selector: '#child', first: true }],
  },
  { name: 'initial', policy: 'none', body: child('initial'), points: [{ selector: '#child' }] },
  { name: 'unset', policy: 'none', body: child('unset'), points: [{ selector: '#child' }] },
  { name: 'inherit', policy: 'none', body: child('inherit'), points: [{ selector: '#child' }] },
  {
    name: 'invalid',
    policy: 'none',
    body: child('auto;pointer-events:bogus'),
    points: [{ selector: '#child' }],
  },
  {
    name: 'variable',
    policy: 'none',
    body: child('var(--hit)'),
    extra: '--hit:auto;',
    points: [{ selector: '#child' }],
  },
  {
    name: 'invalid_variable',
    policy: 'none',
    body: child('var(--hit)'),
    extra: '--hit:bogus;',
    points: [{ selector: '#child' }],
  },
  {
    name: 'clipped_restore',
    policy: 'none',
    body: child('auto', 'position:relative;left:60px;top:10px;'),
    extra: 'width:80px;height:50px;overflow:hidden;padding:0;',
    points: [
      { x: 80, y: 35 },
      { x: 110, y: 35 },
    ],
  },
  {
    name: 'overflow_restore',
    policy: 'none',
    body: child('auto', 'position:relative;left:60px;top:10px;'),
    extra: 'width:80px;height:50px;padding:0;',
    points: [
      { x: 80, y: 35 },
      { x: 110, y: 35 },
    ],
  },
  {
    name: 'higher_cover',
    policy: 'none',
    body: child('auto'),
    cover: 'auto',
    points: [
      { x: 50, y: 50 },
      { x: 190, y: 110 },
    ],
  },
  {
    name: 'transparent_cover',
    policy: 'none',
    body: child('auto'),
    cover: 'none',
    points: [
      { x: 50, y: 50 },
      { x: 190, y: 110 },
    ],
  },
  {
    name: 'button_restore',
    policy: 'none',
    body: '<button id="child" type="button" style="pointer-events:auto;width:90px;height:40px">Tap</button>',
    points: [{ selector: '#child' }, { x: 190, y: 110 }],
  },
  {
    name: 'canvas_none',
    policy: 'none',
    body: '<canvas id="child" width="90" height="40" style="width:90px;height:40px"></canvas>',
    points: [{ selector: '#child' }],
  },
  {
    name: 'canvas_restore',
    policy: 'none',
    body: '<canvas id="child" width="90" height="40" style="pointer-events:auto;width:90px;height:40px"></canvas>',
    points: [{ selector: '#child' }],
  },
  {
    name: 'svg_keyword_html',
    policy: 'none',
    body: child('all'),
    points: [{ selector: '#child' }],
  },
  { name: 'dynamic', policy: 'none', dynamic: true },
  { name: 'programmatic', policy: 'none', programmatic: true },
];
const driverSource = `(function(){
 var phase='initial',trace=[];
 function report(){var values={};['base','overlay','child'].forEach(function(id){var e=document.getElementById(id);if(e&&e.tagName!=='SPAN')values[id]=getComputedStyle(e).getPropertyValue('pointer-events');});document.getElementById('probe').textContent=JSON.stringify({phase:phase,trace:trace,pointer:values});}
 document.querySelectorAll('#host,[id]').forEach(function(e){if(['probe','toggle','program'].includes(e.id))return;e.addEventListener('click',function(event){trace.push({target:event.target.id,current:e.id,trusted:event.isTrusted});if(e.id==='host'){event.preventDefault();report();}});});
 document.getElementById('toggle').onclick=function(){var e=document.getElementById('overlay');e.style.pointerEvents=e.style.pointerEvents==='none'?'auto':'none';phase=e.style.pointerEvents;requestAnimationFrame(report);};
 document.getElementById('program').onclick=function(){document.getElementById('overlay').click();phase='program';report();};
 requestAnimationFrame(report);
})();`;
const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
});
try {
  if (browser.version() !== '153.0.8010.12') throw Error('Expected pinned Chromium');
  const cases = [];
  for (const mode of modes)
    for (const viewport of [
      { width: 390, height: 844 },
      { width: 768, height: 1024 },
    ])
      for (const dpr of [1, 3])
        for (const theme of ['light', 'dark']) {
          const html = `<!doctype html><html><head><style>html,body{margin:0;padding:0;font:16px/20px monospace}#host{position:relative;width:240px;height:160px}#base{width:240px;height:160px;background:#22c55e}#overlay{position:absolute;left:10px;top:10px;width:200px;height:120px;box-sizing:border-box;padding:10px;background:#3b82f6}#probe{display:none}</style></head><body><div id="host"><div id="base"></div><div id="overlay" style="pointer-events:${mode.policy};${mode.extra ?? ''}">${mode.body ?? ''}</div>${mode.cover ? `<div id="cover" style="position:absolute;left:30px;top:30px;width:90px;height:50px;z-index:5;pointer-events:${mode.cover};background:#f97316"></div>` : ''}</div><button type="button" id="toggle">Toggle policy</button><button type="button" id="program">Programmatic click</button><pre id="probe">WAIT</pre></body></html>`;
          const context = await browser.newContext({
            viewport,
            deviceScaleFactor: dpr,
            colorScheme: theme,
            hasTouch: true,
          });
          const errors = [],
            requests = [];
          try {
            const page = await context.newPage();
            page.on('pageerror', (e) => errors.push(String(e)));
            await page.route('**/*', (r) => {
              requests.push(r.request().url());
              return r.abort();
            });
            await page.setContent(
              html.replace('</body>', '<script>' + driverSource + '</script></body>'),
            );
            await page.waitForFunction(() =>
              document.getElementById('probe').textContent.startsWith('{'),
            );
            const initial = JSON.parse(await page.locator('#probe').textContent());
            const steps = [];
            const snapshotHtml = () =>
              page.evaluate(() => {
                const root = document.documentElement.cloneNode(true);
                root.querySelectorAll('script').forEach((e) => e.remove());
                return '<!doctype html>' + root.outerHTML;
              });
            async function record(action, point, target, markup) {
              await page.waitForTimeout(20);
              const state = JSON.parse(await page.locator('#probe').textContent());
              steps.push({ action, point, target, state, html: markup });
            }
            for (const sample of mode.points ?? [
              { x: 30, y: 30 },
              { x: 230, y: 150 },
            ]) {
              let point;
              if (sample.selector) {
                const r = await page.locator(sample.selector).evaluate((e) => {
                  const r = e.getClientRects()[0];
                  return { x: r.x, y: r.y, width: r.width, height: r.height };
                });
                point = {
                  x: r.x + (sample.first ? Math.min(4, r.width / 2) : r.width / 2),
                  y: r.y + r.height / 2,
                };
              } else point = { x: sample.x, y: sample.y };
              const target = await page.evaluate(
                (p) => document.elementFromPoint(p.x, p.y)?.id ?? '',
                point,
              );
              const markup = await snapshotHtml();
              await page.touchscreen.tap(point.x, point.y);
              await record('tap', point, target, markup);
            }
            if (mode.dynamic) {
              for (const desired of ['auto', 'none']) {
                await page.locator('#toggle').tap();
                await page.waitForFunction(
                  (v) => JSON.parse(document.getElementById('probe').textContent).phase === v,
                  desired,
                );
                await record('toggle', null, null, await snapshotHtml());
                const point = { x: 30, y: 30 },
                  target = await page.evaluate(
                    (p) => document.elementFromPoint(p.x, p.y).id,
                    point,
                  ),
                  markup = await snapshotHtml();
                await page.touchscreen.tap(point.x, point.y);
                await record('tap', point, target, markup);
              }
            }
            if (mode.programmatic) {
              await page.locator('#program').tap();
              await page.waitForFunction(
                () => JSON.parse(document.getElementById('probe').textContent).phase === 'program',
              );
              await record('program', null, null, await snapshotHtml());
            }
            const png = (await page.screenshot()).toString('base64');
            const paint = await page.evaluate(
              async ({ png, dpr }) => {
                const b = await createImageBitmap(
                  new Blob([Uint8Array.from(atob(png), (c) => c.charCodeAt(0))], {
                    type: 'image/png',
                  }),
                );
                const c = document.createElement('canvas');
                c.width = b.width;
                c.height = b.height;
                const x = c.getContext('2d');
                x.drawImage(b, 0, 0);
                b.close();
                return [...x.getImageData(190 * dpr, 110 * dpr, 1, 1).data];
              },
              { png, dpr },
            );
            if (errors.length || requests.length) throw Error(JSON.stringify({ errors, requests }));
            cases.push({
              name: mode.name,
              viewport,
              dpr,
              theme,
              html,
              initial,
              steps,
              paint: { x: 190, y: 110, rgba: paint },
              errors,
              requests,
            });
          } finally {
            await context.close();
          }
        }
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-pointer-events-chromium153.json', import.meta.url),
    JSON.stringify({ schemaVersion: 1, browserVersion: browser.version(), driverSource, cases }) +
      '\n',
  );
  console.log(
    JSON.stringify({
      cases: cases.length,
      modes: modes.map((m) => m.name),
      browserVersion: browser.version(),
    }),
  );
} finally {
  await browser.close();
}
