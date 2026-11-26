import { requireTestBrowserExecutable } from './test_browser.mjs';
import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';

const outputPath = new URL('../../../../packages/pirc_render/test/fixtures/parity/document-margins-chromium153.json', import.meta.url);
const gatewayRequire = createRequire(new URL('../../../gateway/package.json', import.meta.url));
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
    name: 'positive_parent_and_first_child_margins_collapse',
    purpose: 'The larger positive first-child top margin collapses through its unbordered parent.',
    styles: 'body{margin:0}#outer{width:220px;border:1px solid}#parent{margin-top:20px}#child{margin-top:30px;width:30px;height:10px}',
    body: '<div id="outer"><div id="parent"><div id="child"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'child'],
  },
  {
    name: 'body_default_margin_8_inner_first_child_collapse',
    purpose: 'A supported first-child collapse inside a bordered wrapper with the browser-default body margin of 8px.',
    styles: '#outer{width:220px;border:1px solid}#parent{margin-top:20px}#child{margin-top:30px;width:30px;height:10px}',
    body: '<div id="outer"><div id="parent"><div id="child"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'child'],
  },
  {
    name: 'zero_parent_and_positive_first_child_margin_collapse',
    purpose: 'A positive first-child top margin collapses through a zero-margin unbordered parent.',
    styles: 'body{margin:0}#outer{width:220px;border:1px solid}#parent{margin-top:0}#child{margin-top:30px;width:30px;height:10px}',
    body: '<div id="outer"><div id="parent"><div id="child"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'child'],
  },
  {
    name: 'nested_unbordered_chain_collapses_max_positive_margin',
    purpose: 'Positive top margins on a nested chain collapse to the largest margin.',
    styles: 'body{margin:0}#outer{width:220px;border:1px solid}#parent{margin-top:12px}#child{margin-top:20px}#grandchild{margin-top:28px;width:30px;height:10px}',
    body: '<div id="outer"><div id="parent"><div id="child"><div id="grandchild"></div></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'child', 'grandchild'],
  },
  {
    name: 'second_sibling_margin_does_not_collapse_through_parent',
    purpose: 'A previous in-flow sibling prevents the next block margin from collapsing through the parent.',
    styles: 'body{margin:0}#outer{width:220px;border:1px solid}#parent{margin-top:20px}#previous{width:30px;height:10px}#child{margin-top:30px;width:30px;height:10px}',
    body: '<div id="outer"><div id="parent"><div id="previous"></div><div id="child"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'previous', 'child'],
  },
  {
    name: 'parent_top_border_stops_first_child_collapse',
    purpose: 'A nonzero parent top border keeps the first child margin inside the parent.',
    styles: 'body{margin:0}#outer{width:220px;border:1px solid}#parent{margin-top:20px;border-top:2px solid}#child{margin-top:30px;width:30px;height:10px}',
    body: '<div id="outer"><div id="parent"><div id="child"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'child'],
  },
  {
    name: 'parent_top_padding_stops_first_child_collapse',
    purpose: 'Nonzero parent top padding keeps the first child margin inside the parent.',
    styles: 'body{margin:0}#outer{width:220px;border:1px solid}#parent{margin-top:20px;padding-top:6px}#child{margin-top:30px;width:30px;height:10px}',
    body: '<div id="outer"><div id="parent"><div id="child"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'child'],
  },
  {
    name: 'overflow_auto_stops_first_child_collapse',
    purpose: 'An overflow:auto parent establishes a block formatting context and retains the child margin.',
    styles: 'body{margin:0}#outer{width:220px;border:1px solid}#parent{margin-top:20px;overflow:auto}#child{margin-top:30px;width:30px;height:10px}',
    body: '<div id="outer"><div id="parent"><div id="child"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'child'],
  },
  {
    name: 'overflow_hidden_stops_first_child_collapse',
    purpose: 'An overflow:hidden parent establishes a block formatting context and retains the child margin.',
    styles: 'body{margin:0}#outer{width:220px;border:1px solid}#parent{margin-top:20px;overflow:hidden}#child{margin-top:30px;width:30px;height:10px}',
    body: '<div id="outer"><div id="parent"><div id="child"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'child'],
  },
  {
    name: 'flow_root_stops_first_child_collapse',
    purpose: 'A display:flow-root parent retains the first child margin inside its formatting context.',
    styles: 'body{margin:0}#outer{width:220px;border:1px solid}#parent{margin-top:20px;display:flow-root}#child{margin-top:30px;width:30px;height:10px}',
    body: '<div id="outer"><div id="parent"><div id="child"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'child'],
  },
  {
    name: 'column_flex_item_margin_does_not_collapse',
    purpose: 'A first column flex item retains its positive top margin inside the flex parent.',
    styles: 'body{margin:0}#outer{width:220px;border:1px solid}#parent{display:flex;flex-direction:column;margin-top:20px}#child{margin-top:30px;width:30px;height:10px}',
    body: '<div id="outer"><div id="parent"><div id="child"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'child'],
  },
  {
    name: 'grid_item_margin_does_not_collapse',
    purpose: 'A first grid item retains its positive top margin inside the grid parent.',
    styles: 'body{margin:0}#outer{width:220px;border:1px solid}#parent{display:grid;grid-template-columns:100px;margin-top:20px}#child{margin-top:30px;width:30px;height:10px}',
    body: '<div id="outer"><div id="parent"><div id="child"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'child'],
  },
  {
    name: 'fixed_height_parent_still_collapses_first_child_margin',
    purpose: 'A fixed parent height does not by itself stop positive first-child top margin collapse.',
    styles: 'body{margin:0}#outer{width:220px;border:1px solid}#parent{height:80px;margin-top:20px}#child{margin-top:30px;width:30px;height:10px}',
    body: '<div id="outer"><div id="parent"><div id="child"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'child'],
  },
  {
    name: 'visibility_hidden_first_child_still_collapses',
    purpose: 'A visibility:hidden first child keeps its box and its positive margin still collapses.',
    styles: 'body{margin:0}#outer{width:220px;border:1px solid}#parent{margin-top:20px}#child{visibility:hidden;margin-top:30px;width:30px;height:10px}',
    body: '<div id="outer"><div id="parent"><div id="child"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'child'],
  },
  {
    name: 'display_none_first_child_has_no_collapsing_box',
    purpose: 'A display:none first child contributes no box or margin to the parent.',
    styles: 'body{margin:0}#outer{width:220px;border:1px solid}#parent{margin-top:20px}#child{display:none;margin-top:30px;width:30px;height:10px}',
    body: '<div id="outer"><div id="parent"><div id="child"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'child'],
  },
  {
    name: 'html_body_root_margin_propagation_with_1000px_first_child',
    purpose: 'A first body child with a 1000px top margin, default 8px body margin, and zero html margin.',
    styles: 'html{margin:0}body{margin:8px}#child{margin-top:1000px;width:30px;height:10px}',
    body: '<div id="child"></div>',
    targets: ['html', 'body', 'child'],
  },
];

const unsupportedReferences = [
  {
    name: 'mixed_positive_and_negative_collapsing_margins',
    reason: 'The CSS margin-collapse rule combines the largest positive and most negative margin; this reference set focuses on positive margins.',
  },
  {
    name: 'percentage_vertical_margins',
    reason: 'Percentage margins resolve from containing-block width and need a separate width-sensitive reference.',
  },
];

const controlReasons = {
  second_sibling_margin_does_not_collapse_through_parent: 'A preceding in-flow sibling is outside the parent/first-child helper scope.',
  overflow_auto_stops_first_child_collapse: 'Overflow establishes a block formatting context, which is outside the initial helper scope.',
  overflow_hidden_stops_first_child_collapse: 'Overflow establishes a block formatting context, which is outside the initial helper scope.',
  flow_root_stops_first_child_collapse: 'display:flow-root establishes a block formatting context, which is outside the initial helper scope.',
  column_flex_item_margin_does_not_collapse: 'Flex items are outside the initial helper scope.',
  grid_item_margin_does_not_collapse: 'Grid items are outside the initial helper scope.',
  display_none_first_child_has_no_collapsing_box: 'display:none box omission is captured as a boundary control.',
};

function assertFiniteMeasurement(value, label) {
  for (const key of ['offsetTop', 'offsetLeft']) {
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
        await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));

        const measured = await page.evaluate(targets => {
          const expected = {};
          for (const id of targets) {
            const element = document.getElementById(id);
            if (!element) throw new Error(`Missing target #${id}`);
            const rect = element.getBoundingClientRect();
            expected[id] = {
              offsetTop: element.offsetTop,
              offsetLeft: element.offsetLeft,
              offsetParentId: element.offsetParent?.id || null,
              rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
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
        }, item.targets);

        if (pageErrors.length) throw new Error(pageErrors.join('\n'));
        if (consoleErrors.length) throw new Error(consoleErrors.join('\n'));
        for (const id of item.targets) assertFiniteMeasurement(measured.expected[id], `${item.name} #${id}`);
        for (const [key, value] of Object.entries(measured.documentMetrics)) {
          if (!Number.isFinite(value)) throw new Error(`${item.name} document ${key} is non-finite`);
        }

        outputCases.push({
          name: item.name,
          purpose: item.purpose,
          support: controlReasons[item.name]
            ? { role: 'control', reason: controlReasons[item.name] }
            : { role: 'supported-baseline' },
          styles: { common: commonStyles, case: item.styles },
          authoredHTML,
          targets: item.targets,
          viewportWidth: viewport.width,
          viewportHeight: viewport.height,
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
      geometry: 'getBoundingClientRect border boxes and native offset properties',
    },
    unsupportedReferences,
    cases: outputCases,
  };
  await writeFile(outputPath, `${JSON.stringify(output)}\n`);
  console.log(`Wrote ${outputCases.length} margin observations to ${outputPath.pathname}`);
} finally {
  await browser.close();
}
