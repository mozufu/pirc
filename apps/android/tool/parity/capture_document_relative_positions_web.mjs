import { requireTestBrowserExecutable } from './test_browser.mjs';
import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';

const outputPath = new URL(
  '../../../../packages/pirc_render/test/fixtures/parity/document-relative-positions-chromium153.json',
  import.meta.url,
);
const projectRequire = createRequire(
  new URL('../../../../package.json', import.meta.url),
);
const { chromium } = projectRequire('playwright-core');

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
    name: 'relative_positive_top_left_insets',
    purpose:
      'Positive top and left insets move the relative box while preserving its normal-flow slot for the next sibling.',
    styles:
      'body{margin:0}#outer{width:400px;border:1px solid}#subject{position:relative;top:12px;left:17px;width:40px;height:20px}#after{width:50px;height:10px}',
    body: '<div id="outer"><div id="subject"></div><div id="after"></div></div>',
    targets: ['html', 'body', 'outer', 'subject', 'after'],
  },
  {
    name: 'relative_negative_fractional_top_left_insets',
    purpose:
      'Negative half-pixel top and left insets preserve browser fractional border-box coordinates and native integer offsets.',
    styles:
      'body{margin:0}#outer{width:400px;border:1px solid}#subject{position:relative;top:-7.5px;left:-4.5px;width:40px;height:20px}#after{width:50px;height:10px}',
    body: '<div id="outer"><div id="subject"></div><div id="after"></div></div>',
    targets: ['html', 'body', 'outer', 'subject', 'after'],
  },
  {
    name: 'relative_positive_right_bottom_only_insets',
    purpose:
      'With top and left auto, positive right and bottom insets shift a relative box toward negative left and top.',
    styles:
      'body{margin:0}#outer{width:400px;border:1px solid}#parent{width:240px;height:120px;border:1px solid}#subject{position:relative;top:auto;right:12px;bottom:9px;left:auto;width:50px;height:30px}',
    body: '<div id="outer"><div id="parent"><div id="subject"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'subject'],
  },
  {
    name: 'relative_negative_right_bottom_only_insets',
    purpose:
      'Negative right and bottom insets with the opposite sides auto shift a relative box toward positive left and top.',
    styles:
      'body{margin:0}#outer{width:400px;border:1px solid}#parent{width:240px;height:120px;border:1px solid}#subject{position:relative;top:auto;right:-12.5px;bottom:-8.5px;left:auto;width:50px;height:30px}',
    body: '<div id="outer"><div id="parent"><div id="subject"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'subject'],
  },
  {
    name: 'relative_all_auto_insets_leave_normal_position',
    purpose:
      'All auto insets leave the relatively positioned element in its normal-flow position.',
    styles:
      'body{margin:0}#outer{width:400px;border:1px solid}#subject{position:relative;top:auto;right:auto;bottom:auto;left:auto;width:40px;height:20px}#after{width:50px;height:10px}',
    body: '<div id="outer"><div id="subject"></div><div id="after"></div></div>',
    targets: ['html', 'body', 'outer', 'subject', 'after'],
  },
  {
    name: 'relative_overconstrained_insets_follow_parent_direction',
    purpose:
      'The same overconstrained horizontal insets resolve by inherited LTR or RTL direction; top wins over bottom on both boxes.',
    styles:
      'body{margin:0}#outer{width:400px;border:1px solid}.direction{width:160px;height:80px;border:1px solid;margin-bottom:8px}.relative{position:relative;top:12px;bottom:6px;left:15px;right:25px;width:40px;height:20px}#ltr{direction:ltr}#rtl{direction:rtl}',
    body:
      '<div id="outer"><div id="ltr" class="direction"><div id="ltrSubject" class="relative"></div></div><div id="rtl" class="direction" dir="rtl"><div id="rtlSubject" class="relative"></div></div></div>',
    targets: [
      'html',
      'body',
      'outer',
      'ltr',
      'ltrSubject',
      'rtl',
      'rtlSubject',
    ],
  },
  {
    name: 'relative_overconstraint_uses_containing_direction_not_child_direction',
    purpose:
      'Overconstrained left/right insets follow the containing block direction even when the child explicitly has the opposite direction.',
    styles:
      'body{margin:0}#outer{width:400px;border:1px solid}.direction{width:160px;height:80px;border:1px solid;margin-bottom:8px}.relative{position:relative;top:12px;bottom:6px;left:15px;right:25px;width:40px;height:20px}#ltrParent{direction:ltr}#rtlParent{direction:rtl}#ltrChild{direction:rtl}#rtlChild{direction:ltr}',
    body:
      '<div id="outer"><div id="ltrParent" class="direction"><div id="ltrChild" class="relative"></div></div><div id="rtlParent" class="direction"><div id="rtlChild" class="relative"></div></div></div>',
    targets: [
      'html',
      'body',
      'outer',
      'ltrParent',
      'ltrChild',
      'rtlParent',
      'rtlChild',
    ],
  },
  {
    name: 'relative_percent_insets_use_definite_containing_block_size',
    purpose:
      'Relative left 10% uses the 300px content width and top 10% uses the definite 200px content height.',
    styles:
      'body{margin:0}#outer{width:400px;border:1px solid}#parent{box-sizing:content-box;width:300px;height:200px;border:1px solid;padding:10px}#subject{position:relative;top:10%;left:10%;width:50px;height:30px}',
    body: '<div id="outer"><div id="parent"><div id="subject"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'subject'],
  },
  {
    name: 'relative_vertical_percent_inset_in_auto_height_container',
    purpose:
      'A relative 25% top inset in an auto-height parent captures Chromium behavior when the parent height depends on content.',
    styles:
      'body{margin:0}#outer{width:400px;border:1px solid}#parent{width:300px;border:1px solid}#subject{position:relative;top:25%;left:10%;width:50px;height:30px}#filler{height:20px}',
    body: '<div id="outer"><div id="parent"><div id="subject"></div><div id="filler"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'subject', 'filler'],
  },
  {
    name: 'relative_nested_offsets_cancel_and_leave_sibling_flow',
    purpose:
      'A relative child with opposite insets cancels its relative parent visually; following in-flow siblings retain their original positions.',
    styles:
      'body{margin:0}#outer{width:400px;border:1px solid}#parent{position:relative;top:15px;left:12px;width:200px;height:60px}#child{position:relative;top:-15px;left:-12px;width:40px;height:20px}#innerAfter{width:60px;height:10px}#following{width:70px;height:10px}',
    body:
      '<div id="outer"><div id="parent"><div id="child"></div><div id="innerAfter"></div></div><div id="following"></div></div>',
    targets: [
      'html',
      'body',
      'outer',
      'parent',
      'child',
      'innerAfter',
      'following',
    ],
  },
  {
    name: 'relative_insets_preserve_parent_child_margin_collapse',
    purpose:
      'Relative insets change painted positions without changing positive parent/first-child margin collapse or the next sibling flow position.',
    styles:
      'body{margin:0}#outer{width:400px;border:1px solid}#parent{position:relative;top:5px;left:3px;width:200px;margin-top:18px}#child{position:relative;top:-6px;left:4px;width:50px;height:12px;margin-top:28px}#following{width:60px;height:10px}',
    body:
      '<div id="outer"><div id="parent"><div id="child"></div></div><div id="following"></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'child', 'following'],
  },
  {
    name: 'relative_child_inside_bordered_padded_parent',
    purpose:
      'A relative child is measured inside a containing block with border and padding on every edge.',
    styles:
      'body{margin:0}#outer{width:400px;border:1px solid}#parent{box-sizing:content-box;width:240px;height:100px;border:3px solid;padding:8px}#subject{position:relative;top:5px;left:7px;width:60px;height:20px}',
    body: '<div id="outer"><div id="parent"><div id="subject"></div></div></div>',
    targets: ['html', 'body', 'outer', 'parent', 'subject'],
  },
  {
    name: 'relative_html_and_body_insets',
    purpose:
      'The root html and body boxes both use relative insets while body keeps its default 8px margin.',
    styles:
      'html{position:relative;top:10px;left:7px}body{position:relative;top:-4px;left:-3px}#child{width:50px;height:20px}',
    body: '<div id="child"></div>',
    targets: ['html', 'body', 'child'],
  },
  {
    name: 'relative_subject_scrolled_in_overflow_auto',
    purpose:
      'A half-pixel relative subject is measured before and after scrolling an overflow:auto ancestor in both axes.',
    styles:
      'body{margin:0}#outer{width:300px;border:1px solid}#scroller{position:relative;top:5.5px;left:7.5px;box-sizing:border-box;width:140px;height:90px;padding:5px;border:2px solid;overflow:auto}#spacer{width:260px;height:120px}#subject{position:relative;top:-2.5px;left:-3.5px;width:180px;height:20px}',
    body:
      '<div id="outer"><div id="scroller"><div id="spacer"></div><div id="subject"></div></div></div>',
    targets: ['html', 'body', 'outer', 'scroller', 'spacer', 'subject'],
    states: [
      { name: 'initial', elementScroll: { scroller: { left: 0, top: 0 } } },
      {
        name: 'scrolled',
        elementScroll: { scroller: { left: 37.5, top: 41.5 } },
      },
    ],
  },
  {
    name: 'relative_subject_scrolled_in_overflow_hidden',
    purpose:
      'Programmatic scrolling of an overflow:hidden ancestor changes the relative subject rect while preserving its native offset values.',
    styles:
      'body{margin:0}#outer{width:300px;border:1px solid}#scroller{position:relative;top:5.5px;left:7.5px;box-sizing:border-box;width:140px;height:90px;padding:5px;border:2px solid;overflow:hidden}#spacer{width:260px;height:120px}#subject{position:relative;top:-2.5px;left:-3.5px;width:180px;height:20px}',
    body:
      '<div id="outer"><div id="scroller"><div id="spacer"></div><div id="subject"></div></div></div>',
    targets: ['html', 'body', 'outer', 'scroller', 'spacer', 'subject'],
    states: [
      { name: 'initial', elementScroll: { scroller: { left: 0, top: 0 } } },
      {
        name: 'scrolled',
        elementScroll: { scroller: { left: 37.5, top: 41.5 } },
      },
    ],
  },
  {
    name: 'relative_inline_span_grid_children_are_blockified',
    purpose:
      'Default inline span children become grid items despite common indentation whitespace; the relative subject uses its fixed row and column tracks.',
    styles:
      'body{margin:0}#outer{width:400px;border:1px solid}#grid{display:grid;grid-template-columns:100px 100px;grid-template-rows:60px;width:300px}#subject{position:relative;top:8px;left:7px;width:40px;height:20px}#after{width:30px;height:10px}',
    body:
      '<div id="outer"><div id="grid">\n        <span id="subject"></span>\n        <span id="after"></span>\n      </div></div>',
    targets: ['html', 'body', 'outer', 'grid', 'subject', 'after'],
  },
  {
    name: 'relative_flex_and_grid_children_keep_flow_slots',
    purpose:
      'Relative insets move flex and grid items visually while preserving subsequent item positions and tracks.',
    styles:
      'body{margin:0}#outer{width:400px;border:1px solid}#flex{display:flex;width:300px;height:100px}#flexSubject{position:relative;top:8px;left:7px;width:80px;height:30px}#flexAfter{width:60px;height:20px}#grid{display:grid;grid-template-columns:100px 100px;grid-template-rows:60px;width:300px;margin-top:12px}#gridSubject{position:relative;top:-5px;left:12px;width:40px;height:20px}#gridAfter{width:30px;height:10px}',
    body:
      '<div id="outer"><div id="flex"><div id="flexSubject"></div><div id="flexAfter"></div></div><div id="grid"><div id="gridSubject"></div><div id="gridAfter"></div></div></div>',
    targets: [
      'html',
      'body',
      'outer',
      'flex',
      'flexSubject',
      'flexAfter',
      'grid',
      'gridSubject',
      'gridAfter',
    ],
  },
  {
    name: 'relative_percent_insets_after_viewport_resize',
    purpose:
      'Relative 10% left insets resolve against an auto-width parent after resizing from the other reference viewport; top uses its definite 160px height.',
    styles:
      'body{margin:0}#parent{box-sizing:border-box;width:auto;height:160px;border:1px solid}#subject{position:relative;top:10%;left:10%;width:40px;height:30px}',
    body: '<div id="parent"><div id="subject"></div></div>',
    targets: ['html', 'body', 'parent', 'subject'],
    resizeFromOtherViewport: true,
  },
];

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
  for (const side of ['top', 'right', 'bottom', 'left']) {
    if (typeof value.computedInsets[side] !== 'string') {
      throw new Error(`${label} has no computed ${side} inset`);
    }
  }
  for (const key of ['width', 'height']) {
    if (!Number.isFinite(value.parentContentSize[key])) {
      throw new Error(`${label} has a non-finite parent content ${key}`);
    }
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

async function setState(page, state) {
  await page.evaluate(({ windowScroll, elementScroll }) => {
    if (windowScroll) window.scrollTo(windowScroll.x, windowScroll.y);
    for (const [id, scroll] of Object.entries(elementScroll || {})) {
      document.getElementById(id).scrollTo(scroll.left, scroll.top);
    }
  }, {
    windowScroll: state.windowScroll || { x: 0, y: 0 },
    elementScroll: state.elementScroll || {},
  });
  await waitForLayout(page);
}

async function measure(page, targets) {
  return page.evaluate(targetIds => {
    const pixel = value => Number.parseFloat(value) || 0;
    const contentSize = element => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return {
        width:
          rect.width -
          pixel(style.borderLeftWidth) -
          pixel(style.borderRightWidth) -
          pixel(style.paddingLeft) -
          pixel(style.paddingRight),
        height:
          rect.height -
          pixel(style.borderTopWidth) -
          pixel(style.borderBottomWidth) -
          pixel(style.paddingTop) -
          pixel(style.paddingBottom),
      };
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
        computedPosition: style.position,
        computedDirection: style.direction,
        computedInsets: {
          top: style.top,
          right: style.right,
          bottom: style.bottom,
          left: style.left,
        },
        parentContentSize: parent
          ? contentSize(parent)
          : { width: window.innerWidth, height: window.innerHeight },
        parentComputedSize: parent
          ? {
              width: getComputedStyle(parent).width,
              height: getComputedStyle(parent).height,
            }
          : { width: `${window.innerWidth}px`, height: `${window.innerHeight}px` },
        ...(id === 'scroller'
          ? {
              scroll: {
                left: element.scrollLeft,
                top: element.scrollTop,
                width: element.scrollWidth,
                height: element.scrollHeight,
                clientWidth: element.clientWidth,
                clientHeight: element.clientHeight,
              },
            }
          : {}),
      };
    }
    return {
      expected,
      windowScroll: { x: window.scrollX, y: window.scrollY },
      documentMetrics: {
        innerWidth: window.innerWidth,
        innerHeight: window.innerHeight,
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

        const states = [];
        for (const state of item.states || [{ name: 'initial' }]) {
          await setState(page, state);
          const measured = await measure(page, item.targets);
          if (pageErrors.length) throw new Error(pageErrors.join('\n'));
          if (consoleErrors.length) throw new Error(consoleErrors.join('\n'));
          for (const id of item.targets) {
            assertFiniteMeasurement(measured.expected[id], `${item.name} #${id}`);
          }
          for (const [key, value] of Object.entries(measured.documentMetrics)) {
            if (!Number.isFinite(value)) {
              throw new Error(`${item.name} document ${key} is non-finite`);
            }
          }
          states.push({
            name: state.name,
            windowScroll: measured.windowScroll,
            elementScroll: state.elementScroll || {},
            expected: measured.expected,
            documentMetrics: measured.documentMetrics,
          });
        }

        if (beforeResize) {
          for (const id of item.targets) {
            assertFiniteMeasurement(beforeResize.expected[id], `${item.name} before resize #${id}`);
          }
        }
        outputCases.push({
          name: item.name,
          purpose: item.purpose,
          styles: { common: commonStyles, case: item.styles },
          authoredHTML,
          targets: item.targets,
          viewportWidth: viewport.width,
          viewportHeight: viewport.height,
          ...(item.resizeFromOtherViewport
            ? {
                resizedFrom: startingViewport,
                beforeResizeExpected: beforeResize.expected,
                beforeResizeWindowScroll: beforeResize.windowScroll,
              }
            : {}),
          states,
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
        'getBoundingClientRect border boxes, native offset properties, computed direction and insets, parent content size, and scroll metrics',
    },
    cases: outputCases,
  };
  await writeFile(outputPath, `${JSON.stringify(output)}\n`);
  console.log(
    `Wrote ${outputCases.length} relative-position observations to ${outputPath.pathname}`,
  );
} finally {
  await browser.close();
}
