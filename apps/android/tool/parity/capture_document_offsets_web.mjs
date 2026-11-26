import { requireTestBrowserExecutable } from './test_browser.mjs';
import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';

const outputPath = new URL('../../../../packages/pirc_render/test/fixtures/parity/document-offsets-chromium153.json', import.meta.url);
const gatewayRequire = createRequire(new URL('../../../gateway/package.json', import.meta.url));
const { chromium } = gatewayRequire('playwright-core');

const viewports = [
  { width: 390, height: 844 },
  { width: 768, height: 1024 },
];
const deviceScaleFactor = 1;

const html = (style, body) => `<!doctype html>
<html id="html"><head><meta charset="utf-8">
<style>html,body{scrollbar-width:none}*::-webkit-scrollbar{width:0;height:0}${style}</style></head><body id="body">${body}</body></html>`;

const cases = [
  {
    name: 'default_body_margin_with_child_and_sibling',
    purpose: 'Browser-default body margin with two plain normal-flow children.',
    html: html('.box{width:12px;height:10px}', '<div id="first" class="box"></div><div id="sibling" class="box"></div>'),
    targets: ['html', 'body', 'first', 'sibling'],
  },
  {
    name: 'body_padding_border_static',
    purpose: 'A static body with nonzero padding and border, retaining its default margin.',
    html: html(
      'body{margin:8px;padding:11px 13px;border:3px solid}#parent{padding:7px 9px;border:2px solid}#a{width:10px;height:10px}',
      '<div id="parent"><div id="a"></div></div>',
    ),
    targets: ['html', 'body', 'parent', 'a'],
  },
  {
    name: 'body_padding_border_relative_no_insets',
    purpose: 'A relative body with nonzero padding and border and no top or left inset.',
    html: html(
      'body{margin:8px;padding:11px 13px;border:3px solid;position:relative}#parent{padding:7px 9px;border:2px solid}#a{width:10px;height:10px}',
      '<div id="parent"><div id="a"></div></div>',
    ),
    targets: ['html', 'body', 'parent', 'a'],
  },
  {
    name: 'nested_normal_flow_fractional_and_signed_margins',
    purpose: 'Nested static boxes with positive, fractional, and negative margins.',
    html: html(
      'body{margin:8px}#outer{padding:4px 6px;border:1px solid}#inner{padding:3px 5px;border:2px solid}.box{width:20px;height:10px}#positive{margin:2px 11px}#fractional{margin:2.5px 2.5px}#negative{margin:1.5px -7.5px}',
      '<div id="outer"><div id="inner"><div id="positive" class="box"></div><div id="fractional" class="box"></div><div id="negative" class="box"></div></div></div>',
    ),
    targets: ['html', 'body', 'outer', 'inner', 'positive', 'fractional', 'negative'],
  },
  {
    name: 'relative_parent_negative_half_margins',
    purpose: 'Negative fractional horizontal margins under a zero-inset relative parent, with no vertical margins.',
    html: html(
      'body{margin:0}#parent{position:relative;padding:0;border:0}#negativeSevenHalf{width:20px;height:10px;margin:0 0 0 -7.5px}#negativeHalf{width:20px;height:10px;margin:0 0 0 -0.5px}',
      '<div id="parent"><div id="negativeSevenHalf"></div><div id="negativeHalf"></div></div>',
    ),
    targets: ['html', 'body', 'parent', 'negativeSevenHalf', 'negativeHalf'],
  },
  {
    name: 'static_flex_layout_items',
    purpose: 'Flex items inside a static flex container with nonzero border, padding, and gap.',
    html: html(
      'body{margin:8px}#flex{display:flex;align-items:center;gap:13.5px;width:240px;height:90px;padding:7px 11px;border:2px solid}.item{width:20px;height:10px}#flexA{margin-left:2.5px}#flexB{margin-left:-1.5px}',
      '<div id="flex"><div id="flexA" class="item"></div><div id="flexB" class="item"></div></div>',
    ),
    targets: ['html', 'body', 'flex', 'flexA', 'flexB'],
  },
  {
    name: 'row_flex_shrink_unequal_bases_signed_left_margins',
    purpose: 'A shrinking row flex line with unequal bases, a positive left margin on the first item, and a negative left margin on the second.',
    html: html(
      'body{margin:0}#flex{display:flex;width:180px;height:60px;padding:4px 6px;border:1px solid}#itemA{flex:0 1 120px;min-width:0;height:20px;margin-left:14px}#itemB{flex:0 1 90px;min-width:0;height:20px;margin-left:-9px}',
      '<div id="flex"><div id="itemA"></div><div id="itemB"></div></div>',
    ),
    targets: ['html', 'body', 'flex', 'itemA', 'itemB'],
  },
  {
    name: 'column_flex_grow_and_shrink_positive_block_margins',
    purpose: 'Column flex growth and shrinkage with positive top and bottom margins on every flex item.',
    html: html(
      'body{margin:0}.column{display:flex;flex-direction:column;width:120px;padding:6px 4px;border:1px solid}#growColumn{height:130px}#growA{flex:1 1 30px;margin:7px 0 9px}#growB{flex:2 1 30px;margin:11px 0 5px}#shrinkColumn{height:90px}#shrinkA{flex:0 1 70px;margin:4px 0 6px}#shrinkB{flex:0 1 50px;margin:3px 0 5px}',
      '<div id="growColumn" class="column"><div id="growA"></div><div id="growB"></div></div><div id="shrinkColumn" class="column"><div id="shrinkA"></div><div id="shrinkB"></div></div>',
    ),
    targets: ['html', 'body', 'growColumn', 'growA', 'growB', 'shrinkColumn', 'shrinkA', 'shrinkB'],
  },
  {
    name: 'row_flex_align_center_positive_cross_axis_margins',
    purpose: 'Center-aligned row flex items with positive top and bottom cross-axis margins.',
    html: html(
      'body{margin:0}#flex{display:flex;align-items:center;gap:8px;width:160px;height:100px;padding:5px 7px;border:1px solid}#itemA{width:40px;height:20px;margin:8px 0 12px}#itemB{width:30px;height:30px;margin:4px 0 18px}',
      '<div id="flex"><div id="itemA"></div><div id="itemB"></div></div>',
    ),
    targets: ['html', 'body', 'flex', 'itemA', 'itemB'],
  },
  {
    name: 'static_grid_layout_items',
    purpose: 'Grid items inside a static grid container with nonzero border, padding, and gaps.',
    html: html(
      'body{margin:8px}#grid{display:grid;grid-template-columns:65px 90px;grid-template-rows:40px 50px;gap:5.5px;width:240px;padding:7px 11px;border:2px solid}.item{width:20px;height:10px}#gridB{margin-left:2.5px}',
      '<div id="grid"><div id="gridA" class="item"></div><div id="gridB" class="item"></div></div>',
    ),
    targets: ['html', 'body', 'grid', 'gridA', 'gridB'],
  },
  {
    name: 'nested_relative_parent_border_padding_no_insets',
    purpose: 'A nested relative parent establishes the offset parent and has border and padding but no insets.',
    html: html(
      'body{margin:8px}#relative{position:relative;width:210px;height:120px;padding:11px 13px;border:5px solid}#child{margin:7px 9px;width:30px;height:20px}#grandchild{margin:3px 4px;width:12px;height:8px}',
      '<div id="relative"><div id="child"><div id="grandchild"></div></div></div>',
    ),
    targets: ['html', 'body', 'relative', 'child', 'grandchild'],
  },
  {
    name: 'nested_scroll_container_static',
    purpose: 'A static overflow container and its child before and after scrolling the container.',
    html: html(
      'body{margin:0}#scroller{width:150px;height:100px;overflow:auto;padding:5px;border:4px solid}#content{width:300px;height:300px}#target{margin:63px 0 0 81px;width:30px;height:20px}',
      '<div id="scroller"><div id="content"><div id="target"></div></div></div>',
    ),
    targets: ['html', 'body', 'scroller', 'content', 'target'],
    scrollSequence: [{ name: 'scroll_40_60', elements: { scroller: { top: 40, left: 60 } } }],
  },
  {
    name: 'nested_scroll_container_relative',
    purpose: 'A relative overflow container and its child before and after scrolling the container.',
    html: html(
      'body{margin:0}#scroller{position:relative;width:150px;height:100px;overflow:auto;padding:5px;border:4px solid}#content{width:300px;height:300px}#target{margin:63px 0 0 81px;width:30px;height:20px}',
      '<div id="scroller"><div id="content"><div id="target"></div></div></div>',
    ),
    targets: ['html', 'body', 'scroller', 'content', 'target'],
    scrollSequence: [{ name: 'scroll_40_60', elements: { scroller: { top: 40, left: 60 } } }],
  },
  {
    name: 'window_scroll_static_body_child_at_1000px',
    purpose: 'A tall document with a child at 1000px, before and after scrolling the window by 100px.',
    html: html(
      'body{margin:0}#child{margin-top:1000px;width:20px;height:200px}',
      '<div id="child"></div>',
    ),
    targets: ['html', 'body', 'child'],
    scrollSequence: [{ name: 'window_scroll_100', window: { top: 100, left: 0 } }],
  },
  {
    name: 'visibility_hidden_layout_box',
    purpose: 'A visibility-hidden element retains its normal-flow layout box and offsets.',
    html: html(
      'body{margin:8px}#hidden{visibility:hidden;margin:3.5px 6.5px;width:31px;height:17px}',
      '<div id="hidden"></div>',
    ),
    targets: ['html', 'body', 'hidden'],
  },
  {
    name: 'detached_element',
    purpose: 'A formerly connected element is detached before its offsets and rectangle are read.',
    html: html('body{margin:8px}#detached{margin:3px 5px;width:31px;height:17px}', '<div id="detached"></div>'),
    targets: ['html', 'body', 'detached'],
    detachBeforeMeasure: ['detached'],
  },
  {
    name: 'html_margin_padding_body_zero',
    purpose: 'Nonzero html margin, padding, and border with a zero-margin, zero-padding body.',
    html: html(
      'html{margin:17px 19px;padding:5px 7px;border:2px solid}body{margin:0;padding:0;border:0}#child{width:10px;height:10px}',
      '<div id="child"></div>',
    ),
    targets: ['html', 'body', 'child'],
  },
  {
    name: 'display_none_ancestor',
    purpose: 'A connected target under a display:none ancestor.',
    html: html(
      'body{margin:8px}#ancestor{display:none;padding:11px;border:3px solid}#child{margin:5px;width:30px;height:20px}',
      '<div id="ancestor"><div id="child"></div></div>',
    ),
    targets: ['html', 'body', 'ancestor', 'child'],
  },
];

const unsupportedReferences = [
  { name: 'relative_nonzero_insets', reason: 'Positioned top/left insets change visual position; excluded from the supported baseline.' },
  { name: 'absolute_positioned', reason: 'Absolute positioning is outside the supported normal-flow offset baseline.' },
  { name: 'fixed_positioned', reason: 'Fixed positioning is outside the supported normal-flow offset baseline.' },
  { name: 'transformed_elements', reason: 'CSS transforms change visual rectangles without the baseline offset coordinate model.' },
  { name: 'zoomed_elements', reason: 'CSS zoom is outside the supported baseline.' },
  { name: 'table_layout', reason: 'Table-specific offset-parent behavior is outside the supported baseline.' },
  { name: 'inline_multifragment', reason: 'Multi-fragment inline boxes are outside the supported baseline.' },
];

function assertFiniteTarget(value, label) {
  for (const key of ['offsetTop', 'offsetLeft', 'scrollTop', 'scrollLeft', 'clientTop', 'clientLeft']) {
    if (!Number.isFinite(value[key])) throw new Error(`${label} has a non-finite ${key}: ${value[key]}`);
  }
  for (const key of ['x', 'y', 'width', 'height']) {
    if (!Number.isFinite(value.rect[key])) throw new Error(`${label} has a non-finite rect.${key}: ${value.rect[key]}`);
  }
}

const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
  args: ['--disable-background-networking', '--disable-component-update', '--no-first-run'],
});

try {
  const browserVersion = await browser.version();
  if (!browserVersion.startsWith('153.')) {
    throw new Error(`Expected the dedicated Chromium 153 browser, got ${browserVersion}`);
  }

  const outputCases = [];
  for (const item of cases) {
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
        await page.setContent(item.html, { waitUntil: 'load' });
        await page.evaluate(ids => {
          window.__detachedTargets = {};
          for (const id of ids) {
            const element = document.getElementById(id);
            if (!element) throw new Error(`Missing detached target #${id}`);
            window.__detachedTargets[id] = element;
            element.remove();
          }
        }, item.detachBeforeMeasure ?? []);
        await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));

        const measure = async () => page.evaluate(targets => {
          const elements = {};
          for (const id of targets) {
            const element = window.__detachedTargets?.[id] ?? document.getElementById(id);
            if (!element) throw new Error(`Missing target #${id}`);
            const rect = element.getBoundingClientRect();
            elements[id] = {
              offsetTop: element.offsetTop,
              offsetLeft: element.offsetLeft,
              offsetParentId: element.offsetParent?.id || null,
              rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
              scrollTop: element.scrollTop,
              scrollLeft: element.scrollLeft,
              clientTop: element.clientTop,
              clientLeft: element.clientLeft,
            };
          }
          return {
            windowScroll: { x: window.scrollX, y: window.scrollY },
            expected: elements,
          };
        }, item.targets);

        const expected = await measure();
        if (pageErrors.length) throw new Error(pageErrors.join('\n'));
        if (consoleErrors.length) throw new Error(consoleErrors.join('\n'));
        for (const [id, value] of Object.entries(expected.expected)) assertFiniteTarget(value, `${item.name} #${id}`);

        if (item.scrollSequence?.length) {
          const states = [{ name: 'initial', ...expected }];
          for (const step of item.scrollSequence) {
            await page.evaluate(({ window: windowPosition, elements: elementPositions }) => {
              if (windowPosition) window.scrollTo(windowPosition.left ?? 0, windowPosition.top ?? 0);
              for (const [id, position] of Object.entries(elementPositions ?? {})) {
                const element = document.getElementById(id);
                if (!element) throw new Error(`Missing scroll target #${id}`);
                element.scrollTop = position.top ?? 0;
                element.scrollLeft = position.left ?? 0;
              }
            }, step);
            await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
            const scrolled = await measure();
            for (const [id, value] of Object.entries(scrolled.expected)) assertFiniteTarget(value, `${item.name} #${id} after ${step.name}`);
            states.push({ name: step.name, ...scrolled });
          }
          outputCases.push({
            name: item.name,
            purpose: item.purpose,
            nativeSupport: 'supported',
            authoredHTML: item.html,
            targets: item.targets,
            viewportWidth: viewport.width,
            viewportHeight: viewport.height,
            states,
          });
        } else {
          outputCases.push({
            name: item.name,
            purpose: item.purpose,
            nativeSupport: 'supported',
            authoredHTML: item.html,
            targets: item.targets,
            viewportWidth: viewport.width,
            viewportHeight: viewport.height,
            ...expected,
          });
        }

        if (pageErrors.length) throw new Error(pageErrors.join('\n'));
        if (consoleErrors.length) throw new Error(consoleErrors.join('\n'));
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
    },
    unsupportedReferences,
    cases: outputCases,
  };
  await writeFile(outputPath, `${JSON.stringify(output)}\n`);
  console.log(`Wrote ${outputCases.length} offset observations to ${outputPath.pathname}`);
} finally {
  await browser.close();
}
