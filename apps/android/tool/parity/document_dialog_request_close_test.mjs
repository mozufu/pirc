import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import nativeVm from 'node:vm';
import test from 'node:test';
import { createDocumentScriptHostVm } from './document_script_host_test_helper.mjs';
import {
  dialogRequestHTML,
  dialogRequestCases,
  runDialogRequestCase,
  readDialogRequestState,
} from './document_dialog_request_close_fixture.mjs';
const vm = createDocumentScriptHostVm(nativeVm),
  bundle = readFileSync(
    new URL('../../assets/document-script-runtime.js', import.meta.url),
    'utf8',
  );
const fixture = JSON.parse(
  readFileSync(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-dialog-request-close-chromium153.json', import.meta.url),
    'utf8',
  ),
);
function invoke(c, m, args = {}) {
  return JSON.parse(
    vm.runInContext(`__pircDocument.${m}(${JSON.stringify(args)})`, c, { timeout: 3000 }),
  );
}
function read(c) {
  return JSON.parse(vm.runInContext(`JSON.stringify(${readDialogRequestState})`, c));
}
function context() {
  const c = vm.createContext({});
  vm.runInContext(bundle, c, { timeout: 3000 });
  invoke(c, 'init', { html: dialogRequestHTML, url: 'https://dialog-request.example/test' });
  return c;
}
assert.equal(fixture.browserVersion, '153.0.8010.12');
assert.equal(fixture.html, dialogRequestHTML);
assert.deepEqual(fixture.cases, dialogRequestCases);
assert.equal(fixture.states.length, dialogRequestCases.length);
assert.equal(fixture.profiles.length, 8);
assert.equal(
  new Set(fixture.profiles.map((p) => JSON.stringify([p.viewport, p.dpr, p.theme]))).size,
  8,
);
for (const p of fixture.profiles)
  assert.deepEqual(
    p.steps.map((s) => s.name),
    ['initial', 'open', 'blocked', 'allowed', 'closed', 'reopen', 'forced'],
  );
for (const [i, row] of dialogRequestCases.entries())
  test(`dialog close request matches Chromium: ${row.name}`, () => {
    assert.equal(fixture.states[i].name, row.name);
    const c = context();
    vm.runInContext(runDialogRequestCase(row), c, { timeout: 3000 });
    assert.deepEqual(read(c), fixture.states[i].synchronous, 'synchronous result/events/focus');
    for (let now = 1; now <= 128; now++) {
      const result = invoke(c, 'snapshot');
      assert.deepEqual(result.formActions, [], 'dialog requests never navigate or submit');
      assert.deepEqual(result.navigationActions, []);
      assert.ok(
        !result.diagnostics.some((d) => d.severity === 'error'),
        JSON.stringify(result.diagnostics),
      );
      if (result.scheduler.timerDelayMs === null) break;
      invoke(c, 'pump', { now });
      assert.ok(now < 128, 'timers settle');
    }
    assert.deepEqual(read(c), fixture.states[i].result, 'settled result/events/focus');
  });
test('requestClose receiver, return, conversions and handler slot getter', () => {
  const c = context();
  assert.throws(
    () => vm.runInContext('HTMLDialogElement.prototype.requestClose.call(document.body)', c),
    /Illegal invocation/,
  );
  assert.equal(vm.runInContext('document.getElementById("dialog").requestClose()', c), undefined);
  assert.equal(
    vm.runInContext(
      '(()=>{const d=document.getElementById("dialog"),f=()=>false;d.oncancel=f;return d.oncancel===f})()',
      c,
    ),
    true,
  );
  assert.equal(
    vm.runInContext(
      '(()=>{const d=document.getElementById("dialog");d.setAttribute("oncancel","return false");return typeof d.oncancel})()',
      c,
    ),
    'function',
  );
});
