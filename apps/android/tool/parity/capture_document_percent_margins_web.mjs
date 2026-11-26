import { requireTestBrowserExecutable } from './test_browser.mjs';
import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';

const outputPath = new URL(
  '../../../../packages/pirc_render/test/fixtures/parity/document-percent-margins-chromium153.json',
  import.meta.url,
);
const gatewayRequire = createRequire(
  new URL('../../../gateway/package.json', import.meta.url),
);
const { chromium } = gatewayRequire('playwright-core');

const viewports = [
  { width: 390, height: 844 },
  { width: 768, height: 1024 },
];
const deviceScaleFactor = 1;
const commonStyles =
  'html,body{scrollbar-width:none}*::-webkit-scrollbar{width:0;height:0}';

const html = (styles, body) => `<!doctype html>
<html id="html"><head><meta charset="utf-8">
<style>${commonStyles}${styles}</style></head><body id="body">${body}</body></html>`;

const cases = [
  {
    name: 'child_percent_basis_is_parent_content_width',
    purpose:
      'A 5% child top margin resolves against a 256px parent content box inside a 300px border-box with horizontal padding and borders.',
    styles:
      'body{margin:0}#outer{width:400px;border:1px solid}#parent{box-sizing:border-box;width:300px;padding-left:20px;padding-right:20px;border-left:2px solid;border-right:2px solid}#child{margin-top:5%;width:30px;height:10px}',
    body: '<div id="outer"><div id="parent"><div id="child"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'child'],
  },
  {
    name: 'parent_and_child_percent_margins_use_different_widths',
    purpose:
      'The parent 5% top margin uses the 400px outer content width; its 10% child margin uses the 158px parent content width.',
    styles:
      'body{margin:0}#outer{width:400px;border:1px solid}#parent{box-sizing:border-box;width:200px;padding-left:20px;padding-right:20px;border-left:1px solid;border-right:1px solid;margin-top:5%}#child{margin-top:10%;width:30px;height:10px}',
    body: '<div id="outer"><div id="parent"><div id="child"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'child'],
  },
  {
    name: 'nested_percent_and_pixel_margins_collapse_by_resolved_size',
    purpose:
      'Nested 400px, 240px, and 120px content widths resolve a 12px, 10%, and 28px top-margin chain before positive margins collapse.',
    styles:
      'body{margin:0}#outer{width:400px;border:1px solid}#parent{width:240px;margin-top:12px}#child{width:120px;margin-top:10%}#grandchild{width:30px;height:10px;margin-top:28px}',
    body:
      '<div id="outer"><div id="parent"><div id="child"><div id="grandchild"></div></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'child', 'grandchild'],
  },
  {
    name: 'auto_width_percent_margin_after_viewport_resize',
    purpose:
      'An auto-width parent tracks the viewport; its 5% child top margin is captured after resizing from the other reference viewport.',
    styles:
      'body{margin:0}#outer{width:auto;border:1px solid}#parent{width:auto}#child{margin-top:5%;width:30px;height:10px}',
    body: '<div id="outer"><div id="parent"><div id="child"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'child'],
    resizeFromOtherViewport: true,
  },
  {
    name: 'body_default_margin_with_percent_first_child',
    purpose:
      'The body keeps its browser-default 8px margin while its first child has a 5% top margin resolved against body content width.',
    styles: 'html{margin:0}#child{margin-top:5%;width:30px;height:10px}',
    body: '<div id="child"></div>',
    targets: ['html', 'body', 'child'],
  },
  {
    name: 'fixed_height_parent_allows_percent_first_child_collapse',
    purpose:
      'An explicit 80px parent height does not stop its first child 5% top margin from collapsing through it.',
    styles:
      'body{margin:0}#outer{width:400px;border:1px solid}#parent{width:300px;height:80px}#child{margin-top:5%;width:30px;height:10px}',
    body: '<div id="outer"><div id="parent"><div id="child"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'child'],
  },
  {
    name: 'parent_top_border_stops_percent_child_collapse',
    purpose:
      'A top border keeps the child 5% margin inside its 300px parent content box.',
    styles:
      'body{margin:0}#outer{width:400px;border:1px solid}#parent{width:300px;border-top:2px solid}#child{margin-top:5%;width:30px;height:10px}',
    body: '<div id="outer"><div id="parent"><div id="child"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'child'],
  },
  {
    name: 'parent_top_padding_stops_percent_child_collapse',
    purpose:
      'Top padding keeps the child 5% margin inside its 300px parent content box.',
    styles:
      'body{margin:0}#outer{width:400px;border:1px solid}#parent{width:300px;padding-top:6px}#child{margin-top:5%;width:30px;height:10px}',
    body: '<div id="outer"><div id="parent"><div id="child"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'child'],
  },
  {
    name: 'overflow_auto_stops_percent_child_collapse',
    purpose:
      'An overflow:auto formatting context retains the child 5% top margin inside its parent.',
    styles:
      'body{margin:0}#outer{width:400px;border:1px solid}#parent{width:300px;overflow:auto}#child{margin-top:5%;width:30px;height:10px}',
    body: '<div id="outer"><div id="parent"><div id="child"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'child'],
  },
  {
    name: 'flow_root_stops_percent_child_collapse',
    purpose:
      'A display:flow-root formatting context retains the child 5% top margin inside its parent.',
    styles:
      'body{margin:0}#outer{width:400px;border:1px solid}#parent{width:300px;display:flow-root}#child{margin-top:5%;width:30px;height:10px}',
    body: '<div id="outer"><div id="parent"><div id="child"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'child'],
  },
  {
    name: 'column_flex_parent_stops_percent_child_collapse',
    purpose:
      'A column flex item retains the child 5% top margin inside its flex parent.',
    styles:
      'body{margin:0}#outer{width:400px;border:1px solid}#parent{width:300px;display:flex;flex-direction:column}#child{margin-top:5%;width:30px;height:10px}',
    body: '<div id="outer"><div id="parent"><div id="child"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'child'],
  },
  {
    name: 'grid_parent_stops_percent_child_collapse',
    purpose:
      'A grid item retains the child 5% top margin inside its grid parent.',
    styles:
      'body{margin:0}#outer{width:400px;border:1px solid}#parent{width:300px;display:grid;grid-template-columns:300px}#child{margin-top:5%;width:30px;height:10px}',
    body: '<div id="outer"><div id="parent"><div id="child"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'child'],
  },
  {
    name: 'column_flex_auto_height_item_contains_percent_margin_chain',
    purpose:
      'A column flex item sizes itself around a normal block parent-child-grandchild chain whose 5% and 10% margins use different widths; the following flex sibling records the item height.',
    styles:
      'body{margin:0}#outer{width:400px;border:1px solid}#flex{display:flex;flex-direction:column;width:360px;border:1px solid}#parent{width:220px;margin-top:5%}#child{width:120px;margin-top:10%}#grandchild{width:40px;height:10px;margin-top:16px}#next{width:40px;height:8px}',
    body:
      '<div id="outer"><div id="flex"><div id="item"><div id="parent"><div id="child"><div id="grandchild"></div></div></div></div><div id="next"></div></div></div>',
    targets: [
      'html',
      'body',
      'outer',
      'flex',
      'item',
      'parent',
      'child',
      'grandchild',
      'next',
    ],
  },
  {
    name: 'row_flex_wrap_percent_item_content_baseline',
    purpose:
      'Two 160px items share the first 320px flex line; a third wraps and its 5% child margin contributes to the second line height.',
    styles:
      'body{margin:0}#outer{width:400px;border:1px solid}#flex{display:flex;flex-flow:row wrap;align-content:flex-start;width:320px}#first{width:160px;height:12px}#second{width:160px;height:20px}#third{width:160px}#wrapchild{margin-top:5%;width:30px;height:8px}',
    body:
      '<div id="outer"><div id="flex"><div id="first"></div><div id="second"></div><div id="third"><div id="wrapchild"></div></div></div></div>',
    targets: [
      'html',
      'body',
      'outer',
      'flex',
      'first',
      'second',
      'third',
      'wrapchild',
    ],
  },
  {
    name: 'pixel_and_percent_margin_winner_flips_with_viewport_width',
    purpose:
      'A 20px parent margin wins over 5% at 390px; the child percentage resolves larger and wins at 768px.',
    styles:
      'body{margin:0}#outer{width:auto;border:1px solid}#parent{width:auto;margin-top:20px}#child{margin-top:5%;width:30px;height:10px}',
    body: '<div id="outer"><div id="parent"><div id="child"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'child'],
  },
];

const controlReasons = {
  parent_top_border_stops_percent_child_collapse:
    'The parent top border separates its margin from the child margin.',
  parent_top_padding_stops_percent_child_collapse:
    'The parent top padding separates its margin from the child margin.',
  overflow_auto_stops_percent_child_collapse:
    'Overflow establishes a block formatting context.',
  flow_root_stops_percent_child_collapse:
    'display:flow-root establishes a block formatting context.',
  column_flex_parent_stops_percent_child_collapse:
    'Flex items do not collapse margins with the flex container.',
  grid_parent_stops_percent_child_collapse:
    'Grid items do not collapse margins with the grid container.',
  row_flex_wrap_percent_item_content_baseline:
    'This is a wrapping flex-item sizing control for percentage content margins.',
};

function assertFiniteMeasurement(value, label) {
  for (const key of ['offsetTop', 'offsetLeft']) {
    if (!Number.isFinite(value[key])) {
      throw new Error(`${label} has a non-finite ${key}: ${value[key]}`);
    }
  }
  for (const key of ['x', 'y', 'width', 'height']) {
    if (!Number.isFinite(value.rect[key])) {
      throw new Error(`${label} has a non-finite rect.${key}: ${value.rect[key]}`);
    }
  }
  if (!Number.isFinite(value.computedMarginTop)) {
    throw new Error(`${label} has a non-finite computed margin-top`);
  }
  if (!Number.isFinite(value.containingBlockContentWidth)) {
    throw new Error(`${label} has a non-finite containing-block content width`);
  }
}

const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
  args: [
    '--disable-background-networking',
    '--disable-component-update',
    '--no-first-run',
  ],
});

function otherViewport(viewport) {
  return viewports.find(candidate => candidate.width !== viewport.width);
}

async function waitForLayout(page) {
  await page.evaluate(
    () =>
      new Promise(resolve =>
        requestAnimationFrame(() => requestAnimationFrame(resolve)),
      ),
  );
}

async function measure(page, targets) {
  return page.evaluate(targetIds => {
    const pixel = value => Number.parseFloat(value) || 0;
    const contentWidth = element => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return (
        rect.width -
        pixel(style.borderLeftWidth) -
        pixel(style.borderRightWidth) -
        pixel(style.paddingLeft) -
        pixel(style.paddingRight)
      );
    };
    const expected = {};
    for (const id of targetIds) {
      const element = document.getElementById(id);
      if (!element) throw new Error(`Missing target #${id}`);
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      const parent = element.parentElement;
      expected[id] = {
        offsetTop: element.offsetTop,
        offsetLeft: element.offsetLeft,
        offsetParentId: element.offsetParent?.id || null,
        rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
        computedMarginTop: pixel(style.marginTop),
        computedMarginTopCss: style.marginTop,
        containingBlockContentWidth: parent ? contentWidth(parent) : window.innerWidth,
        display: style.display,
      };
    }
    return {
      expected,
      documentMetrics: {
        innerWidth: window.innerWidth,
        innerHeight: window.innerHeight,
        scrollX: window.scrollX,
        scrollY: window.scrollY,
        htmlScrollWidth: document.documentElement.scrollWidth,
        htmlScrollHeight: document.documentElement.scrollHeight,
        bodyScrollWidth: document.body.scrollWidth,
        bodyScrollHeight: document.body.scrollHeight,
      },
    };
  }, targets);
}

try {
  const browserVersion = await browser.version();
  if (!browserVersion.startsWith('153.')) {
    throw new Error(`Expected the dedicated Chromium 153 browser, got ${browserVersion}`);
  }

  const outputCases = [];
  for (const item of cases) {
    const authoredHTML = html(item.styles, item.body);
    for (const viewport of viewports) {
      const startingViewport = item.resizeFromOtherViewport
        ? otherViewport(viewport)
        : viewport;
      const context = await browser.newContext({
        viewport: startingViewport,
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

        let beforeResize;
        if (item.resizeFromOtherViewport) {
          beforeResize = await measure(page, item.targets);
          await page.setViewportSize(viewport);
          await waitForLayout(page);
        }
        const measured = await measure(page, item.targets);

        if (pageErrors.length) throw new Error(pageErrors.join('\n'));
        if (consoleErrors.length) throw new Error(consoleErrors.join('\n'));
        for (const id of item.targets) {
          assertFiniteMeasurement(measured.expected[id], `${item.name} #${id}`);
          if (beforeResize) {
            assertFiniteMeasurement(beforeResize.expected[id], `${item.name} before resize #${id}`);
          }
        }
        for (const [key, value] of Object.entries(measured.documentMetrics)) {
          if (!Number.isFinite(value)) {
            throw new Error(`${item.name} document ${key} is non-finite`);
          }
        }

        outputCases.push({
          name: item.name,
          purpose: item.purpose,
          support: controlReasons[item.name]
            ? { role: 'control', reason: controlReasons[item.name] }
            : { role: 'supported-reference' },
          styles: { common: commonStyles, case: item.styles },
          authoredHTML,
          targets: item.targets,
          viewportWidth: viewport.width,
          viewportHeight: viewport.height,
          ...(item.resizeFromOtherViewport
            ? {
                resizedFrom: startingViewport,
                beforeResizeExpected: beforeResize.expected,
              }
            : {}),
          expected: measured.expected,
          documentMetrics: measured.documentMetrics,
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
      geometry:
        'getBoundingClientRect border boxes, native offset properties, computed margin-top, and containing-block content widths',
    },
    cases: outputCases,
  };
  await writeFile(outputPath, `${JSON.stringify(output)}\n`);
  console.log(
    `Wrote ${outputCases.length} percent-margin observations to ${outputPath.pathname}`,
  );
} finally {
  await browser.close();
}
