import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import {
  scrollBehaviorModes,
  scrollBehaviorHTML,
  buildScrollBehaviorDriver,
} from './document_scroll_behavior_fixture.mjs';
const f = JSON.parse(
  readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-scroll-behavior-chromium153.json', import.meta.url)),
);
const bundle = readFileSync(
  process.env.PIRC_DOCUMENT_SCRIPT_RUNTIME_BUNDLE ||
    fileURLToPath(new URL('../../assets/document-script-runtime.js', import.meta.url)),
  'utf8',
);
function runtime(row) {
  const context = vm.createContext({}, { microtaskMode: 'afterEvaluate' }),
    run = (s) => new vm.Script(s).runInContext(context),
    invoke = (m, a) => JSON.parse(run(`__pircDocument.${m}(${JSON.stringify(a)})`));
  run(bundle);
  const initial = invoke('init', {
    hostLayout: true,
    url: 'https://example.test/behavior',
    html: row.html,
  });
  const id = (selector) =>
      run(
        `document.querySelector(${JSON.stringify(selector)}).getAttribute('data-pirc-script-id')`,
      ),
    port = id('#port'),
    root = id('html');
  let generation = 0;
  const packet = (overrides = {}) => ({
    revision: invoke('snapshot', {}).layout.revision,
    generation: ++generation,
    scrollActionThrough: 0,
    viewport: {
      ...row.viewport,
      scrollX: 0,
      scrollY: 0,
      scrollBehavior: row.result.css.root,
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
            computedStyle: { 'scroll-behavior': row.result.css.element },
            scroll: {
              left: 0,
              top: 0,
              width: 600,
              height: 800,
              range: { minLeft: 0, maxLeft: 420, minTop: 0, maxTop: 700 },
            },
          }
        : id === root
          ? {
              id,
              kind: 'box',
              x: 0,
              y: 0,
              width: row.viewport.width,
              height: 2200,
              computedStyle: { 'scroll-behavior': row.result.css.root },
            }
          : { id, kind: 'none' },
    ),
    ...overrides,
  });
  invoke('updateLayout', packet());
  return { run, invoke, packet };
}
test('224 independent CSS scroll-behavior profiles preserve original browser sources', () => {
  assert.equal(f.browserVersion, '153.0.8010.12');
  assert.equal(f.cases.length, 224);
  assert.equal(scrollBehaviorModes.length, 14);
  assert.equal(
    new Set(f.cases.map((r) => [r.mode, r.target, r.viewport.width, r.dpr, r.theme].join('/')))
      .size,
    224,
  );
  for (const r of f.cases) {
    assert.equal(r.html, scrollBehaviorHTML(r.mode));
    assert.equal(r.driverSource, buildScrollBehaviorDriver(r.mode, r.target));
  }
});
test('shipped auto/instant defaults and setters preserve native-measured current positions against Chromium', () => {
  for (const row of f.cases) {
    const { run, invoke } = runtime(row);
    const actor =
      row.target === 'root'
        ? row.mode === 'alias'
          ? 'document.documentElement'
          : 'window'
        : 'document.getElementById("port")';
    const call =
      row.mode === 'setter'
        ? `${row.target === 'root' ? 'document.documentElement' : 'document.getElementById("port")'}.scrollTop=180`
        : row.mode === 'numeric'
          ? `${actor}.scrollTo(0,180)`
          : `${actor}.scrollTo({top:180${row.mode === 'instant' ? ',behavior:"instant"' : row.mode === 'auto' ? ',behavior:"auto"' : ''}})`;
    run(call);
    assert.deepEqual(
      JSON.parse(
        run(
          'JSON.stringify({root:{left:scrollX,top:scrollY},element:{left:document.getElementById("port").scrollLeft,top:document.getElementById("port").scrollTop}})',
        ),
      ),
      row.result.immediate,
      `${row.mode}/${row.target}`,
    );
    const action = invoke('snapshot', {}).scrollActions[0];
    assert.ok(action);
    if (row.mode !== 'instant')
      assert.equal(
        action.resolvedBehavior,
        row.result.css[row.target] === 'smooth' ? 'smooth' : 'instant',
      );
  }
});
test('queued behavior stays fixed when later CSS changes and dirty defaults withhold synchronous feedback', () => {
  const row = f.cases.find((r) => r.mode === 'css-auto' && r.target === 'root'),
    a = runtime(row);
  a.run('window.scrollTo({top:180});document.documentElement.classList.add("changed")');
  assert.equal(a.invoke('snapshot', {}).scrollActions[0].resolvedBehavior, 'instant');
  const b = runtime(row);
  b.run('document.documentElement.classList.add("changed");window.scrollTo({top:180})');
  assert.equal(b.invoke('snapshot', {}).scrollActions[0].resolvedBehavior, undefined);
  assert.throws(
    // Node VM may swallow global accessor errors; verify the exact getter directly.
    () => b.run('Object.getOwnPropertyDescriptor(window,"scrollY").get.call(window)'),
    (e) => e.name === 'NotSupportedError',
  );
});
test('invalid native scroll behavior metadata is rejected atomically', () => {
  const { invoke, packet } = runtime(f.cases[0]);
  for (const invalid of ['instant', 'SMOOTH', null, 1]) {
    const p = packet();
    p.viewport.scrollBehavior = invalid;
    assert.throws(() => invoke('updateLayout', p), /scrollBehavior/);
  }
});
