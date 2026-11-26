import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import {
  scrollFeedbackHTML,
  buildScrollFeedbackDriver,
} from './document_scroll_feedback_fixture.mjs';
const fixture = JSON.parse(
  readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-scroll-feedback-chromium153.json', import.meta.url)),
);
const bundle = readFileSync(
  process.env.PIRC_DOCUMENT_SCRIPT_RUNTIME_BUNDLE ||
    fileURLToPath(new URL('../../assets/document-script-runtime.js', import.meta.url)),
  'utf8',
);
function runtime(row = { viewport: { width: 390, height: 844 } }) {
  const c = vm.createContext({}, { microtaskMode: 'afterEvaluate' });
  const run = (s) => new vm.Script(s).runInContext(c);
  run(bundle);
  const invoke = (method, argument) =>
    JSON.parse(run(`__pircDocument.${method}(${JSON.stringify(argument)})`));
  const initial = invoke('init', {
    hostLayout: true,
    url: 'https://example.test/feedback',
    html: scrollFeedbackHTML,
  });
  const id = (selector) =>
    run(`document.querySelector(${JSON.stringify(selector)}).getAttribute('data-pirc-script-id')`);
  const port = id('#port'),
    root = id('html');
  let generation = 0;
  const packet = (overrides = {}) => ({
    revision: initial.layout.revision,
    generation: ++generation,
    scrollActionThrough: 0,
    viewport: {
      ...row.viewport,
      scrollX: 0,
      scrollY: 0,
      contentWidth: row.viewport.width,
      contentHeight: 2200,
      scrollRange: { minLeft: 0, maxLeft: 0, minTop: 0, maxTop: 2200 - row.viewport.height },
    },
    boxes: initial.layout.ids.map((id) =>
      id === port
        ? {
            id,
            kind: 'box',
            x: 0,
            y: 0,
            width: 180,
            height: 100,
            scroll: {
              left: 0,
              top: 0,
              width: 600,
              height: 800,
              range: { minLeft: 0, maxLeft: 420, minTop: 0, maxTop: 700 },
            },
          }
        : id === root
          ? { id, kind: 'box', x: 0, y: 0, width: row.viewport.width, height: 2200 }
          : { id, kind: 'none' },
    ),
    ...overrides,
  });
  invoke('updateLayout', packet());
  return { run, invoke, packet, port, root };
}
test('96 independent Chromium profiles preserve the exact shared feedback source', () => {
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(fixture.html, scrollFeedbackHTML);
  assert.equal(fixture.cases.length, 96);
  assert.equal(
    new Set(
      fixture.cases.map((r) => [r.mode, r.target, r.viewport.width, r.dpr, r.theme].join('/')),
    ).size,
    96,
  );
  for (const r of fixture.cases)
    assert.equal(r.driverSource, buildScrollFeedbackDriver(r.mode, r.target));
});
test('shipped synchronous setters, aliases, clamping, mixed calls and Promise jobs match Chromium', () => {
  for (const row of fixture.cases.filter((r) => r.mode !== 'raf-add')) {
    const { run, invoke } = runtime(row);
    run(row.driverSource);
    run('document.getElementById("run").click()');
    assert.deepEqual(
      JSON.parse(run('JSON.stringify(window.feedbackTrace)')),
      row.result.trace,
      `${row.mode}/${row.target}/trace`,
    );
    assert.deepEqual(
      JSON.parse(run('JSON.stringify(window.feedbackImmediate)')),
      row.result.immediate,
      `${row.mode}/${row.target}/immediate`,
    );
    assert.deepEqual(
      invoke('snapshot', {}).diagnostics.filter((d) => d.severity !== 'info'),
      [],
    );
  }
});
test('response draining and old measurements retain new commands until their exact prefix is acknowledged', () => {
  const { run, invoke, packet, port } = runtime();
  run('var p=document.getElementById("port");p.scrollTop+=20;p.scrollTop+=20');
  const first = invoke('snapshot', {});
  assert.deepEqual(
    first.scrollActions.map((a) => a.y),
    [20, 40],
  );
  assert.equal(run('p.scrollTop'), 40);
  invoke('updateLayout', packet());
  assert.equal(run('p.scrollTop'), 40, 'an old frame cannot wipe pending commands');
  run('p.scrollTop+=20');
  const second = invoke('snapshot', {});
  assert.equal(second.scrollActions[0].y, 60);
  const partial = packet({ scrollActionThrough: 2 });
  partial.boxes.find((b) => b.id === port).scroll.top = 40;
  invoke('updateLayout', partial);
  assert.equal(run('p.scrollTop'), 60, 'a delayed prefix retains later commands');
  const all = packet({ scrollActionThrough: 3 });
  all.boxes.find((b) => b.id === port).scroll.top = 55;
  invoke('updateLayout', all);
  assert.equal(run('p.scrollTop'), 55, 'actual native pixels win after acknowledgement');
});
test('acknowledgements and measured ranges validate atomically and monotonically', () => {
  const { run, invoke, packet } = runtime();
  run('window.scrollTo(0,20);window.scrollTo(0,40)');
  const p = packet();
  for (const bad of [-1, 0.5, 3, null])
    assert.throws(
      () => invoke('updateLayout', { ...p, scrollActionThrough: bad }),
      (e) => e.name === 'RangeError',
    );
  for (const bad of [
    null,
    { minLeft: 0, maxLeft: 0, minTop: 5, maxTop: 1 },
    { minLeft: 0, maxLeft: 0, minTop: 0, maxTop: '99' },
  ])
    assert.throws(
      () => invoke('updateLayout', { ...p, viewport: { ...p.viewport, scrollRange: bad } }),
      (e) => ['RangeError', 'TypeError'].includes(e.name),
    );
  assert.equal(run('window.scrollY'), 40);
  invoke('updateLayout', {
    ...p,
    scrollActionThrough: 1,
    viewport: { ...p.viewport, scrollY: 20 },
  });
  assert.equal(run('window.scrollY'), 40);
  assert.throws(
    () => invoke('updateLayout', { ...packet(), scrollActionThrough: 0 }),
    (e) => e.name === 'RangeError',
  );
});
test('pending scrolling never supplies fabricated element rectangles or stale bounds after mutations', () => {
  const { run, invoke, packet, port } = runtime();
  run('var p=document.getElementById("port");p.scrollTop=20');
  assert.throws(
    () => run('p.getBoundingClientRect()'),
    (e) => e.name === 'NotSupportedError',
  );
  assert.throws(
    () => run('p.getClientRects()'),
    (e) => e.name === 'NotSupportedError',
  );
  const p = packet({ scrollActionThrough: 1 });
  p.boxes.find((b) => b.id === port).scroll.top = 20;
  invoke('updateLayout', p);
  assert.equal(run('p.getBoundingClientRect().top'), 0);
  run('window.scrollTo(0,80);p.style.height="200px"');
  assert.throws(
    () => run('document.documentElement.scrollTop'),
    (e) => e.name === 'NotSupportedError',
  );
});
test('missing native ranges are explicit and disabled axes clamp to their actual zero range', () => {
  const { run, invoke, packet, port } = runtime();
  const missing = packet();
  delete missing.boxes.find((b) => b.id === port).scroll.range;
  invoke('updateLayout', missing);
  run('var p=document.getElementById("port");p.scrollTop=20');
  assert.throws(
    () => run('p.scrollTop'),
    (e) => e.name === 'NotSupportedError',
  );
  const disabled = packet({ scrollActionThrough: 1 });
  disabled.boxes.find((b) => b.id === port).scroll.range = {
    minLeft: 0,
    maxLeft: 0,
    minTop: 0,
    maxTop: 0,
  };
  invoke('updateLayout', disabled);
  run('p.scrollLeft=100;p.scrollTop=100');
  assert.equal(run('p.scrollLeft+p.scrollTop'), 0);
});
test('native scroll events use actual transitions rather than projected guest positions', () => {
  const { run, invoke, packet } = runtime();
  run(
    'window.events=0;document.addEventListener("scroll",()=>{window.events++});window.scrollTo(0,20)',
  );
  invoke('snapshot', {});
  invoke('updateLayout', packet());
  assert.equal(run('window.events'), 0);
  const p = packet();
  p.viewport.scrollY = 10;
  invoke('updateLayout', p);
  assert.equal(run('window.events'), 1);
  invoke('updateLayout', { ...packet(), scrollActionThrough: 1, viewport: p.viewport });
  assert.equal(run('window.events'), 1);
  assert.equal(run('window.scrollY'), 10);
});
test('visibility cancellation drops stale feedback and a new document starts with an empty ledger', () => {
  const { run, invoke } = runtime();
  run('window.scrollTo(0,80)');
  assert.equal(run('window.scrollY'), 80);
  invoke('updateVisibility', { hidden: true });
  assert.equal(run('window.scrollY'), 0);
  const fresh = runtime();
  assert.equal(fresh.run('window.scrollY'), 0);
  assert.deepEqual(fresh.invoke('snapshot', {}).scrollActions, []);
});
test('the feedback ledger remains bounded across response snapshots', () => {
  const { run, invoke } = runtime();
  for (let i = 0; i < 128; i++) {
    run('window.scrollBy(0,1)');
    invoke('snapshot', {});
  }
  run('window.scrollBy(0,1)');
  const result = invoke('snapshot', {});
  assert.equal(result.scrollActions.length, 0);
  assert.equal(result.diagnostics.filter((d) => d.code === 'layout.scroll_action_limit').length, 1);
  assert.equal(run('window.scrollY'), 128);
});

test('standards root scroll aliases use the measured viewport even without a separate root box', () => {
  const { run, invoke, packet, root } = runtime();
  const p = packet();
  p.boxes = p.boxes.map((b) => (b.id === root ? { id: root, kind: 'none' } : b));
  invoke('updateLayout', p);
  run('document.documentElement.scrollTop+=20;document.documentElement.scrollTop+=20');
  assert.equal(run('window.scrollY'), 40);
  assert.equal(run('document.documentElement.scrollTop'), 40);
  assert.equal(run('document.documentElement.scrollHeight'), 2200);
  assert.equal(run('document.documentElement.clientWidth'), 390);
  assert.equal(run('document.documentElement.clientHeight'), 844);
});
