import { requireTestBrowserExecutable } from './test_browser.mjs';
import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';

const outputPath = new URL('../../../../packages/pirc_render/test/fixtures/parity/document-percentages-chromium153.json', import.meta.url);
const gatewayRequire = createRequire(new URL('../../../gateway/package.json', import.meta.url));
const { chromium } = gatewayRequire('playwright-core');

const viewportWidths = [390, 768];
const viewportHeight = 1000;
const themes = ['light', 'dark'];
const deviceScaleFactor = 1;

const html = (style, body) => `<!doctype html>
<html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
<style>html,body{margin:0;padding:0}${style}</style></head><body>${body}</body></html>`;

const cases = [
  {
    name: 'nested_content_box_percentage_width_height',
    purpose: 'Nested width and height percentages with content-box padding, borders, and margins.',
    html: html(
      '#outer{width:240px;height:180px;margin:7px 9px;padding:12px 16px;border:3px solid} #inner{width:50%;height:50%;margin:4px;padding:5px;border:2px solid} #deep{width:50%;height:50%;margin:3px;padding:2px;border:1px solid',
      '<div id="outer"><div id="inner"><div id="deep"></div></div></div>',
    ),
    targets: ['outer', 'inner', 'deep'],
  },
  {
    name: 'percentage_edges_content_box',
    purpose: 'Percentage width and height with percentage margin and padding under a definite containing block.',
    html: html(
      '#parent{width:300px;height:200px} #child{width:50%;height:50%;margin:5%;padding:10%;border:2px solid}',
      '<div id="parent"><div id="child"></div></div>',
    ),
    targets: ['parent', 'child'],
  },
  {
    name: 'percentage_edges_border_box',
    purpose: 'The same percentage edges with border-box width and height.',
    html: html(
      '#parent{width:300px;height:200px} #child{box-sizing:border-box;width:50%;height:50%;margin:5%;padding:10%;border:2px solid}',
      '<div id="parent"><div id="child"></div></div>',
    ),
    targets: ['parent', 'child'],
  },
  {
    name: 'percentage_height_auto_parent',
    purpose: 'A percentage-height child inside an auto-height parent, with no in-flow content.',
    html: html(
      '#parent{width:220px;padding:8px;border:3px solid} #child{width:100%;height:50%;padding:4px;border:2px solid}',
      '<div id="parent"><div id="child"></div></div>',
    ),
    targets: ['parent', 'child'],
  },
  {
    name: 'percentage_height_definite_parent',
    purpose: 'A percentage-height child inside a definite-height parent content box.',
    html: html(
      '#parent{width:220px;height:200px;padding:8px;border:3px solid} #child{width:100%;height:50%;padding:4px;border:2px solid}',
      '<div id="parent"><div id="child"></div></div>',
    ),
    targets: ['parent', 'child'],
  },
  {
    name: 'percentage_height_auto_ancestor_chain',
    purpose: 'A definite grandparent does not make a percentage height definite through an auto-height parent.',
    html: html(
      '#grand{width:300px;height:240px;padding:10px;border:2px solid} #parent{padding:5px;border:1px solid} #child{width:50%;height:50%;padding:3px;border:2px solid} #payload{width:20px;height:36px}',
      '<div id="grand"><div id="parent"><div id="child"><div id="payload"></div></div></div></div>',
    ),
    targets: ['grand', 'parent', 'child', 'payload'],
  },
  {
    name: 'percentage_min_max_constraints',
    purpose: 'Percentage min and max width and height constraints under a definite containing block.',
    html: html(
      '#parent{width:300px;height:200px} #min-width{width:10px;min-width:50%;max-width:80%;height:20px} #max-width{width:95%;min-width:20px;max-width:60%;height:20px} #min-height{width:24px;height:10px;min-height:25%;max-height:75%} #max-height{width:24px;height:90%;min-height:20%;max-height:50%}',
      '<div id="parent"><div id="min-width"></div><div id="max-width"></div><div id="min-height"></div><div id="max-height"></div></div>',
    ),
    targets: ['parent', 'min-width', 'max-width', 'min-height', 'max-height'],
  },
  {
    name: 'percentage_widths_in_flex_row',
    purpose: 'Percentage child widths in a definite-width flex row with content-box edges.',
    html: html(
      '#row{display:flex;width:300px;height:100px;gap:10px;padding:8px;border:2px solid} #a{flex:none;width:25%;height:30px} #b{flex:none;width:50%;height:40px} #c{flex:none;width:10%;height:20px}',
      '<div id="row"><div id="a"></div><div id="b"></div><div id="c"></div></div>',
    ),
    targets: ['row', 'a', 'b', 'c'],
  },
  {
    name: 'percentage_heights_in_flex_column',
    purpose: 'Percentage child heights in a definite-height flex column.',
    html: html(
      '#column{display:flex;flex-direction:column;width:220px;height:240px;gap:10px;padding:8px;border:2px solid} #a{flex:none;width:40px;height:25%} #b{flex:none;width:50px;height:50%} #c{flex:none;width:60px;height:10%}',
      '<div id="column"><div id="a"></div><div id="b"></div><div id="c"></div></div>',
    ),
    targets: ['column', 'a', 'b', 'c'],
  },
  {
    name: 'percentage_tracks_and_items_in_grid',
    purpose: 'Percentage grid tracks and empty grid items under definite inline and block sizes.',
    html: html(
      '#grid{display:grid;width:320px;height:220px;grid-template-columns:25% 50% 25%;grid-template-rows:30% 70%;gap:0} #a{width:50%;height:50%} #b{width:100%;height:100%} #c{width:75%;height:25%}',
      '<div id="grid"><div id="a"></div><div id="b"></div><div id="c"></div></div>',
    ),
    targets: ['grid', 'a', 'b', 'c'],
  },
  {
    name: 'percentage_width_overflow',
    purpose: 'A 125% child width and resulting document horizontal scroll extent.',
    html: html(
      '#parent{width:100vw;height:50px} #overwide{width:125%;height:24px}',
      '<div id="parent"><div id="overwide"></div></div>',
    ),
    targets: ['parent', 'overwide'],
  },
  {
    name: 'block_width_auto_with_edges',
    purpose: 'A block width:auto filling its containing block after fixed margins, padding, and borders.',
    html: html(
      '#parent{width:240px} #auto{width:auto;height:40px;margin-left:15px;margin-right:9px;padding:12px;border:3px solid}',
      '<div id="parent"><div id="auto"></div></div>',
    ),
    targets: ['parent', 'auto'],
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
  args: ['--disable-background-networking', '--disable-component-update', '--no-first-run'],
});

try {
  const browserVersion = await browser.version();
  if (!browserVersion.startsWith('153.')) {
    throw new Error(`Expected the dedicated Chromium 153 browser, got ${browserVersion}`);
  }

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
          await page.evaluate(async () => {
            await document.fonts.ready;
            await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
          });

          const measured = await page.evaluate(targets => {
            const expected = {};
            for (const id of targets) {
              const element = document.getElementById(id);
              if (!element) throw new Error(`Missing target #${id}`);
              const rect = element.getBoundingClientRect();
              expected[id] = {
                rect: rect.toJSON(),
                clientRects: Array.from(element.getClientRects(), item => item.toJSON()),
                clientWidth: element.clientWidth,
                clientHeight: element.clientHeight,
                clientLeft: element.clientLeft,
                clientTop: element.clientTop,
                offsetWidth: element.offsetWidth,
                offsetHeight: element.offsetHeight,
                scrollWidth: element.scrollWidth,
                scrollHeight: element.scrollHeight,
                scrollLeft: element.scrollLeft,
                scrollTop: element.scrollTop,
              };
            }
            const root = document.documentElement;
            const body = document.body;
            return {
              targets: expected,
              document: {
                viewportWidth: window.innerWidth,
                viewportHeight: window.innerHeight,
                scrollX: window.scrollX,
                scrollY: window.scrollY,
                clientWidth: root.clientWidth,
                clientHeight: root.clientHeight,
                scrollWidth: root.scrollWidth,
                scrollHeight: root.scrollHeight,
                bodyScrollWidth: body.scrollWidth,
                bodyScrollHeight: body.scrollHeight,
              },
            };
          }, item.targets);

          if (pageErrors.length) throw new Error(pageErrors.join('\n'));
          if (consoleErrors.length) throw new Error(consoleErrors.join('\n'));
          for (const id of item.targets) {
            const target = measured.targets[id];
            assertFiniteRect(target.rect, `${item.name} #${id}`);
            for (const rect of target.clientRects) assertFiniteRect(rect, `${item.name} #${id} client rect`);
            for (const key of ['clientWidth', 'clientHeight', 'clientLeft', 'clientTop', 'offsetWidth', 'offsetHeight', 'scrollWidth', 'scrollHeight', 'scrollLeft', 'scrollTop']) {
              if (!Number.isFinite(target[key])) throw new Error(`${item.name} #${id} has a non-finite ${key}`);
            }
          }
          for (const [key, value] of Object.entries(measured.document)) {
            if (!Number.isFinite(value)) throw new Error(`${item.name} document ${key} is non-finite`);
          }

          outputCases.push({
            name: item.name,
            purpose: item.purpose,
            authoredHTML: item.html,
            targets: item.targets,
            viewportWidth,
            viewportHeight,
            theme,
            deviceScaleFactor,
            expected: measured.targets,
            documentMetrics: measured.document,
          });
        } finally {
          await context.close();
        }
      }
    }
  }

  const fixture = {
    browserVersion,
    capture: {
      viewportWidths,
      viewportHeight,
      themes,
      deviceScaleFactor,
      textScale: 'default',
      browserExecutable: 'dedicated chromium-headless-shell from test_browser.mjs',
    },
    cases: outputCases,
  };
  await writeFile(outputPath, `${JSON.stringify(fixture, null, 2)}\n`);
  console.log(`Captured ${cases.length} cases (${outputCases.length} viewport/theme entries) with Chromium ${browserVersion}: ${outputPath.pathname}`);
} finally {
  await browser.close();
}
