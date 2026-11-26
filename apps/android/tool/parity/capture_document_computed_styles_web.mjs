import { requireTestBrowserExecutable } from './test_browser.mjs';
import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';

const outputPath = new URL(
  '../../../../packages/pirc_render/test/fixtures/parity/document-computed-styles-chromium153.json',
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
const commonStyles = 'html,body{scrollbar-width:none}*::-webkit-scrollbar{width:0;height:0}';

const html = (styles, body) => `<!doctype html>
<html id="html"><head><meta charset="utf-8">
<style>${commonStyles}${styles}</style></head><body id="body">${body}</body></html>`;

const cases = [
  {
    name: 'ua_defaults_and_block_inline_elements',
    purpose:
      'Captures Chromium UA defaults for root/body, common block and inline elements, headings, lists, and a form control.',
    styles: '',
    body:
      '<div id="block"></div><span id="inline"></span><p id="paragraph">Text</p><h1 id="heading">Heading</h1><button id="button" type="button">Go</button><ul id="list"><li id="listItem">Item</li></ul>',
    targets: ['html', 'body', 'block', 'inline', 'paragraph', 'heading', 'button', 'list', 'listItem'],
    properties: [
      'display', 'position', 'box-sizing', 'color', 'background-color',
      'font-family', 'font-size', 'font-weight', 'font-style', 'line-height',
      'margin-top', 'margin-right', 'margin-bottom', 'margin-left',
      'padding-top', 'padding-left', 'width', 'height', 'list-style-type',
      'white-space', 'visibility',
    ],
  },
  {
    name: 'font_shorthand_inheritance_em_rem_and_line_height',
    purpose:
      'Captures font shorthand expansion, inherited typography, em/rem sizes, and normal, unitless, and length line heights.',
    styles:
      'html{font-size:10px}body{margin:0;font:400 1.4rem/1.5 serif}#parent{font-size:20px;line-height:normal}#emChild{font-size:1.25em;line-height:1.4}#remChild{font-size:1.8rem;line-height:2}#shorthand{font:italic 700 18px/1.3 sans-serif}#inherited{letter-spacing:1.25px}',
    body:
      '<div id="parent"><span id="emChild"></span><span id="remChild"></span><span id="inherited"></span></div><div id="shorthand"></div>',
    targets: ['html', 'body', 'parent', 'emChild', 'remChild', 'inherited', 'shorthand'],
    properties: [
      'font', 'font-family', 'font-size', 'font-weight', 'font-style',
      'font-variant', 'font-stretch', 'line-height', 'letter-spacing',
      'word-spacing', 'text-transform',
    ],
  },
  {
    name: 'flex_and_grid_inline_items_are_blockified',
    purpose:
      'Captures computed display and used width/height for default inline spans that become direct flex and grid items.',
    styles:
      'body{margin:0}#flexParent{display:flex;width:300px;height:80px;gap:0}#flexFixed{width:40px;height:20px}#flexStretch{flex:1}#gridParent{display:grid;width:300px;height:80px;grid-template-columns:80px 1fr;grid-template-rows:80px;gap:0}#gridFixed{grid-column:1;width:40px;height:20px}#gridStretch{grid-column:2}',
    body:
      '<div id="flexParent"><span id="flexFixed"></span><span id="flexStretch"></span></div><div id="gridParent"><span id="gridFixed"></span><span id="gridStretch"></span></div>',
    targets: [
      'flexParent', 'flexFixed', 'flexStretch',
      'gridParent', 'gridFixed', 'gridStretch',
    ],
    properties: ['display', 'width', 'height', 'position', 'box-sizing'],
  },
  {
    name: 'color_current_color_and_rgba_serialization',
    purpose:
      'Captures computed color serialization, currentColor resolution, alpha colors, transparency, and opacity.',
    styles:
      'body{margin:0;color:rgb(12,34,56)}#base{color:rgb(20,40,60);border:2px solid currentColor}#rgba{color:rgba(10,20,30,.4);background-color:rgba(200,100,50,.25);border:1px solid currentColor}#inherit{color:inherit;background-color:currentColor}#transparent{color:transparent;opacity:.5}',
    body:
      '<div id="base"></div><div id="rgba"></div><div id="inherit"></div><div id="transparent"></div>',
    targets: ['body', 'base', 'rgba', 'inherit', 'transparent'],
    properties: [
      'color', 'background-color', 'border-top-color', 'border-right-color',
      'border-bottom-color', 'border-left-color', 'opacity', 'fill',
    ],
  },
  {
    name: 'content_box_and_border_box_dimensions',
    purpose:
      'Captures computed width/height and actual border-box rectangles for content-box and border-box sizing.',
    styles:
      'body{margin:0}#contentBox{box-sizing:content-box;width:120px;height:50px;padding:10px 12px;border:3px solid;margin:4px}#borderBox{box-sizing:border-box;width:120px;height:50px;padding:10px 12px;border:3px solid;margin:4px}',
    body: '<div id="contentBox"></div><div id="borderBox"></div>',
    targets: ['contentBox', 'borderBox'],
    properties: [
      'display', 'box-sizing', 'width', 'height', 'min-width', 'max-width',
      'min-height', 'max-height', 'padding-top', 'padding-right',
      'padding-bottom', 'padding-left', 'border-top-width',
      'border-right-width', 'margin-top', 'margin-left',
    ],
  },
  {
    name: 'percentage_margin_padding_use_containing_block_width',
    purpose:
      'Captures percentage width, margins, and padding against a containing block whose content width changes with viewport size.',
    styles:
      'body{margin:0}#container{box-sizing:content-box;width:80%;padding:0 20px 0 12px;border:2px solid}#child{box-sizing:content-box;width:50%;margin-left:10%;margin-top:5%;padding-left:5%;border-left:1px solid}',
    body: '<div id="container"><div id="child"></div></div>',
    targets: ['container', 'child'],
    properties: [
      'box-sizing', 'width', 'height', 'margin-top', 'margin-right',
      'margin-bottom', 'margin-left', 'padding-top', 'padding-right',
      'padding-bottom', 'padding-left', 'border-left-width',
    ],
  },
  {
    name: 'relative_insets_and_directional_overconstraint',
    purpose:
      'Captures resolved relative insets, used positions, and parent-direction precedence when left and right are both specified.',
    styles:
      'body{margin:0}#ltrParent,#rtlParent{box-sizing:content-box;width:200px;height:100px;border:1px solid;margin-bottom:12px}#rtlParent{direction:rtl}#ltrSubject,#rtlSubject{position:relative;top:10%;right:25px;bottom:8%;left:15px;width:40px;height:20px}#rtlSubject{direction:ltr}',
    body:
      '<div id="ltrParent"><div id="ltrSubject"></div></div><div id="rtlParent"><div id="rtlSubject"></div></div>',
    targets: ['ltrParent', 'ltrSubject', 'rtlParent', 'rtlSubject'],
    properties: [
      'display', 'position', 'direction', 'top', 'right', 'bottom', 'left',
      'width', 'height', 'margin-top', 'margin-left',
    ],
  },
  {
    name: 'relative_insets_with_auto_height_containing_block',
    purpose:
      'Captures percentage vertical and horizontal relative insets in an auto-height containing block, plus auto-sided inset resolution.',
    styles:
      'body{margin:0}#autoParent{box-sizing:content-box;width:300px;border:1px solid}#percentSubject{position:relative;top:25%;left:10%;width:40px;height:20px}#autoSides{position:relative;top:auto;right:12px;bottom:8px;left:auto;width:30px;height:15px}',
    body:
      '<div id="autoParent"><div id="percentSubject"></div><div id="autoSides"></div></div>',
    targets: ['autoParent', 'percentSubject', 'autoSides'],
    properties: [
      'position', 'top', 'right', 'bottom', 'left', 'width', 'height',
      'margin-top', 'margin-left',
    ],
  },
  {
    name: 'display_none_and_disconnected_elements',
    purpose:
      'Captures computed styles retained for a display:none descendant and the actual style values for removed and never-connected elements.',
    styles:
      'body{margin:0}.hiddenParent{display:none}.hiddenChild{display:block;width:77px;height:13px;color:rgb(9,18,27);--token: hidden}.detachedStyle{display:block;width:33px;height:11px;color:rgb(70,80,90);font-size:19px}',
    body:
      '<div id="hiddenParent" class="hiddenParent"><div id="hiddenChild" class="hiddenChild"></div></div><div id="removed" class="detachedStyle"></div>',
    targets: ['hiddenParent', 'hiddenChild', 'removed', 'neverConnected'],
    properties: [
      'display', 'position', 'width', 'height', 'color', 'font-size',
      'visibility', '--token',
    ],
    detachTargets: true,
  },
  {
    name: 'custom_properties_inheritance_and_var_fallback',
    purpose:
      'Captures custom-property inheritance, nested var() resolution, a fallback, and computed use in ordinary color properties.',
    styles:
      ':root{--theme:rgb(31,63,95);--surface:rgba(80,120,160,.4)}body{margin:0}#parent{--local:var(--theme);color:var(--local)}#child{color:var(--local);background-color:var(--surface);border:2px solid currentColor}#fallback{color:var(--missing, rgb(4,5,6));--local:var(--missing, fallback-token)}',
    body:
      '<div id="parent"><div id="child"></div><div id="fallback"></div></div>',
    targets: ['html', 'body', 'parent', 'child', 'fallback'],
    properties: [
      '--theme', '--surface', '--local', '--missing', 'color',
      'background-color', 'border-top-color',
    ],
  },
  {
    name: 'cssom_readonly_declaration_and_property_iteration',
    purpose:
      'Records computed declaration length and full indexed property order plus camel-case access, getPropertyValue, priority, cssText, iteration, and attempted mutation.',
    styles:
      'body{margin:0;color:rgb(25,50,75)}#probe{box-sizing:border-box;width:120px;height:40px;padding:4px;margin:3px;background-color:rgba(10,20,30,.5);font:italic 600 16px/1.25 serif}',
    body: '<div id="probe"></div>',
    targets: ['probe'],
    properties: [
      'color', 'background-color', 'font-size', 'font-family', 'line-height',
      'margin-top', 'padding-left', 'width', 'height', 'box-sizing',
    ],
    cssomSurface: true,
  },
  {
    name: 'class_and_inline_style_mutation_update_retained_declaration',
    purpose:
      'Captures computed values before and after class and inline-style mutations using a retained and a fresh getComputedStyle declaration.',
    styles:
      'body{margin:0}.before{color:rgb(180,20,30);width:45px;background-color:rgb(240,230,220)}.after{color:rgb(20,30,180);width:90px;background-color:rgba(20,30,180,.2)}#probe{height:12px}',
    body: '<div id="probe" class="before"></div>',
    targets: ['probe'],
    properties: [
      'color', 'background-color', 'width', 'height', 'display',
      'font-size',
    ],
    mutation: {
      target: 'probe',
      className: 'after',
      inlineStyle: { height: '24px', marginLeft: '7px' },
    },
  },
];

const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
  args: [
    '--disable-background-networking',
    '--disable-component-update',
    '--no-first-run',
  ],
});

async function waitForLayout(page) {
  await page.evaluate(
    () =>
      new Promise(resolve =>
        requestAnimationFrame(() => requestAnimationFrame(resolve)),
      ),
  );
}

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
        page.on('pageerror', error => pageErrors.push(error.stack || error.message));
        page.on('console', message => {
          if (message.type() === 'error') consoleErrors.push(message.text());
        });
        await page.route('**/*', route => route.abort());
        await page.setContent(authoredHTML, { waitUntil: 'load' });
        await waitForLayout(page);

        await page.evaluate(({ detachTargets }) => {
          const detached = {};
          if (detachTargets) {
            const removed = document.getElementById('removed');
            removed.remove();
            detached.removed = removed;
            const neverConnected = document.createElement('div');
            neverConnected.id = 'neverConnected';
            neverConnected.className = 'detachedStyle';
            neverConnected.style.width = '14px';
            detached.neverConnected = neverConnected;
          }
          window.__computedStyleDetachedTargets = detached;
        }, { detachTargets: item.detachTargets === true });

        const result = await page.evaluate(async ({
          targets,
          properties,
          cssomSurface,
          mutation,
        }) => {
          const detached = window.__computedStyleDetachedTargets || {};
          const find = id => detached[id] || document.getElementById(id);
          const getRect = element => {
            const rect = element.getBoundingClientRect();
            return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
          };
          const readStyle = (element, style, names) => {
            return {
              isConnected: element.isConnected,
              values: Object.fromEntries(
                names.map(name => [name, style.getPropertyValue(name)]),
              ),
              declarationLength: style.length,
              firstItem: style.item(0),
              rect: getRect(element),
            };
          };
          const read = (element, names) =>
            readStyle(element, getComputedStyle(element), names);

          const expected = {};
          for (const id of targets) {
            const element = find(id);
            if (!element) throw new Error(`Missing target #${id}`);
            expected[id] = read(element, properties);
          }

          let cssom = null;
          if (cssomSurface) {
            const element = find('probe');
            const style = getComputedStyle(element);
            const beforeMutation = style.getPropertyValue('color');
            let mutationError = null;
            try {
              style.setProperty('color', 'rgb(1, 2, 3)');
            } catch (error) {
              mutationError = error.name;
            }
            const afterMutation = style.getPropertyValue('color');
            const propertyOrder = Array.from(
              { length: style.length },
              (_, index) => style.item(index),
            );
            const iterableNames = [...style];
            cssom = {
              length: style.length,
              propertyOrder,
              iterableLength: iterableNames.length,
              iterableFirst: iterableNames[0] ?? null,
              iterableLast: iterableNames.at(-1) ?? null,
              iterableMatchesPropertyOrder:
                iterableNames.length === propertyOrder.length &&
                iterableNames.every((name, index) => name === propertyOrder[index]),
              indexedFirst: style[0] ?? null,
              itemFirst: style.item(0),
              cssText: style.cssText,
              camelGetters: {
                color: style.color,
                backgroundColor: style.backgroundColor,
                fontSize: style.fontSize,
                lineHeight: style.lineHeight,
                marginTop: style.marginTop,
                paddingLeft: style.paddingLeft,
                boxSizing: style.boxSizing,
              },
              getPropertyValues: {
                color: style.getPropertyValue('color'),
                backgroundColor: style.getPropertyValue('background-color'),
                fontSize: style.getPropertyValue('font-size'),
              },
              priorities: {
                color: style.getPropertyPriority('color'),
                backgroundColor: style.getPropertyPriority('background-color'),
              },
              readOnlyAttempt: {
                before: beforeMutation,
                after: afterMutation,
                errorName: mutationError,
                inlineStyleAfter: element.getAttribute('style'),
              },
              sameObjectOnSecondCall: style === getComputedStyle(element),
            };
          }

          let mutationResult = null;
          if (mutation) {
            const element = find(mutation.target);
            const retained = getComputedStyle(element);
            const before = read(element, properties);
            element.className = mutation.className;
            for (const [property, value] of Object.entries(mutation.inlineStyle)) {
              element.style[property] = value;
            }
            await new Promise(resolve =>
              requestAnimationFrame(() => requestAnimationFrame(resolve)),
            );
            const fresh = getComputedStyle(element);
            mutationResult = {
              before,
              retainedAfter: readStyle(element, retained, properties),
              freshAfter: readStyle(element, fresh, properties),
              sameObject: retained === fresh,
              classAfter: element.className,
              inlineStyleAfter: element.getAttribute('style'),
            };
          }

          return { expected, cssom, mutation: mutationResult };
        }, {
          targets: item.targets,
          properties: item.properties,
          cssomSurface: item.cssomSurface === true,
          mutation: item.mutation || null,
        });

        if (pageErrors.length) throw new Error(pageErrors.join('\n'));
        if (consoleErrors.length) throw new Error(consoleErrors.join('\n'));
        for (const id of item.targets) {
          const value = result.expected[id];
          if (!Number.isFinite(value.declarationLength)) {
            throw new Error(`${item.name} #${id} has non-finite declaration length`);
          }
          for (const property of item.properties) {
            if (typeof value.values[property] !== 'string') {
              throw new Error(`${item.name} #${id} missing ${property} string`);
            }
          }
          for (const key of ['x', 'y', 'width', 'height']) {
            if (!Number.isFinite(value.rect[key])) {
              throw new Error(`${item.name} #${id} has non-finite rect.${key}`);
            }
          }
        }
        if (result.cssom) {
          if (result.cssom.propertyOrder.length !== result.cssom.length) {
            throw new Error(`${item.name} CSSStyleDeclaration order/length mismatch`);
          }
          if (
            result.cssom.iterableLength !== result.cssom.length ||
            !result.cssom.iterableMatchesPropertyOrder
          ) {
            throw new Error(`${item.name} CSSStyleDeclaration iterator/order mismatch`);
          }
        }

        outputCases.push({
          name: item.name,
          purpose: item.purpose,
          authoredHTML,
          styles: { common: commonStyles, case: item.styles },
          targets: item.targets,
          supportedProperties: item.properties,
          viewportWidth: viewport.width,
          viewportHeight: viewport.height,
          expected: result.expected,
          ...(result.cssom ? { cssomSurface: result.cssom } : {}),
          ...(result.mutation ? { mutation: result.mutation } : {}),
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
      network: 'all page requests aborted; synthetic HTML only',
      scope:
        'Only the supportedProperties list on each case is asserted as an expected-value surface. CSSStyleDeclaration length and complete property order are recorded separately as Chromium observations, not a claim of complete native CSSOM parity.',
      geometry:
        'getComputedStyle selected properties, CSSStyleDeclaration metadata where requested, connectedness, and border-box getBoundingClientRect values',
    },
    cases: outputCases,
  };
  await writeFile(outputPath, `${JSON.stringify(output)}\n`);
  console.log(
    `Wrote ${outputCases.length} computed-style observations to ${outputPath.pathname}`,
  );
} finally {
  await browser.close();
}
