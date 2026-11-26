import { requireTestBrowserExecutable } from './test_browser.mjs';
import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';

const outputPath = new URL('../../../../packages/pirc_render/test/fixtures/parity/document-element-scroll-chromium153.json', import.meta.url);
const gatewayRequire = createRequire(new URL('../../../gateway/package.json', import.meta.url));
const { chromium } = gatewayRequire('playwright-core');

const viewportWidths = [390, 768];
const viewportHeight = 1000;
const themes = ['light', 'dark'];
const deviceScaleFactor = 1;
const unsupported = [
  'RTL scrollLeft conventions and vertical writing modes are not covered.',
  'User-driven wheel, touch, keyboard, and scrollbar dragging are not covered.',
  'Scroll snapping, smooth animation, and scroll anchoring are not covered.',
];

const documentHTML = (styles, body) => `<!doctype html>
<html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
<style>html,body{margin:0;padding:0}*{scroll-behavior:auto}${styles}</style></head>
<body>${body}</body></html>`;

const cases = [
  {
    name: 'vertical_auto_tall_child',
    purpose: 'Vertical overflow-y:auto with a tall child; checks scrollTop setters, scrollTo, scrollBy, and end clamping.',
    html: documentHTML(
      '#scroller{box-sizing:content-box;width:160px;height:100px;overflow-x:hidden;overflow-y:auto;padding:10px;border:4px solid} #child{width:120px;height:360px}',
      '<div id="scroller"><div id="child"></div></div>',
    ),
    targets: ['scroller', 'child'],
    actions: [
      { label: 'set_scroll_top_50', op: 'set', id: 'scroller', top: 50 },
      { label: 'scroll_to_top_130', op: 'scrollTo', id: 'scroller', top: 130, left: 0 },
      { label: 'scroll_by_top_45', op: 'scrollBy', id: 'scroller', top: 45, left: 0 },
      { label: 'clamp_to_end', op: 'scrollTo', id: 'scroller', top: 9999, left: 0 },
    ],
  },
  {
    name: 'horizontal_auto_wide_child',
    purpose: 'Horizontal overflow-x:auto with a wide child; checks scrollLeft setters, scrollTo, scrollBy, and end clamping.',
    html: documentHTML(
      '#scroller{box-sizing:content-box;width:140px;height:80px;overflow-x:auto;overflow-y:hidden;padding:7px 9px;border:3px solid} #child{width:420px;height:30px}',
      '<div id="scroller"><div id="child"></div></div>',
    ),
    targets: ['scroller', 'child'],
    actions: [
      { label: 'set_scroll_left_35', op: 'set', id: 'scroller', left: 35 },
      { label: 'scroll_to_left_115', op: 'scrollTo', id: 'scroller', top: 0, left: 115 },
      { label: 'scroll_by_left_70', op: 'scrollBy', id: 'scroller', top: 0, left: 70 },
      { label: 'clamp_to_end', op: 'scrollTo', id: 'scroller', top: 0, left: 9999 },
    ],
  },
  {
    name: 'both_axes_auto_padding_border',
    purpose: 'Two-axis overflow with content-box dimensions, padding, and border; records child position changes and both-axis clamping.',
    html: documentHTML(
      '#scroller{box-sizing:content-box;width:140px;height:100px;overflow:auto;padding:8px;border:3px solid} #child{width:420px;height:260px}',
      '<div id="scroller"><div id="child"></div></div>',
    ),
    targets: ['scroller', 'child'],
    actions: [
      { label: 'set_both_axes', op: 'set', id: 'scroller', left: 23, top: 31 },
      { label: 'scroll_to_110_90', op: 'scrollTo', id: 'scroller', top: 90, left: 110 },
      { label: 'scroll_by_45_55', op: 'scrollBy', id: 'scroller', top: 55, left: 45 },
      { label: 'clamp_both_axes_to_end', op: 'scrollTo', id: 'scroller', top: 9999, left: 9999 },
    ],
  },
  {
    name: 'hidden_programmatic_vs_clip',
    purpose: 'Contrasts overflow:hidden programmatic scrolling with overflow:clip, which is not a scroll container.',
    html: documentHTML(
      '#hidden{width:120px;height:70px;overflow:hidden;border:2px solid} #clip{width:120px;height:70px;overflow:clip;border:2px solid;margin-top:12px} .tall{width:100px;height:200px}',
      '<div id="hidden"><div id="hidden-child" class="tall"></div></div><div id="clip"><div id="clip-child" class="tall"></div></div>',
    ),
    targets: ['hidden', 'hidden-child', 'clip', 'clip-child'],
    actions: [
      { label: 'set_both_scroll_tops_40', op: 'setBoth', ids: ['hidden', 'clip'], top: 40 },
      { label: 'scroll_to_hidden_120', op: 'scrollTo', id: 'hidden', top: 120, left: 0 },
      { label: 'scroll_by_clip_20', op: 'scrollBy', id: 'clip', top: 20, left: 0 },
      { label: 'clamp_hidden_to_end', op: 'scrollTo', id: 'hidden', top: 9999, left: 0 },
    ],
  },
  {
    name: 'nested_vertical_scrollers',
    purpose: 'Nested vertical auto scrollers with a trailing outer child; tracks independent inner and outer offsets and descendant viewport coordinates.',
    html: documentHTML(
      '#outer{width:180px;height:110px;overflow-x:hidden;overflow-y:auto;padding:6px;border:2px solid} #inner{width:140px;height:70px;overflow-x:hidden;overflow-y:auto;padding:4px;border:2px solid} #inner-child{width:100px;height:280px} #tail{height:190px;width:100px}',
      '<div id="outer"><div id="inner"><div id="inner-child"></div></div><div id="tail"></div></div>',
    ),
    targets: ['outer', 'inner', 'inner-child', 'tail'],
    actions: [
      { label: 'set_inner_25_outer_60', op: 'setSequence', sequence: [{ id: 'inner', top: 25 }, { id: 'outer', top: 60 }] },
      { label: 'scroll_by_outer_30', op: 'scrollBy', id: 'outer', top: 30, left: 0 },
      { label: 'scroll_by_inner_40', op: 'scrollBy', id: 'inner', top: 40, left: 0 },
      { label: 'clamp_outer_to_end', op: 'scrollTo', id: 'outer', top: 9999, left: 0 },
    ],
  },
];

function assertFiniteRect(rect, label) {
  for (const key of ['x', 'y', 'width', 'height', 'top', 'right', 'bottom', 'left']) {
    if (!Number.isFinite(rect[key])) throw new Error(`${label} has a non-finite rect.${key}: ${rect[key]}`);
  }
}

async function settle(page) {
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
}

const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
  args: ['--disable-background-networking', '--disable-component-update', '--no-first-run'],
});

try {
  const browserVersion = await browser.version();
  if (!browserVersion.startsWith('153.')) throw new Error(`Expected dedicated Chromium 153, got ${browserVersion}`);

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
          page.on('console', message => { if (message.type() === 'error') consoleErrors.push(message.text()); });
          await page.route('**/*', route => route.abort());
          await page.setContent(item.html, { waitUntil: 'load' });
          await settle(page);

          await page.evaluate(targets => {
            window.__oracleScrollEvents = [];
            for (const id of targets) {
              const node = document.getElementById(id);
              if (!node) throw new Error(`Missing target #${id}`);
              node.addEventListener('scroll', () => window.__oracleScrollEvents.push({
                target: id,
                scrollLeft: node.scrollLeft,
                scrollTop: node.scrollTop,
              }));
            }
          }, item.targets);

          const snapshot = async label => {
            await settle(page);
            return page.evaluate(({ targets, label }) => {
              const observed = {};
              for (const id of targets) {
                const element = document.getElementById(id);
                if (!element) throw new Error(`Missing target #${id}`);
                const rect = element.getBoundingClientRect();
                const style = getComputedStyle(element);
                observed[id] = {
                  rect: rect.toJSON(),
                  clientRects: Array.from(element.getClientRects(), clientRect => clientRect.toJSON()),
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
                  overflowX: style.overflowX,
                  overflowY: style.overflowY,
                  direction: style.direction,
                  writingMode: style.writingMode,
                };
              }
              return {
                label,
                scrollX: window.scrollX,
                scrollY: window.scrollY,
                targets: observed,
                scrollEvents: window.__oracleScrollEvents.slice(),
              };
            }, { targets: item.targets, label });
          };

          const stages = [await snapshot('initial')];
          for (const action of item.actions) {
            await page.evaluate(action => {
              const node = id => {
                const target = document.getElementById(id);
                if (!target) throw new Error(`Missing action target #${id}`);
                return target;
              };
              switch (action.op) {
                case 'set':
                  if (action.left !== undefined) node(action.id).scrollLeft = action.left;
                  if (action.top !== undefined) node(action.id).scrollTop = action.top;
                  break;
                case 'setBoth':
                  for (const id of action.ids) node(id).scrollTop = action.top;
                  break;
                case 'setSequence':
                  for (const entry of action.sequence) {
                    if (entry.left !== undefined) node(entry.id).scrollLeft = entry.left;
                    if (entry.top !== undefined) node(entry.id).scrollTop = entry.top;
                  }
                  break;
                case 'scrollTo':
                  node(action.id).scrollTo(action.left, action.top);
                  break;
                case 'scrollBy':
                  node(action.id).scrollBy(action.left, action.top);
                  break;
                default:
                  throw new Error(`Unknown scroll action ${action.op}`);
              }
            }, action);
            stages.push(await snapshot(action.label));
          }

          if (pageErrors.length) throw new Error(pageErrors.join('\n'));
          if (consoleErrors.length) throw new Error(consoleErrors.join('\n'));
          for (const stage of stages) {
            if (!Number.isFinite(stage.scrollX) || !Number.isFinite(stage.scrollY)) throw new Error(`${item.name} has non-finite window scroll offsets`);
            for (const [id, observed] of Object.entries(stage.targets)) {
              assertFiniteRect(observed.rect, `${item.name} #${id} ${stage.label}`);
              for (const rect of observed.clientRects) assertFiniteRect(rect, `${item.name} #${id} ${stage.label} client rect`);
              for (const key of ['clientWidth', 'clientHeight', 'clientLeft', 'clientTop', 'offsetWidth', 'offsetHeight', 'scrollWidth', 'scrollHeight', 'scrollLeft', 'scrollTop']) {
                if (!Number.isFinite(observed[key])) throw new Error(`${item.name} #${id} has non-finite ${key}`);
              }
            }
          }

          outputCases.push({
            name: item.name,
            purpose: item.purpose,
            authoredHTML: item.html,
            targets: item.targets,
            actions: item.actions,
            viewportWidth,
            viewportHeight,
            theme,
            deviceScaleFactor,
            textScale: 'default',
            unsupported,
            expected: { stages },
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
      remoteRequests: 'blocked',
      scrollbarMode: 'Measured directly; no overlay/non-overlay assumption is encoded.',
    },
    cases: outputCases,
  };
  await writeFile(outputPath, `${JSON.stringify(fixture, null, 2)}\n`);
  console.log(`Captured ${cases.length} cases (${outputCases.length} viewport/theme entries) with Chromium ${browserVersion}: ${outputPath.pathname}`);
} finally {
  await browser.close();
}
