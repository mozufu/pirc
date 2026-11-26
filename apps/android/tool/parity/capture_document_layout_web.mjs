import { requireTestBrowserExecutable } from './test_browser.mjs';
import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';

const outputPath = new URL('../../../../packages/pirc_render/test/fixtures/parity/document-layout-chromium153.json', import.meta.url);
const gatewayRequire = createRequire(new URL('../../../gateway/package.json', import.meta.url));
const { chromium } = gatewayRequire('playwright-core');

const viewportWidths = [390, 768];
const viewportHeight = 1000;
const themes = ['light', 'dark'];
const deviceScaleFactor = 1;

const page = (style, body) => `<!doctype html>
<html><head><meta name="color-scheme" content="light dark"><meta charset="utf-8">
<style>${style}</style></head><body>${body}</body></html>`;

const svg = 'data:image/svg+xml,%3Csvg xmlns="http://www.w3.org/2000/svg" width="30" height="16" viewBox="0 0 30 16"%3E%3Crect width="30" height="16" fill="%23336699"/%3E%3C/svg%3E';

const cases = [
  {
    name: 'fixed_percent_nested_boxes',
    html: page(
      'body{margin:0} #outer{width:240px;height:150px;margin:7px 9px;padding:10px 12px;border:2px solid} #percent{width:50%;height:50%;margin:3px;padding:4px;border:1px solid} #nested{width:25%;height:30px;margin:2px;padding:2px;border:1px solid}',
      '<div id="outer"><div id="percent"><div id="nested"></div></div></div>',
    ),
    targets: ['outer', 'percent', 'nested'],
  },
  {
    name: 'content_box_and_border_box',
    html: page(
      'body{margin:0} .box{width:120px;height:60px;margin:5px;padding:10px;border:3px solid} #content{box-sizing:content-box} #border{box-sizing:border-box}',
      '<div id="content" class="box"></div><div id="border" class="box"></div>',
    ),
    targets: ['content', 'border'],
  },
  {
    name: 'min_max_constraints',
    html: page(
      'body{margin:0} #min-width{width:80px;min-width:130px;max-width:180px;height:24px} #max-width{width:240px;min-width:100px;max-width:160px;height:24px} #min-height{width:24px;height:40px;min-height:90px;max-height:120px} #max-height{width:24px;height:160px;min-height:80px;max-height:110px}',
      '<div id="min-width"></div><div id="max-width"></div><div id="min-height"></div><div id="max-height"></div>',
    ),
    targets: ['min-width', 'max-width', 'min-height', 'max-height'],
  },
  {
    name: 'flex_row',
    html: page(
      'body{margin:0} #row{display:flex;align-items:stretch;gap:10px;width:300px;height:100px;padding:5px;border:2px solid} #row-a{flex:1 1 0;min-width:0} #row-b{flex:2 1 0;min-width:0} #row-c{flex:none;width:50px}',
      '<div id="row"><div id="row-a"></div><div id="row-b"></div><div id="row-c"></div></div>',
    ),
    targets: ['row', 'row-a', 'row-b', 'row-c'],
  },
  {
    name: 'flex_column',
    html: page(
      'body{margin:0} #column{display:flex;flex-direction:column;gap:8px;width:180px;height:220px;padding:6px;border:2px solid} #column-a{flex:1 1 0;min-height:0} #column-b{flex:2 1 0;min-height:0} #column-c{flex:none;height:30px}',
      '<div id="column"><div id="column-a"></div><div id="column-b"></div><div id="column-c"></div></div>',
    ),
    targets: ['column', 'column-a', 'column-b', 'column-c'],
  },
  {
    name: 'display_none_descendants',
    html: page(
      'body{margin:0} #hidden{display:none;width:120px;height:70px;padding:8px;border:2px solid} #hidden-child{width:40px;height:20px} #shown{width:80px;height:30px;margin-top:12px}',
      '<div id="hidden"><div id="hidden-child"></div></div><div id="shown"></div>',
    ),
    targets: ['hidden', 'hidden-child', 'shown'],
  },
  {
    name: 'offscreen_boxes_after_scroll',
    html: page(
      'body{margin:0} #before{height:80px} #spacer{height:1100px} #offscreen{width:70px;height:45px;margin:4px;padding:3px;border:2px solid} #after{height:50px}',
      '<div id="before"></div><div id="spacer"></div><div id="offscreen"></div><div id="after"></div>',
    ),
    targets: ['before', 'offscreen', 'after'],
    scrollY: 120,
  },
  {
    name: 'initial_document_root_and_body',
    html: '<!doctype html><html id="root"><head><meta charset="utf-8"></head><body id="body"></body></html>',
    targets: ['root', 'body'],
  },
  {
    name: 'native_controls_fixed_dimensions',
    html: page(
      'body{margin:0} #controls{display:flex;align-items:flex-start;gap:8px} input,button,select,textarea{box-sizing:border-box;width:150px;height:42px;margin:0;padding:4px;border:2px solid;font:14px Arial,sans-serif} textarea{resize:none}',
      '<div id="controls"><input id="input" type="text" value="sample"><button id="button" type="button">button</button><select id="select"><option>option</option></select><textarea id="textarea">sample</textarea></div>',
    ),
    targets: ['controls', 'input', 'button', 'select', 'textarea'],
  },
  {
    name: 'inline_canvas_and_image_with_and_without_padding',
    html: page(
      'body{margin:0} .line{font-size:0;line-height:0;white-space:nowrap} #padded{margin:11px;padding:9px 13px;border:2px solid} canvas,img{vertical-align:baseline}',
      `<div id="plain" class="line"><canvas id="canvas-plain" width="40" height="20"></canvas><img id="image-plain" width="30" height="16" src="${svg}"></div><div id="padded" class="line"><canvas id="canvas-padded" width="40" height="20"></canvas><img id="image-padded" width="30" height="16" src="${svg}"></div>`,
    ),
    targets: ['plain', 'canvas-plain', 'image-plain', 'padded', 'canvas-padded', 'image-padded'],
  },
  {
    name: 'inline_text_wrapping_unsupported_native',
    html: page(
      'body{margin:0} #wrapper{width:140px;padding:4px;border:1px solid;font:16px/20px Arial,sans-serif;white-space:normal} #wrapped{white-space:normal}',
      '<div id="wrapper"><span id="wrapped">alpha beta gamma delta epsilon zeta eta theta iota kappa</span></div>',
    ),
    targets: ['wrapper', 'wrapped'],
    nativeSupport: 'unsupported',
  },
];

function assertFiniteRect(rect, label) {
  for (const key of ['x', 'y', 'width', 'height', 'top', 'right', 'bottom', 'left']) {
    if (!Number.isFinite(rect[key])) throw new Error(`${label} has a non-finite ${key}: ${rect[key]}`);
  }
}

const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
});

try {
  const outputCases = [];
  for (const item of cases) {
    for (const viewportWidth of viewportWidths) {
      for (const theme of themes) {
        const context = await browser.newContext({
          viewport: { width: viewportWidth, height: viewportHeight },
          deviceScaleFactor,
          colorScheme: theme,
          serviceWorkers: 'block',
        });
        try {
          const page = await context.newPage();
          const pageErrors = [];
          const consoleErrors = [];
          page.on('pageerror', error => pageErrors.push(error.stack || error.message));
          page.on('console', message => {
            if (message.type() === 'error') consoleErrors.push(message.text());
          });
          await page.route('**/*', route => route.abort());
          await page.setContent(item.html, { waitUntil: 'load' });
          await page.evaluate(() => document.fonts.ready);
          await page.evaluate(async scrollY => {
            if (scrollY) window.scrollTo(0, scrollY);
            await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
          }, item.scrollY ?? 0);

          const measured = await page.evaluate(targets => {
            const result = {};
            for (const id of targets) {
              const element = document.getElementById(id);
              if (!element) throw new Error(`Missing target #${id}`);
              const rect = element.getBoundingClientRect();
              result[id] = {
                rect: rect.toJSON(),
                clientRects: Array.from(element.getClientRects(), item => item.toJSON()),
                clientWidth: element.clientWidth,
                clientHeight: element.clientHeight,
                clientLeft: element.clientLeft,
                clientTop: element.clientTop,
                offsetWidth: element.offsetWidth,
                offsetHeight: element.offsetHeight,
                scrollX: window.scrollX,
                scrollY: window.scrollY,
              };
            }
            return result;
          }, item.targets);

          if (pageErrors.length) throw new Error(pageErrors.join('\n'));
          if (consoleErrors.length) throw new Error(consoleErrors.join('\n'));
          for (const id of item.targets) {
            const target = measured[id];
            assertFiniteRect(target.rect, `${item.name} #${id}`);
            for (const rect of target.clientRects) assertFiniteRect(rect, `${item.name} #${id} client rect`);
            for (const key of ['clientWidth', 'clientHeight', 'clientLeft', 'clientTop', 'offsetWidth', 'offsetHeight', 'scrollX', 'scrollY']) {
              if (!Number.isFinite(target[key])) throw new Error(`${item.name} #${id} has a non-finite ${key}`);
            }
          }

          const actualScrollY = measured[item.targets[0]].scrollY;
          if (actualScrollY !== (item.scrollY ?? 0)) {
            throw new Error(`${item.name} requested scrollY=${item.scrollY ?? 0} but browser reached ${actualScrollY}`);
          }
          outputCases.push({
            name: item.name,
            html: item.html,
            targets: item.targets,
            viewportWidth,
            theme,
            ...(item.scrollY === undefined ? {} : { scrollY: item.scrollY }),
            ...(item.nativeSupport === undefined ? {} : { nativeSupport: item.nativeSupport }),
            expected: measured,
          });
        } finally {
          await context.close();
        }
      }
    }
  }

  const fixture = {
    browserVersion: await browser.version(),
    viewport: { height: viewportHeight, deviceScaleFactor, widths: viewportWidths, themes },
    cases: outputCases,
  };
  await writeFile(outputPath, `${JSON.stringify(fixture, null, 2)}\n`);
  console.log(`Captured ${cases.length} cases (${outputCases.length} viewport/theme entries) with Chromium ${fixture.browserVersion}: ${outputPath.pathname}`);
} finally {
  await browser.close();
}
