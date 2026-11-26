import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';
const require = createRequire(new URL('../../../../package.json', import.meta.url));
const { chromium } = require('playwright-core');
const html =
  '<!doctype html><html><head><style>body{margin:0}#target{width:100.5px;height:40.25px;padding:3.5px 5.25px;border:2px solid}#canvas{width:80px;height:40px;padding:2px;border:1px solid}</style></head><body><div id="target"></div><canvas id="canvas"></canvas><span id="inline">text</span></body></html>';
const setup = `
window.events=[];window.phase='initial';window.observers={};
for (const [name,id,box] of [['content','target','content-box'],['border','target','border-box'],['canvas','canvas','content-box'],['inline','inline','content-box']]) {
 const observer=new ResizeObserver(function(entries,instance){
  window.events.push({phase:window.phase,name,self:this===observer,instance:instance===observer,
   entries:entries.map(e=>({id:e.target.id,rect:e.contentRect.toJSON(),
    content:Array.from(e.contentBoxSize,s=>({inlineSize:s.inlineSize,blockSize:s.blockSize})),
    border:Array.from(e.borderBoxSize,s=>({inlineSize:s.inlineSize,blockSize:s.blockSize})),
    entryType:e instanceof ResizeObserverEntry,sizeType:e.contentBoxSize[0] instanceof ResizeObserverSize,
    frozenContent:Object.isFrozen(e.contentBoxSize),frozenBorder:Object.isFrozen(e.borderBoxSize)}))});
 });
 window.observers[name]=observer;observer.nativeTestTarget=id;observer.nativeTestBox=box;
}
for(const o of Object.values(window.observers).reverse())o.observe(document.getElementById(o.nativeTestTarget),{box:o.nativeTestBox});
`;
const steps = [
  { name: 'initial', code: '' },
  { name: 'same', code: "document.getElementById('target').style.width='100.5px'" },
  {
    name: 'repeat-observe',
    code: "window.observers.content.observe(document.getElementById('target'))",
  },
  { name: 'width', code: "document.getElementById('target').style.width='130.75px'" },
  { name: 'padding', code: "document.getElementById('target').style.paddingLeft='8.5px'" },
  { name: 'border', code: "document.getElementById('target').style.borderLeftWidth='4px'" },
  {
    name: 'observe-other-box',
    code: "window.observers.content.observe(document.getElementById('target'),{box:'border-box'})",
  },
  { name: 'hidden', code: "document.getElementById('target').style.display='none'" },
  { name: 'shown', code: "document.getElementById('target').style.display='block'" },
  {
    name: 'unobserve',
    code: "window.observers.content.unobserve(document.getElementById('target'));document.getElementById('target').style.width='140px'",
  },
  {
    name: 'reobserve',
    code: "window.observers.content.observe(document.getElementById('target'))",
  },
  {
    name: 'disconnect',
    code: "Object.values(window.observers).forEach(o=>o.disconnect());document.getElementById('target').style.width='150px'",
  },
];
const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
});
const records = [];
let callbackInteractions;
try {
  for (const viewport of [
    { width: 390, height: 844 },
    { width: 768, height: 1024 },
  ]) {
    const context = await browser.newContext({
      viewport,
      deviceScaleFactor: 1,
      colorScheme: 'light',
    });
    await context.route('**/*', (route) => route.abort());
    try {
      const page = await context.newPage();
      if (!callbackInteractions) {
        await page.setContent('<div id="target" style="width:100px;height:40px"></div>');
        callbackInteractions = await page.evaluate(async () => {
          const result = {};
          for (const op of ['disconnect', 'unobserve', 'reobserve']) {
            const calls = [],
              target = document.getElementById('target');
            let second;
            const first = new ResizeObserver(() => {
              calls.push('first');
              if (op === 'disconnect') second.disconnect();
              if (op === 'unobserve') second.unobserve(target);
              if (op === 'reobserve') second.observe(target, { box: 'border-box' });
            });
            second = new ResizeObserver(() => calls.push('second'));
            first.observe(target);
            second.observe(target);
            await new Promise((resolve) =>
              requestAnimationFrame(() => requestAnimationFrame(resolve)),
            );
            first.disconnect();
            second.disconnect();
            result[op] = calls;
          }
          return result;
        });
      }
      await page.setContent(html);
      await page.evaluate(setup);
      const stages = [];
      for (const step of steps) {
        await page.evaluate(({ name, code }) => {
          window.phase = name;
          if (code) (0, eval)(code);
        }, step);
        await page.evaluate(
          () =>
            new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))),
        );
        stages.push(
          await page.evaluate(
            (name) => ({
              name,
              html: document.documentElement.outerHTML,
              events: window.events.splice(0),
              boxes: ['target', 'canvas', 'inline'].map((id) => {
                const e = document.getElementById(id),
                  s = getComputedStyle(e),
                  r = e.getBoundingClientRect();
                const none =
                  s.display === 'none' || (s.display === 'inline' && e.tagName !== 'CANVAS');
                const px = (name) => parseFloat(s.getPropertyValue(name));
                return {
                  id,
                  kind: s.display === 'none' ? 'none' : 'box',
                  x: r.x,
                  y: r.y,
                  width: r.width,
                  height: r.height,
                  resize: none
                    ? { kind: 'none' }
                    : {
                        kind: 'box',
                        contentRect: {
                          x: px('padding-left'),
                          y: px('padding-top'),
                          width:
                            r.width -
                            px('padding-left') -
                            px('padding-right') -
                            px('border-left-width') -
                            px('border-right-width'),
                          height:
                            r.height -
                            px('padding-top') -
                            px('padding-bottom') -
                            px('border-top-width') -
                            px('border-bottom-width'),
                        },
                        borderBoxSize: { inlineSize: r.width, blockSize: r.height },
                      },
                };
              }),
            }),
            step.name,
          ),
        );
      }
      records.push({ viewport, stages });
    } finally {
      await context.close();
    }
  }
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-resize-chromium153.json', import.meta.url),
    JSON.stringify({
      browser: browser.version(),
      html,
      setup,
      steps,
      records,
      callbackInteractions,
    }) + '\n',
  );
  console.log(
    `Captured ${records.length} viewports, ${steps.length} stages each; external requests blocked.`,
  );
} finally {
  await browser.close();
}
