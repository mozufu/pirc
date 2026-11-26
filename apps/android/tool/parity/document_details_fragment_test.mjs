import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import nativeVm from 'node:vm';
import test from 'node:test';
import { createDocumentScriptHostVm } from './document_script_host_test_helper.mjs';
import { detailsFragmentCases, detailsFragmentHTML } from './document_details_fragment_fixture.mjs';
const vm = createDocumentScriptHostVm(nativeVm);
const bundle = readFileSync(
  process.env.PIRC_DOCUMENT_SCRIPT_RUNTIME_BUNDLE ||
    new URL('../../assets/document-script-runtime.js', import.meta.url),
  'utf8',
);
const fixture = JSON.parse(
  readFileSync(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-details-fragment-chromium153.json', import.meta.url),
    'utf8',
  ),
);
const read = `JSON.stringify({open:Object.fromEntries(['peer','outer','inner'].map(id=>[id,document.getElementById(id).open])),target:document.querySelector(':target')?.id||null,toggles:window.toggles.splice(0)})`;
function call(c, m, a = {}) {
  return JSON.parse(
    vm.runInContext(`__pircDocument.${m}(${JSON.stringify(a)})`, c, { timeout: 3000 }),
  );
}
function evaluate(c, s) {
  return vm.runInContext(s, c, { timeout: 3000 });
}
function drain(c) {
  let now = 0;
  for (let i = 0; i < 40; i++) {
    const r = call(c, 'snapshot');
    assert.equal(
      r.diagnostics.some((d) => d.severity === 'error'),
      false,
      JSON.stringify(r.diagnostics),
    );
    if (r.scheduler.timerDelayMs === null) return r;
    now += Math.max(1, r.scheduler.timerDelayMs);
    call(c, 'pump', { now });
  }
  throw Error('Unsettled fragment runtime');
}
test('details fragment corpus retains all native geometry and environment profiles', () => {
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(fixture.cases.length, 96);
  const keys = new Set();
  for (const row of fixture.cases) {
    assert.deepEqual(
      row.spec,
      detailsFragmentCases.find((c) => c.id === row.spec.id),
    );
    assert.equal(row.html, detailsFragmentHTML(row.spec, { scripted: true }));
    const key = JSON.stringify([row.spec.id, row.initial, row.screen.width, row.dpr, row.theme]);
    assert.ok(!keys.has(key));
    keys.add(key);
    assert.equal(row.states.length, row.initial ? 4 : 5);
  }
});
for (const row of fixture.cases.filter(
  (c) => c.screen.width === 390 && c.dpr === 1 && c.theme === 'light',
)) {
  test(`runtime reveals details for ${row.spec.id} initial=${row.initial}`, () => {
    const c = vm.createContext({});
    evaluate(c, bundle);
    const url = 'https://details-fragment.example/test',
      fragment = '#' + row.spec.target;
    call(c, 'init', {
      html: row.html,
      url: url + (row.initial ? fragment : ''),
      history: { entryKey: 'initial', index: 0, length: 1, ackRevision: 0, targetRevision: 0 },
    });
    let states = [...row.states],
      revision = 0,
      key = 'initial',
      index = 0,
      length = 1;
    function compare() {
      drain(c);
      const state = states.shift();
      assert.ok(state);
      const actual = JSON.parse(evaluate(c, read));
      assert.deepEqual(
        actual,
        { open: state.result.open, target: state.result.target, toggles: state.result.toggles },
        state.name,
      );
    }
    function navigate() {
      const jump = evaluate(
        c,
        `document.getElementById('jump').getAttribute('data-pirc-script-id')`,
      );
      call(c, 'dispatch', { id: jump, type: 'click' });
      if (!row.initial && revision === 0) {
        key = 'fragment';
        index = 1;
        length = 2;
      }
      call(c, 'updateHistory', {
        entryKey: key,
        index,
        length,
        url: url + fragment,
        ackRevision: 0,
        targetRevision: ++revision,
        targetUrl: url + fragment,
        changeKind: 'fragment',
      });
    }
    compare();
    if (!row.initial) {
      navigate();
      compare();
    }
    evaluate(
      c,
      `document.getElementById('outer').open=false;document.getElementById('outerSummary').focus({preventScroll:true})`,
    );
    compare();
    navigate();
    compare();
    evaluate(
      c,
      `document.getElementById('outer').open=false;document.getElementById('outerSummary').focus({preventScroll:true})`,
    );
    drain(c);
    evaluate(c, `history.pushState({},'', '#other-route')`);
    drain(c);
    assert.equal(
      evaluate(c, `document.getElementById('outer').open`),
      false,
      'pushState must not reveal details',
    );
    call(c, 'updateHistory', {
      entryKey: key,
      index,
      length: length + 1,
      url: url + fragment,
      ackRevision: 1,
      targetRevision: ++revision,
      targetUrl: url + fragment,
      changeKind: 'traverse',
    });
    compare();
    assert.equal(states.length, 0);
  });
}
