import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import {
  scrollRectModes,
  scrollRectHTML,
  buildScrollRectDriver,
} from './document_scroll_rect_fixture.mjs';
const fixture = JSON.parse(
  readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-scroll-rect-chromium153.json', import.meta.url)),
);
const bundle = readFileSync(
  process.env.PIRC_DOCUMENT_SCRIPT_RUNTIME_BUNDLE ||
    fileURLToPath(new URL('../../assets/document-script-runtime.js', import.meta.url)),
  'utf8',
);
function runtime(row = fixture.cases[0]) {
  const c = vm.createContext({}, { microtaskMode: 'afterEvaluate' }),
    run = (s) => new vm.Script(s).runInContext(c);
  run(bundle);
  const invoke = (method, args) =>
    JSON.parse(run(`__pircDocument.${method}(${JSON.stringify(args)})`));
  const initial = invoke('init', {
    hostLayout: true,
    url: 'https://example.test/scroll-rect',
    html: row.html,
  });
  const ids = {};
  for (const name of ['outer', 'inner', 'target', 'outside', 'fixed'])
    ids[name] = run(`document.getElementById('${name}').getAttribute('data-pirc-script-id')`);
  let generation = 0;
  const packet = (state = row.result.before, through = 0) => ({
    revision: initial.layout.revision,
    generation: ++generation,
    scrollActionThrough: through,
    viewport: {
      ...row.viewport,
      scrollX: state.root[0],
      scrollY: state.root[1],
      contentWidth: row.viewport.width,
      contentHeight: 2400,
      scrollRange: { minLeft: 0, maxLeft: 0, minTop: 0, maxTop: 2400 - row.viewport.height },
    },
    boxes: initial.layout.ids.map((id) => {
      const name = Object.keys(ids).find((n) => ids[n] === id),
        measured = state.boxes[name];
      if (!measured) return { id, kind: 'none' };
      const [x, y, width, height] =
        state === row.result.before ? row.paint.rects[name] : measured.rect;
      const deps = name === 'target' ? ['inner', 'outer'] : name === 'inner' ? ['outer'] : [];
      const port = row.scrollports[name];
      return {
        id,
        kind: 'box',
        x: x + state.root[0],
        y: y + state.root[1],
        width,
        height,
        scrollGeometry: {
          viewport: name !== 'fixed',
          ancestors: deps.map((n) => ({ id: ids[n], axes: row.paint.axes[n] })),
        },
        ...(port
          ? {
              scroll: {
                left: state[name][0],
                top: state[name][1],
                width: port.width,
                height: port.height,
                range: {
                  minLeft: 0,
                  maxLeft: port.width - port.clientWidth,
                  minTop: 0,
                  maxTop: port.height - port.clientHeight,
                },
              },
            }
          : {}),
      };
    }),
  });
  invoke('updateLayout', packet());
  return { run, invoke, packet, ids, row };
}
function near(actual, expected, path = '') {
  if (typeof expected === 'number') {
    assert.ok(
      Number.isFinite(actual) && Math.abs(actual - expected) <= 0.001,
      `${path}: ${actual} != ${expected}`,
    );
    return;
  }
  if (expected && typeof expected === 'object') {
    assert.deepEqual(Object.keys(actual), Object.keys(expected), path);
    for (const key of Object.keys(expected)) near(actual[key], expected[key], `${path}.${key}`);
    return;
  }
  assert.equal(actual, expected, path);
}
test('128 independent Chromium scroll rectangle profiles preserve exact shared source and input locations', () => {
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(fixture.cases.length, 128);
  assert.equal(scrollRectModes.length, 16);
  assert.equal(
    new Set(fixture.cases.map((r) => [r.mode, r.viewport.width, r.dpr, r.theme].join('/'))).size,
    128,
  );
  for (const r of fixture.cases) {
    assert.equal(r.html, scrollRectHTML(r.mode));
    assert.equal(r.driverSource, buildScrollRectDriver(r.mode));
    if (['canvas', 'self-canvas'].includes(r.mode))
      assert.ok(Number.isFinite(r.tap.x) && Number.isFinite(r.tap.y));
  }
});
test('shipped synchronous rectangles and client rects match all 128 browser traces', () => {
  for (const row of fixture.cases) {
    const r = runtime(row);
    r.run(row.driverSource);
    r.run(
      `document.getElementById('${['canvas', 'self-canvas'].includes(row.mode) ? 'target' : 'run'}').click()`,
    );
    assert.deepEqual(
      r.invoke('snapshot', {}).diagnostics.filter((d) => d.severity !== 'info'),
      [],
      row.mode,
    );
    near(
      JSON.parse(r.run('JSON.stringify(window.scrollRectReport)')),
      { before: row.result.before, trace: row.result.trace, immediate: row.result.immediate },
      row.mode,
    );
  }
});
test('fixed and unrelated boxes remain readable across pending unrelated element scrolling', () => {
  const r = runtime();
  r.run('document.getElementById("outer").scrollBy({top:30,behavior:"instant"})');
  assert.equal(r.run('document.getElementById("fixed").getBoundingClientRect().top'), 20);
  assert.equal(
    r.run('document.getElementById("outside").getBoundingClientRect().top'),
    r.row.result.before.boxes.outside.rect[1],
  );
});
test('old measurements retain later rectangle updates until the exact command prefix is acknowledged', () => {
  const row = fixture.cases.find((r) => r.mode === 'combined'),
    r = runtime(row);
  r.run(row.driverSource);
  r.run('document.getElementById("run").click()');
  r.invoke('snapshot', {});
  r.invoke('updateLayout', r.packet(row.result.trace[0], 1));
  assert.deepEqual(
    JSON.parse(
      r.run(
        'JSON.stringify([document.getElementById("target").getBoundingClientRect().x,document.getElementById("target").getBoundingClientRect().y])',
      ),
    ),
    row.result.immediate.boxes.target.rect.slice(0, 2),
  );
  r.invoke('updateLayout', r.packet(row.result.immediate, 3));
  assert.deepEqual(
    JSON.parse(
      r.run(
        'JSON.stringify([document.getElementById("target").getBoundingClientRect().x,document.getElementById("target").getBoundingClientRect().y])',
      ),
    ),
    row.result.immediate.boxes.target.rect.slice(0, 2),
  );
});
test('invalid geometry proofs reject atomically without replacing valid positions', () => {
  const r = runtime(),
    base = r.packet(),
    target = base.boxes.find((b) => b.id === r.ids.target),
    valid = target.scrollGeometry;
  const invalid = [
    null,
    { viewport: 'yes', ancestors: [] },
    { viewport: true, ancestors: [{ id: r.ids.outer, axes: [1, 0, 0] }] },
    { viewport: true, ancestors: [{ id: r.ids.outside, axes: [1, 0, 0, 1] }] },
    {
      viewport: true,
      ancestors: [
        { id: r.ids.outer, axes: [1, 0, 0, 1] },
        { id: r.ids.outer, axes: [1, 0, 0, 1] },
      ],
    },
    {
      viewport: true,
      ancestors: Array.from({ length: 65 }, () => ({ id: r.ids.outer, axes: [1, 0, 0, 1] })),
    },
  ];
  for (const proof of invalid) {
    target.scrollGeometry = proof;
    assert.throws(
      () => r.invoke('updateLayout', base),
      (e) => ['TypeError', 'RangeError'].includes(e.name),
    );
  }
  target.scrollGeometry = valid;
  r.invoke('updateLayout', base);
  assert.equal(
    r.run('document.getElementById("target").getBoundingClientRect().top'),
    r.row.result.before.boxes.target.rect[1],
  );
});
test('missing geometry proof and DOM size mutations keep an explicit native-layout fence', () => {
  const r = runtime(),
    p = r.packet();
  delete p.boxes.find((b) => b.id === r.ids.target).scrollGeometry;
  r.invoke('updateLayout', p);
  r.run('window.scrollBy({top:40,behavior:"instant"})');
  assert.throws(
    () => r.run('document.getElementById("target").getBoundingClientRect()'),
    (e) => e.name === 'NotSupportedError',
  );
  const s = runtime();
  s.run(
    'document.getElementById("target").style.height="90px";window.scrollBy({top:40,behavior:"instant"})',
  );
  assert.throws(
    () => s.run('document.getElementById("target").getBoundingClientRect()'),
    (e) => e.name === 'NotSupportedError',
  );
});
