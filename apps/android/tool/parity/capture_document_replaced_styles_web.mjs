import { requireTestBrowserExecutable } from './test_browser.mjs';
import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';

const outputPath = new URL(
  '../../../../packages/pirc_render/test/fixtures/parity/document-replaced-styles-chromium153.json',
  import.meta.url,
);
const gatewayRequire = createRequire(
  new URL('../../../../package.json', import.meta.url),
);
const { chromium } = gatewayRequire('playwright-core');

const viewports = [
  { width: 390, height: 844 },
  { width: 768, height: 1024 },
];
const deviceScaleFactor = 1;
const commonStyles =
  'html,body{scrollbar-width:none}*::-webkit-scrollbar{width:0;height:0}';
const pngData =
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAAAgCAYAAACinX6EAAAAQUlEQVR42u3QMQEAAAQAMGW0UlM+erBjBRbZNZ+FAAECBAgQIECAAAECBAgQIECAAAECBAgQIECAAAECBAgQcN8Cap6pADGo7g8AAAAASUVORK5CYII=';

const cases = [
  {
    name: 'intrinsic_replaced_defaults_and_html_dimensions',
    purpose:
      'Captures default canvas size, intrinsic PNG image size, and explicit HTML image width/height attributes.',
    styles: 'body{margin:0}',
    body:
      '<canvas id="defaultCanvas"></canvas><img id="intrinsicImage" src="' +
      pngData +
      '"><img id="attributeImage" src="' +
      pngData +
      '" width="96" height="48">',
    targets: ['defaultCanvas', 'intrinsicImage', 'attributeImage'],
  },
  {
    name: 'replaced_content_box_and_border_box_edges',
    purpose:
      'Captures content-box and border-box replaced dimensions with padding, border, and margins.',
    styles:
      'body{margin:0}#contentCanvas{width:100px;height:50px;padding:4px;border:2px solid;margin:3px}#borderBoxImage{box-sizing:border-box;width:120px;height:60px;padding:5px;border:3px solid;margin:6px}',
    body:
      '<canvas id="contentCanvas"></canvas><img id="borderBoxImage" src="' +
      pngData +
      '">',
    targets: ['contentCanvas', 'borderBoxImage'],
  },
  {
    name: 'replaced_percentage_dimensions_in_padded_containing_block',
    purpose:
      'Captures percentage image dimensions against a definite content box inside a bordered and padded parent.',
    styles:
      'body{margin:0}#percentageParent{width:200px;height:100px;padding:10px;border:2px solid}#percentageImage{width:50%;height:50%}',
    body:
      '<div id="percentageParent"><img id="percentageImage" src="' +
      pngData +
      '"></div>',
    targets: ['percentageParent', 'percentageImage'],
  },
  {
    name: 'replaced_intrinsic_overflow_and_max_width_fit',
    purpose:
      'Captures intrinsic canvas and image overflow in narrow parents, plus explicit max-width fitting for an image.',
    styles:
      'body{margin:0}#canvasParent{width:120px}#imageParent,#fittedParent{width:30px}#fittedImage{max-width:100%;height:auto}',
    body:
      '<div id="canvasParent"><canvas id="overflowCanvas"></canvas></div><div id="imageParent"><img id="overflowImage" src="' +
      pngData +
      '"></div><div id="fittedParent"><img id="fittedImage" src="' +
      pngData +
      '"></div>',
    targets: [
      'canvasParent', 'overflowCanvas',
      'imageParent', 'overflowImage',
      'fittedParent', 'fittedImage',
    ],
  },
  {
    name: 'block_and_display_none_replaced_elements',
    purpose:
      'Captures fixed block canvas dimensions and computed dimensions of a hidden image.',
    styles:
      'body{margin:0}#blockCanvas{display:block;width:80px;height:40px}#hiddenImage{display:none;width:90px;height:auto}',
    body:
      '<canvas id="blockCanvas"></canvas><img id="hiddenImage" src="' +
      pngData +
      '">',
    targets: ['blockCanvas', 'hiddenImage'],
  },
  {
    name: 'block_replaced_auto_sizing_in_narrow_parents',
    purpose:
      'Captures auto-sized block canvas and images in narrower parents, including explicit max-width fitting.',
    styles:
      'body{margin:0}#canvasAutoParent{width:120px}#intrinsicImageAutoParent,#fittedImageAutoParent{width:30px}#blockAutoCanvas,#blockAutoImage{display:block}#blockFittedImage{display:block;max-width:100%;height:auto}#blockBorderBoxCanvas{display:block;box-sizing:border-box;width:100px;height:50px;padding:4px;border:2px solid;margin:0}#blockBorderBoxImage{display:block;box-sizing:border-box;width:120px;height:60px;padding:5px;border:3px solid;margin:0}',
    body:
      '<div id="canvasAutoParent"><canvas id="blockAutoCanvas"></canvas></div><div id="intrinsicImageAutoParent"><img id="blockAutoImage" src="' +
      pngData +
      '"></div><div id="fittedImageAutoParent"><img id="blockFittedImage" src="' +
      pngData +
      '"></div><canvas id="blockBorderBoxCanvas"></canvas><img id="blockBorderBoxImage" src="' +
      pngData +
      '">',
    targets: [
      'canvasAutoParent', 'blockAutoCanvas',
      'intrinsicImageAutoParent', 'blockAutoImage',
      'fittedImageAutoParent', 'blockFittedImage',
      'blockBorderBoxCanvas', 'blockBorderBoxImage',
    ],
  },
  {
    name: 'horizontal_edges_on_inline_replaced_elements',
    purpose:
      'Captures margins and padding on intrinsic and sized inline replaced elements inside narrow text-flow parents.',
    styles:
      'body{margin:0;font-family:Arial,sans-serif;font-size:16px;line-height:20px}#inlineImageParent,#inlineCanvasParent,#inlineBorderBoxImageParent{width:30px;padding:2px;border:1px solid}#inlineNaturalImage{margin-left:8px}#inlinePaddedCanvas{padding-left:8px}#inlineBorderBoxImage{box-sizing:border-box;width:120px;height:60px;padding-left:8px;margin-left:8px}',
    body:
      '<div id="inlineImageParent"><span>a</span><img id="inlineNaturalImage" src="' +
      pngData +
      '"><span>b</span></div><div id="inlineCanvasParent"><span>a</span><canvas id="inlinePaddedCanvas"></canvas><span>b</span></div><div id="inlineBorderBoxImageParent"><span>a</span><img id="inlineBorderBoxImage" src="' +
      pngData +
      '"><span>b</span></div>',
    targets: [
      'inlineImageParent', 'inlineNaturalImage',
      'inlineCanvasParent', 'inlinePaddedCanvas',
      'inlineBorderBoxImageParent', 'inlineBorderBoxImage',
    ],
  },
  {
    name: 'block_replaced_height_driven_aspect_ratio',
    purpose:
      'Captures auto-width block canvas and image sizing from definite height and max-height constraints.',
    styles:
      'body{margin:0}#heightCanvasParent,#maxHeightCanvasParent{width:120px}#heightImageParent,#maxHeightImageParent{width:30px}#heightCanvas,#heightImage,#maxHeightCanvas,#maxHeightImage{display:block;width:auto}#heightCanvas{height:100px}#heightImage{height:50px}#maxHeightCanvas{max-height:50px}#maxHeightImage{max-height:16px}',
    body:
      '<div id="heightCanvasParent"><canvas id="heightCanvas"></canvas></div><div id="heightImageParent"><img id="heightImage" src="' +
      pngData +
      '"></div><div id="maxHeightCanvasParent"><canvas id="maxHeightCanvas"></canvas></div><div id="maxHeightImageParent"><img id="maxHeightImage" src="' +
      pngData +
      '"></div>',
    targets: [
      'heightCanvasParent', 'heightCanvas',
      'heightImageParent', 'heightImage',
      'maxHeightCanvasParent', 'maxHeightCanvas',
      'maxHeightImageParent', 'maxHeightImage',
    ],
  },
];

const properties = [
  'display',
  'box-sizing',
  'width',
  'height',
  'min-width',
  'max-width',
  'min-height',
  'max-height',
  'padding-top',
  'padding-right',
  'padding-bottom',
  'padding-left',
  'border-top-width',
  'border-right-width',
  'border-bottom-width',
  'border-left-width',
  'margin-top',
  'margin-right',
  'margin-bottom',
  'margin-left',
];

const html = (styles, body) => `<!doctype html>
<html id="html"><head><meta charset="utf-8">
<style>${commonStyles}${styles}</style></head><body id="body">${body}</body></html>`;

const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
  args: [
    '--disable-background-networking',
    '--disable-component-update',
    '--no-first-run',
  ],
});

try {
  const browserVersion = await browser.version();
  if (!browserVersion.startsWith('153.')) {
    throw new Error(`Expected dedicated Chromium 153, got ${browserVersion}`);
  }

  const outputCases = [];
  for (const item of cases) {
    const authoredHTML = html(item.styles, item.body);
    for (const viewport of viewports) {
      const context = await browser.newContext({
        viewport,
        deviceScaleFactor,
        serviceWorkers: 'block',
      });
      try {
        const page = await context.newPage();
        const pageErrors = [];
        const consoleErrors = [];
        page.on('pageerror', error =>
          pageErrors.push(error.stack || error.message),
        );
        page.on('console', message => {
          if (message.type() === 'error') consoleErrors.push(message.text());
        });
        await page.route('**/*', route => route.abort());
        await page.setContent(authoredHTML, { waitUntil: 'load' });
        await page.evaluate(async targets => {
          await Promise.all(
            targets.map(async id => {
              const element = document.getElementById(id);
              if (element instanceof HTMLImageElement && element.complete) {
                await element.decode();
              }
            }),
          );
        }, item.targets);
        await page.evaluate(
          () =>
            new Promise(resolve =>
              requestAnimationFrame(() => requestAnimationFrame(resolve)),
            ),
        );

        const result = await page.evaluate(({ targets, properties }) => {
          const expected = {};
          for (const id of targets) {
            const element = document.getElementById(id);
            if (!element) throw new Error(`Missing target #${id}`);
            const style = getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            expected[id] = {
              isConnected: element.isConnected,
              values: Object.fromEntries(
                properties.map(name => [name, style.getPropertyValue(name)]),
              ),
              rect: {
                x: rect.x,
                y: rect.y,
                width: rect.width,
                height: rect.height,
              },
              offsetWidth: element.offsetWidth,
              offsetHeight: element.offsetHeight,
              naturalWidth:
                element instanceof HTMLImageElement ? element.naturalWidth : null,
              naturalHeight:
                element instanceof HTMLImageElement ? element.naturalHeight : null,
            };
          }
          return expected;
        }, { targets: item.targets, properties });

        if (pageErrors.length) throw new Error(pageErrors.join('\n'));
        if (consoleErrors.length) throw new Error(consoleErrors.join('\n'));
        for (const id of item.targets) {
          const value = result[id];
          for (const property of properties) {
            if (typeof value.values[property] !== 'string') {
              throw new Error(`${item.name} #${id} missing ${property}`);
            }
          }
          for (const key of ['x', 'y', 'width', 'height']) {
            if (!Number.isFinite(value.rect[key])) {
              throw new Error(`${item.name} #${id} has non-finite rect.${key}`);
            }
          }
          for (const key of ['offsetWidth', 'offsetHeight']) {
            if (!Number.isFinite(value[key])) {
              throw new Error(`${item.name} #${id} has non-finite ${key}`);
            }
          }
        }

        outputCases.push({
          name: item.name,
          purpose: item.purpose,
          authoredHTML,
          styles: { common: commonStyles, case: item.styles },
          targets: item.targets,
          supportedProperties: properties,
          viewportWidth: viewport.width,
          viewportHeight: viewport.height,
          expected: result,
        });
      } finally {
        await context.close();
      }
    }
  }

  const output = {
    browserVersion,
    capture: {
      viewports,
      deviceScaleFactor,
      browserExecutable: 'dedicated chromium-headless-shell from test_browser.mjs',
      network: 'all page requests aborted; synthetic HTML and data URI PNG images only',
      scope:
        'The supportedProperties list is the selected computed-style comparison surface; rect, offsetWidth/offsetHeight, and intrinsic image dimensions are Chromium observations.',
      geometry:
        'getComputedStyle selected properties, connectedness, border-box getBoundingClientRect, offset dimensions, and image intrinsic dimensions',
    },
    cases: outputCases,
  };
  await writeFile(outputPath, `${JSON.stringify(output)}\n`);
  console.log(
    `Wrote ${outputCases.length} replaced-element observations to ${outputPath.pathname}`,
  );
} finally {
  await browser.close();
}
