import { requireTestBrowserExecutable } from './test_browser.mjs';
import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';

const outputPath = new URL('../../../../packages/pirc_render/test/fixtures/parity/document-root-heights-chromium153.json', import.meta.url);
const gatewayRequire = createRequire(new URL('../../../gateway/package.json', import.meta.url));
const { chromium } = gatewayRequire('playwright-core');

const viewports = [
  { width: 390, height: 844 },
  { width: 844, height: 390 },
  { width: 768, height: 1024 },
];
const deviceScaleFactor = 1;

const html = (style, body) => `<!doctype html>
<html id="html"><head><meta charset="utf-8">
<style>html,body{margin:0;padding:0;scrollbar-width:none}*::-webkit-scrollbar{width:0;height:0}${style}</style></head><body id="body">${body}</body></html>`;

const cases = [
  {
    name: 'explicit_100_percent_chain',
    purpose: 'Definite 100% height from the root through body and app, plus a 50% child.',
    html: html(
      'html,body{height:100%} #app{height:100%} #child{height:50%}',
      '<div id="app"><div id="child"></div></div>',
    ),
    targets: ['html', 'body', 'app', 'child'],
  },
  {
    name: '50_percent_root_chain',
    purpose: 'Each percentage height is half of its definite containing block.',
    html: html(
      'html,body{height:50%} #app{height:50%} #child{height:50%}',
      '<div id="app"><div id="child"></div></div>',
    ),
    targets: ['html', 'body', 'app', 'child'],
  },
  {
    name: 'viewport_units_with_vmin_vmax_child',
    purpose: 'Viewport width and height units on app, with vmin and vmax dimensions on its child.',
    html: html(
      '#app{width:50vw;height:25vh} #child{width:50vmin;height:25vmax}',
      '<div id="app"><div id="child"></div></div>',
    ),
    targets: ['html', 'body', 'app', 'child'],
  },
  {
    name: 'html_auto_body_100_percent',
    purpose: 'An auto-height root leaves body and app percentage heights without a definite chain.',
    html: html(
      'html{height:auto} body{height:100%} #app{height:100%} #child{height:64px}',
      '<div id="app"><div id="child"></div></div>',
    ),
    targets: ['html', 'body', 'app', 'child'],
  },
  {
    name: 'body_auto_app_100_percent',
    purpose: 'An auto-height body interrupts the percentage chain from a full-height root.',
    html: html(
      'html{height:100%} body{height:auto} #app{height:100%} #child{height:64px}',
      '<div id="app"><div id="child"></div></div>',
    ),
    targets: ['html', 'body', 'app', 'child'],
  },
  {
    name: 'auto_intermediary_breaks_chain',
    purpose: 'A percentage-height child cannot resolve through an auto-height app intermediary.',
    html: html(
      'html,body{height:100%} #app{height:auto} #middle{height:100%} #child{height:64px}',
      '<div id="app"><div id="middle"><div id="child"></div></div></div>',
    ),
    targets: ['html', 'body', 'app', 'middle', 'child'],
  },
  {
    name: 'html_min_height_100_percent',
    purpose: 'A 100% minimum height on html does not establish a definite percentage height chain.',
    html: html(
      'html{min-height:100%} body{height:100%} #app{height:100%} #child{height:64px}',
      '<div id="app"><div id="child"></div></div>',
    ),
    targets: ['html', 'body', 'app', 'child'],
  },
  {
    name: 'html_min_height_viewport_body_auto',
    purpose: 'A viewport minimum on html with auto body height and a percentage-height app.',
    html: html(
      'html{min-height:100vh} body{height:auto} #app{height:100%} #child{height:64px}',
      '<div id="app"><div id="child"></div></div>',
    ),
    targets: ['html', 'body', 'app', 'child'],
  },
  {
    name: 'html_100_body_auto_min_height_100',
    purpose: 'A definite root with auto body height constrained by min-height:100%.',
    html: html(
      'html{height:100%} body{height:auto;min-height:100%} #app{height:100%} #child{height:32px}',
      '<div id="app"><div id="child"></div></div>',
    ),
    targets: ['html', 'body', 'app', 'child'],
  },
  {
    name: 'body_default_margin_8_with_explicit_heights',
    purpose: 'Explicit 100% heights with the browser-default 8px body margin restored.',
    html: html(
      'html,body{height:100%} body{margin:8px} #app{height:100%} #child{height:32px}',
      '<div id="app"><div id="child"></div></div>',
    ),
    targets: ['html', 'body', 'app', 'child'],
  },
  {
    name: 'content_box_padding_and_border',
    purpose: 'Percentage heights with content-box padding and borders on html, body, app, and child.',
    html: html(
      'html{height:100%;padding:12px 0 5px;border:3px solid} body{height:100%;padding:7px 9px;border:2px solid} #app{height:100%;padding:5px 6px;border:1px solid} #child{height:50%;padding:3px 4px;border:2px solid}',
      '<div id="app"><div id="child"></div></div>',
    ),
    targets: ['html', 'body', 'app', 'child'],
  },
  {
    name: 'overflow_tall_content',
    purpose: 'A 100% root chain with a fixed child taller than the viewport.',
    html: html(
      'html,body{height:100%} #app{height:100%} #child{height:1200px}',
      '<div id="app"><div id="child"></div></div>',
    ),
    targets: ['html', 'body', 'app', 'child'],
  },
  {
    name: 'nested_app_overflow_hidden_tall_child',
    purpose: 'A nested hidden scrollport clips a tall child without extending the page.',
    html: html(
      'html,body{height:100%} #app{height:100%;overflow:hidden} #child{height:1200px}',
      '<div id="app"><div id="child"></div></div>',
    ),
    targets: ['html', 'body', 'app', 'child'],
    scrollTargets: ['app'],
  },
  {
    name: 'nested_app_overflow_auto_tall_child',
    purpose: 'A nested auto scrollport owns a tall child without extending the page.',
    html: html(
      'html,body{height:100%} #app{height:100%;overflow:auto} #child{height:1200px}',
      '<div id="app"><div id="child"></div></div>',
    ),
    targets: ['html', 'body', 'app', 'child'],
    scrollTargets: ['app'],
  },
];

function assertFiniteRect(rect, label) {
  for (const key of ['x', 'y', 'width', 'height']) {
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
        await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));

        const measured = await page.evaluate(({ targets, scrollTargets }) => {
          const geometry = {};
          for (const target of targets) {
            const element = document.getElementById(target);
            if (!element) throw new Error(`Missing target #${target}`);
            const rect = element.getBoundingClientRect();
            geometry[target] = { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
          }
          const targetScrollHeights = {};
          for (const target of scrollTargets) {
            const element = document.getElementById(target);
            if (!element) throw new Error(`Missing scroll target #${target}`);
            targetScrollHeights[target] = element.scrollHeight;
          }
          return {
            expected: geometry,
            targetScrollHeights,
            documentMetrics: {
              innerWidth: window.innerWidth,
              innerHeight: window.innerHeight,
              htmlScrollWidth: document.documentElement.scrollWidth,
              htmlScrollHeight: document.documentElement.scrollHeight,
              bodyScrollWidth: document.body.scrollWidth,
              bodyScrollHeight: document.body.scrollHeight,
            },
          };
        }, { targets: item.targets, scrollTargets: item.scrollTargets ?? [] });

        if (pageErrors.length) throw new Error(pageErrors.join('\n'));
        if (consoleErrors.length) throw new Error(consoleErrors.join('\n'));
        for (const id of item.targets) assertFiniteRect(measured.expected[id], `${item.name} #${id}`);
        for (const [key, value] of Object.entries(measured.documentMetrics)) {
          if (!Number.isFinite(value)) throw new Error(`${item.name} document ${key} is non-finite`);
        }
        for (const [id, value] of Object.entries(measured.targetScrollHeights)) {
          if (!Number.isFinite(value)) throw new Error(`${item.name} #${id} scrollHeight is non-finite`);
        }

        outputCases.push({
          name: item.name,
          purpose: item.purpose,
          authoredHTML: item.html,
          targets: item.targets,
          viewportWidth: viewport.width,
          viewportHeight: viewport.height,
          expected: measured.expected,
          ...(item.scrollTargets?.length
            ? { targetScrollHeights: measured.targetScrollHeights }
            : {}),
          documentMetrics: measured.documentMetrics,
        });
      } finally {
        await context.close();
      }
    }
  }

  const fixture = {
    browserVersion,
    capture: {
      viewports,
      deviceScaleFactor,
      browserExecutable: 'dedicated chromium-headless-shell from test_browser.mjs',
      scrollbarChrome: 'hidden',
    },
    cases: outputCases,
  };
  await writeFile(outputPath, `${JSON.stringify(fixture)}\n`);
  console.log(`Captured ${cases.length} cases (${outputCases.length} viewport entries) with Chromium ${browserVersion}: ${outputPath.pathname}`);
} finally {
  await browser.close();
}
