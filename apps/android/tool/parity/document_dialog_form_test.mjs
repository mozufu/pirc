import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import nativeVm from 'node:vm';
import test from 'node:test';
import { createDocumentScriptHostVm } from './document_script_host_test_helper.mjs';
import {
  dialogFormHTML,
  dialogFormActions,
  readDialogFormState,
} from './document_dialog_form_fixture.mjs';
const vm = createDocumentScriptHostVm(nativeVm),
  bundle = readFileSync(
    new URL('../../assets/document-script-runtime.js', import.meta.url),
    'utf8',
  );
const fixture = JSON.parse(
  readFileSync(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-dialog-form-chromium153.json', import.meta.url),
    'utf8',
  ),
);
function invoke(c, m, input = {}) {
  return JSON.parse(
    vm.runInContext(`__pircDocument.${m}(${JSON.stringify(input)})`, c, { timeout: 3000 }),
  );
}
function drain(c) {
  for (let now = 0; now < 128; now++) {
    const result = invoke(c, 'snapshot');
    assert.deepEqual(
      result.formActions.filter((action) => action.kind === 'submit'),
      [],
      'dialog submission must not construct a navigation or FormData',
    );
    assert.equal(
      result.diagnostics.some((d) => d.severity === 'error'),
      false,
      JSON.stringify(result.diagnostics),
    );
    if (result.scheduler.timerDelayMs === null) return;
    invoke(c, 'pump', { now: now + 1 });
  }
  throw Error('Dialog events did not settle');
}
test('dialog form closing matches independent Chromium values and events', () => {
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(fixture.html, dialogFormHTML);
  assert.deepEqual(fixture.actions, dialogFormActions);
  assert.equal(fixture.cases.length, 8);
  assert.equal(
    new Set(fixture.cases.map((row) => JSON.stringify([row.viewport, row.dpr, row.theme]))).size,
    8,
  );
  for (const row of fixture.cases)
    assert.deepEqual(
      row.steps.map((step) => step.name),
      ['initial', 'open', 'accepted', 'invalid', 'skip', 'external'],
    );
  const c = vm.createContext({});
  vm.runInContext(bundle, c, { timeout: 3000 });
  invoke(c, 'init', { html: dialogFormHTML, url: 'https://dialog.example/test' });
  for (const [i, action] of dialogFormActions.entries()) {
    if (action.script) vm.runInContext(`(()=>{${action.script}})()`, c, { timeout: 3000 });
    drain(c);
    const actual = JSON.parse(vm.runInContext(`JSON.stringify(${readDialogFormState})`, c));
    assert.deepEqual(actual, fixture.states[i].result, action.name);
  }
});
test('dialog constructor, return-value conversion and explicit display limits', () => {
  const c = vm.createContext({});
  vm.runInContext(bundle, c, { timeout: 3000 });
  invoke(c, 'init', { html: '<dialog id="d"></dialog>', url: 'https://dialog.example/test' });
  assert.equal(
    vm.runInContext('document.createElement("dialog") instanceof HTMLDialogElement', c),
    true,
  );
  assert.throws(() => vm.runInContext('new HTMLDialogElement()', c), /Illegal constructor/);
  assert.throws(() => vm.runInContext('new HTMLDialogElement(document)', c), /Illegal constructor/);
  assert.throws(() => vm.runInContext('document.getElementById("d").close(Symbol())', c), /Symbol/);
  assert.throws(
    () => vm.runInContext('document.getElementById("d").returnValue=Symbol()', c),
    /Symbol/,
  );
  assert.equal(vm.runInContext('document.getElementById("d").open', c), false);
  assert.equal(vm.runInContext('typeof document.getElementById("d").showModal', c), 'function');
  assert.equal(vm.runInContext('typeof document.getElementById("d").show', c), 'function');
  assert.equal(vm.runInContext('window.HTMLDialogElement === HTMLDialogElement', c), true);
});

test('submitter dialog override skips FormData and bypasses authored close methods', () => {
  const c = vm.createContext({});
  vm.runInContext(bundle, c, { timeout: 3000 });
  invoke(c, 'init', {
    html: '<dialog open id="d"><form method="post" action="/upload" id="f"><input name="secret" dirname="direction" value="ready"><button id="b" formmethod="dialog" value="save">Save</button></form></dialog>',
    url: 'https://dialog.example/test',
  });
  vm.runInContext(
    `window.calls=0;document.getElementById('f').addEventListener('formdata',()=>calls++);document.getElementById('d').close=()=>{throw Error('authored close must not run')};HTMLDialogElement.prototype.close=()=>{throw Error('prototype close must not run')};document.getElementById('f').requestSubmit(document.getElementById('b'))`,
    c,
  );
  drain(c);
  assert.deepEqual(
    JSON.parse(
      vm.runInContext(
        `JSON.stringify([document.getElementById('d').open,document.getElementById('d').returnValue,calls])`,
        c,
      ),
    ),
    [false, 'save', 0],
  );
});
test('cloned dialog keeps attributes and independent return state', () => {
  const c = vm.createContext({});
  vm.runInContext(bundle, c, { timeout: 3000 });
  invoke(c, 'init', { html: '<dialog open id="d"></dialog>', url: 'https://dialog.example/test' });
  assert.deepEqual(
    JSON.parse(
      vm.runInContext(
        `JSON.stringify((()=>{const d=document.getElementById('d');d.returnValue='original';const copy=d.cloneNode(true);return [copy instanceof HTMLDialogElement,copy.open,copy.returnValue,d.returnValue]})())`,
        c,
      ),
    ),
    [true, true, '', 'original'],
  );
});
