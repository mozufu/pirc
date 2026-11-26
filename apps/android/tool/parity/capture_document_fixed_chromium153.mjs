import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';
const { chromium } = createRequire(import.meta.url)('playwright-core');
const modes = [
  'top_left',
  'bottom_right',
  'percent',
  'stretch',
  'clipped_ancestor',
  'nested_scroll',
  'short_document',
  'fixed_button',
  'fixed_button_ua',
  'fixed_canvas',
  'absolute_child',
  'overlap_z',
  'pointer_none',
  'hidden_dynamic',
  'resize',
];
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
          const short = mode === 'short_document',
            clipped = mode === 'clipped_ancestor' || mode === 'nested_scroll';
          const position =
            mode === 'bottom_right' || short || mode === 'resize'
              ? 'right:17px;bottom:23px'
              : mode === 'percent'
                ? 'left:10%;top:20%'
                : mode === 'stretch'
                  ? 'inset:10px 20px 30px 40px'
                  : 'left:17px;top:23px';
          const size =
            mode === 'percent'
              ? 'width:25%;height:20%;padding:2%;border:2px solid #111'
              : mode === 'stretch'
                ? ''
                : mode === 'absolute_child'
                  ? 'width:100px;height:70px'
                  : 'width:60px;height:40px';
          const tag = mode.startsWith('fixed_button')
            ? 'button'
            : mode === 'fixed_canvas'
              ? 'canvas'
              : 'div';
          const fixed = `<${tag} id="fixed" ${tag === 'button' ? 'type="button"' : tag === 'canvas' ? 'width="60" height="40"' : ''} style="position:fixed;${position};${size};background:#3b82f6;${mode === 'pointer_none' ? 'pointer-events:none;' : ''}${mode === 'fixed_button' ? 'padding:0;border:0;' : ''}">${mode === 'absolute_child' ? '<div id="inside" style="position:absolute;left:10px;top:10px;width:20px;height:10px;background:#f97316"></div>' : tag === 'button' ? 'Tap' : ''}</${tag}>`;
          const html = `<!doctype html><html id="root"><head><style>html,body{margin:0;padding:0;font:16px/20px monospace;background:#22c55e}#advance{position:fixed;left:0;bottom:0;width:120px;height:24px;padding:0;border:0;z-index:1000}#probe{display:none}</style></head><body id="body"><div id="outer" style="padding:${short ? '0' : '40px 0 0 40px'}"><div id="host" style="position:relative;width:${clipped ? '80' : '200'}px;height:${short ? '40' : clipped ? '50' : '120'}px;${clipped ? 'overflow:hidden;' : ''}background:#334155;${mode === 'hidden_dynamic' ? 'display:none;' : ''}">${fixed}${mode === 'nested_scroll' ? '<div style="height:400px"></div>' : ''}</div></div><div id="filler" style="height:${short ? '0' : '2200'}px"></div>${mode === 'overlap_z' ? '<div id="absolute" style="position:absolute;left:17px;top:23px;width:60px;height:40px;background:#f97316;z-index:3"></div>' : ''}<button id="advance" type="button">Advance</button><pre id="probe">WAIT</pre></body></html>`;
          const driverSource = `(function(){var phase=0,clicks=[];
   function rect(e){var r=e.getBoundingClientRect();return{x:r.x,y:r.y,width:r.width,height:r.height};}
   function report(){var boxes={};['fixed','host','filler','inside','absolute'].forEach(function(id){var e=document.getElementById(id);if(e)boxes[id]=rect(e);});document.getElementById('probe').textContent=JSON.stringify({phase:phase,viewport:{width:window.innerWidth,height:window.innerHeight},hostScrollTop:document.getElementById('host').scrollTop,scrollY:window.scrollY,scrollHeight:document.documentElement.scrollHeight,boxes:boxes,clicks:clicks});}
   document.querySelectorAll('[id]').forEach(function(e){if(['advance','probe'].includes(e.id))return;e.addEventListener('click',function(event){if(event.currentTarget===event.target){clicks.push(e.id);requestAnimationFrame(report);}});});
   document.getElementById('advance').onclick=function(){phase++;if(phase===1){window.scrollTo(0,180);${mode === 'nested_scroll' ? "document.getElementById('host').scrollTop=60;" : ''}}else{${mode === 'hidden_dynamic' ? "document.getElementById('host').style.display='block';" : "var f=document.getElementById('fixed');f.style.left='41px';f.style.top='45px';f.style.width='80px';f.style.height='55px';"}}requestAnimationFrame(report);};
   window.addEventListener('resize',function(){requestAnimationFrame(report);});requestAnimationFrame(report);
  })();`;
          const context = await browser.newContext({
            viewport,
            deviceScaleFactor: dpr,
            colorScheme: theme,
            hasTouch: true,
          });
          const errors = [],
            requests = [];
          try {
            await context.route('**/*', (r) => {
              requests.push(r.request().url());
              return r.abort();
            });
            const page = await context.newPage();
            page.on('pageerror', (e) => errors.push(String(e)));
            await page.setContent(
              html.replace('</body>', '<script>' + driverSource + '</script></body>'),
            );
            await page.waitForFunction(() =>
              document.getElementById('probe').textContent.startsWith('{'),
            );
            const states = [];
            async function record() {
              await page.waitForTimeout(30);
              const state = JSON.parse(await page.locator('#probe').textContent());
              const markup = await page.evaluate(() => {
                const root = document.documentElement.cloneNode(true);
                root.querySelectorAll('script').forEach((e) => e.remove());
                return '<!doctype html>' + root.outerHTML;
              });
              const box = state.boxes.inside ?? state.boxes.fixed;
              const point = box.width ? { x: box.x + 5, y: box.y + 5 } : { x: 60, y: 60 };
              const target = await page.evaluate(
                (p) => document.elementFromPoint(p.x, p.y)?.id ?? '',
                point,
              );
              const png = (await page.screenshot()).toString('base64');
              const rgba = await page.evaluate(
                async ({ png, dpr, point }) => {
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
                  return [
                    ...x.getImageData(Math.floor(point.x * dpr), Math.floor(point.y * dpr), 1, 1)
                      .data,
                  ];
                },
                { png, dpr, point },
              );
              states.push({
                state,
                html: markup,
                viewport: page.viewportSize(),
                point,
                target,
                rgba,
              });
            }
            await record();
            await page.locator('#advance').tap();
            await page.waitForFunction(
              () => JSON.parse(document.getElementById('probe').textContent).phase === 1,
            );
            await record();
            if (mode === 'resize') {
              await page.setViewportSize({
                width: viewport.width + 40,
                height: viewport.height - 80,
              });
              await page.waitForTimeout(50);
              await record();
            }
            await page.locator('#advance').tap();
            await page.waitForFunction(
              () => JSON.parse(document.getElementById('probe').textContent).phase === 2,
            );
            await record();
            if (errors.length || requests.length) throw Error(JSON.stringify({ errors, requests }));
            cases.push({
              mode,
              viewport,
              dpr,
              theme,
              html,
              driverSource,
              states,
              errors,
              requests,
            });
          } finally {
            await context.close();
          }
        }
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-fixed-chromium153.json', import.meta.url),
    JSON.stringify({ schemaVersion: 1, browserVersion: browser.version(), cases }) + '\n',
  );
  console.log(JSON.stringify({ cases: cases.length, browserVersion: browser.version() }));
} finally {
  await browser.close();
}
