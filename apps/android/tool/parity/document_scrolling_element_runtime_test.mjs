import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import {
  scrollingElementCases,
  scrollingElementHTML,
  buildScrollingElementDriver,
} from './document_scrolling_element_fixture.mjs';
const fixture = JSON.parse(
  readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-scrolling-element-chromium153.json', import.meta.url)),
);
const bundle = readFileSync(
  process.env.PIRC_DOCUMENT_SCRIPT_RUNTIME_BUNDLE ||
    fileURLToPath(new URL('../../assets/document-script-runtime.js', import.meta.url)),
  'utf8',
);
function runtime(row = fixture.cases[0], mode) {
  const c = vm.createContext({}, { microtaskMode: 'afterEvaluate' }),
    run = (s) => new vm.Script(s).runInContext(c);
  run(bundle);
  const invoke = (name, args) => JSON.parse(run(`__pircDocument.${name}(${JSON.stringify(args)})`));
  const documentMode =
    mode ??
    (row.mode === 'legacy-limited'
      ? 'limited quirks'
      : row.result.immediate.compatMode === 'BackCompat'
        ? 'quirks'
        : 'no quirks');
  const initial = invoke('init', {
    hostLayout: true,
    documentMode,
    url: 'https://example.test/scrolling-element',
    html: row.html,
  });
  const id = (tag) => run(`document.querySelector('${tag}').getAttribute('data-pirc-script-id')`),
    root = id('html'),
    body = id('body');
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
      id === root || id === body
        ? {
            id,
            kind: 'box',
            x: 0,
            y: 0,
            width: row.viewport.width,
            height: 2200,
            computedStyle: row.computed[id === root ? 'root' : 'body'],
            scroll: {
              left: 0,
              top: 0,
              width: row.viewport.width,
              height: 2200,
              range: { minLeft: 0, maxLeft: 0, minTop: 0, maxTop: 0 },
            },
          }
        : { id, kind: 'none' },
    ),
    ...overrides,
  });
  invoke('updateLayout', packet());
  return { run, invoke, packet, root, body };
}
test('88 Chromium owner and mode profiles freeze the exact shared sources', () => {
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(fixture.cases.length, 88);
  assert.equal(
    new Set(fixture.cases.map((r) => [r.mode, r.viewport.width, r.dpr, r.theme].join('/'))).size,
    88,
  );
  for (const r of fixture.cases) {
    assert.equal(r.html, scrollingElementHTML(r.mode));
    assert.equal(r.driverSource, buildScrollingElementDriver());
  }
  assert.equal(scrollingElementCases.length, 11);
});
test('shipped scrollingElement, compatMode, metrics and synchronous methods match all 88 browser profiles', () => {
  for (const row of fixture.cases) {
    const { run, invoke } = runtime(row);
    run(row.driverSource);
    run('document.getElementById("run").click()');
    assert.deepEqual(
      JSON.parse(run('JSON.stringify(window.scrollingElementTrace)')),
      row.result.trace,
      row.mode,
    );
    assert.deepEqual(
      JSON.parse(run('JSON.stringify(window.scrollingElementImmediate)')),
      row.result.immediate,
      row.mode,
    );
    assert.deepEqual(
      invoke('snapshot', {}).diagnostics.filter((d) => d.severity !== 'info'),
      [],
      row.mode,
    );
  }
});
test('initial parser mode ignores guest masking of the doctype property', () => {
  const modern = runtime();
  modern.run('Object.defineProperty(document,"doctype",{value:null,configurable:true})');
  assert.equal(modern.run('document.compatMode'), 'CSS1Compat');
  assert.equal(modern.run('document.scrollingElement===document.documentElement'), true);
  const quirks = runtime(fixture.cases.find((r) => r.mode === 'quirks-default'));
  quirks.run(
    'Object.defineProperty(document,"doctype",{value:new DOMParser().parseFromString("<!doctype html><html><body></body></html>","text/html").doctype,configurable:true})',
  );
  assert.equal(quirks.run('document.compatMode'), 'BackCompat');
});
test('ownership uses current native style, rejects stale/missing proof, and changes after a fresh packet', () => {
  const row = fixture.cases.find((r) => r.mode === 'quirks-body-auto'),
    r = runtime(row);
  assert.equal(r.run('document.scrollingElement===document.body'), true);
  r.run('document.documentElement.style.overflow="hidden"');
  assert.throws(
    () => r.run('document.scrollingElement'),
    (e) => e.name === 'NotSupportedError',
  );
  const descriptor = r.invoke('snapshot', {}).layout;
  const p = r.packet({ revision: descriptor.revision });
  p.boxes.find((b) => b.id === r.root).computedStyle = {
    'overflow-x': 'hidden',
    'overflow-y': 'hidden',
  };
  r.invoke('updateLayout', p);
  assert.equal(r.run('document.scrollingElement'), null);
  const missing = r.packet({ revision: descriptor.revision });
  delete missing.boxes.find((b) => b.id === r.root).computedStyle;
  r.invoke('updateLayout', missing);
  assert.throws(
    () => r.run('document.scrollingElement'),
    (e) => e.name === 'NotSupportedError',
  );
});
test('quirks html positions stay zero and root scroll setters are ignored', () => {
  const { run, invoke } = runtime(fixture.cases.find((r) => r.mode === 'quirks-default'));
  run('document.documentElement.scrollTop=50;document.documentElement.scrollLeft=20');
  assert.equal(run('document.documentElement.scrollTop'), 0);
  assert.equal(run('document.documentElement.scrollLeft'), 0);
  assert.deepEqual(invoke('snapshot', {}).scrollActions, []);
});
test('scrollingElement handles a missing body, a confirmed no-box body and a rootless document', () => {
  const r = runtime(fixture.cases.find((r) => r.mode === 'quirks-default'));
  const p = r.packet();
  p.boxes.find((b) => b.id === r.body).kind = 'none';
  delete p.boxes.find((b) => b.id === r.body).scroll;
  r.invoke('updateLayout', p);
  assert.equal(r.run('document.scrollingElement===document.body'), true);
  r.run('document.body.remove()');
  assert.equal(r.run('document.scrollingElement'), null);
  const modern = runtime();
  modern.run('document.documentElement.remove()');
  assert.equal(modern.run('document.scrollingElement'), null);
});
test('active document accessors are read-only and reject invalid native mode metadata', () => {
  const r = runtime();
  assert.throws(
    () => r.run('"use strict";document.scrollingElement=null'),
    (e) => e.name === 'TypeError',
  );
  assert.throws(
    () => r.run('"use strict";document.compatMode="BackCompat"'),
    (e) => e.name === 'TypeError',
  );
  const c = vm.createContext({}, { microtaskMode: 'afterEvaluate' });
  new vm.Script(bundle).runInContext(c);
  const result = JSON.parse(
    new vm.Script(
      `__pircDocument.init(${JSON.stringify({ hostLayout: true, documentMode: 'invented', html: fixture.cases[0].html })})`,
    ).runInContext(c),
  );
  assert.ok(
    result.diagnostics.some((d) => d.code === 'runtime.init_error' && d.severity === 'error'),
  );
});
