import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import nativeVm from 'node:vm';
import test from 'node:test';
import { createDocumentScriptHostVm } from './document_script_host_test_helper.mjs';
import {
  dialogShowHTML,
  dialogShowCases,
  runDialogShowCase,
  readDialogShowState,
} from './document_dialog_show_fixture.mjs';
const vm = createDocumentScriptHostVm(nativeVm),
  bundle = readFileSync(
    new URL('../../assets/document-script-runtime.js', import.meta.url),
    'utf8',
  );
const fixture = JSON.parse(
  readFileSync(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-dialog-show-chromium153.json', import.meta.url),
    'utf8',
  ),
);
function invoke(c, m, args = {}) {
  return JSON.parse(
    vm.runInContext(`__pircDocument.${m}(${JSON.stringify(args)})`, c, { timeout: 3000 }),
  );
}
function read(c) {
  return JSON.parse(vm.runInContext(`JSON.stringify(${readDialogShowState})`, c));
}
assert.equal(fixture.html, dialogShowHTML);
assert.deepEqual(fixture.cases, dialogShowCases);
assert.equal(fixture.browserVersion, '153.0.8010.12');
assert.equal(fixture.states.length, dialogShowCases.length);
assert.equal(fixture.profiles.length, 8);
assert.equal(
  new Set(fixture.profiles.map((p) => JSON.stringify([p.viewport, p.dpr, p.theme]))).size,
  8,
);
for (const p of fixture.profiles)
  assert.deepEqual(
    p.steps.map((s) => s.name),
    ['initial', 'open', 'saved', 'reopen', 'outside', 'close-outside', 'empty', 'close-empty'],
  );
for (const [i, row] of dialogShowCases.entries())
  test(`dialog.show matches Chromium: ${row.name}`, () => {
    assert.equal(fixture.states[i].name, row.name);
    const c = vm.createContext({});
    vm.runInContext(bundle, c, { timeout: 3000 });
    invoke(c, 'init', { html: dialogShowHTML, url: 'https://dialog-show.example/test' });
    vm.runInContext(runDialogShowCase(row), c, { timeout: 3000 });
    assert.deepEqual(read(c), fixture.states[i].synchronous, 'synchronous focus/events');
    for (let now = 1; now <= 128; now++) {
      const state = invoke(c, 'snapshot');
      assert.deepEqual(
        state.formActions.filter((a) => a.kind === 'submit'),
        [],
      );
      assert.ok(
        !state.diagnostics.some((d) => d.severity === 'error'),
        JSON.stringify(state.diagnostics),
      );
      if (state.scheduler.timerDelayMs === null) break;
      invoke(c, 'pump', { now });
      assert.ok(now < 128, 'timers settle');
    }
    assert.deepEqual(read(c), fixture.states[i].result, 'settled focus/events');
  });

test('dialog.show uses a branded receiver and returns undefined', () => {
  const c = vm.createContext({});
  vm.runInContext(bundle, c, { timeout: 3000 });
  invoke(c, 'init', { html: dialogShowHTML });
  assert.throws(
    () => vm.runInContext('HTMLDialogElement.prototype.show.call(document.body)', c),
    /Illegal invocation/,
  );
  assert.equal(vm.runInContext('document.getElementById("dialog").show()', c), undefined);
  assert.equal(vm.runInContext('document.getElementById("dialog").show()', c), undefined);
  assert.equal(vm.runInContext('typeof HTMLDialogElement.prototype.showModal', c), 'function');
});
