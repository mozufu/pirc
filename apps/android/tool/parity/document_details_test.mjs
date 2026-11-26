import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import nativeVm from 'node:vm';
import test from 'node:test';
import { createDocumentScriptHostVm } from './document_script_host_test_helper.mjs';
import { detailsHTML, detailsActions, readDetailsState } from './document_details_fixture.mjs';
const vm = createDocumentScriptHostVm(nativeVm);
const bundle = readFileSync(
  new URL('../../assets/document-script-runtime.js', import.meta.url),
  'utf8',
);
const fixture = JSON.parse(
  readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-details-chromium153.json', import.meta.url), 'utf8'),
);
function invoke(context, method, input = {}) {
  return JSON.parse(
    vm.runInContext(`__pircDocument.${method}(${JSON.stringify(input)})`, context, {
      timeout: 3000,
    }),
  );
}
const clocks = new WeakMap();
function drain(context) {
  for (let i = 0; i < 32; i++) {
    const r = invoke(context, 'snapshot');
    assert.equal(
      r.diagnostics.some((x) => x.severity === 'error'),
      false,
      JSON.stringify(r.diagnostics),
    );
    if (r.scheduler.timerDelayMs === null) return r;
    const now = (clocks.get(context) || 0) + Math.max(1, r.scheduler.timerDelayMs);
    clocks.set(context, now);
    invoke(context, 'pump', { now });
  }
  throw Error('Details tasks did not settle');
}
test('details IDL, exclusive groups and toggle tasks match independent Chromium states', () => {
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(fixture.html, detailsHTML);
  assert.deepEqual(fixture.actions, detailsActions);
  const context = vm.createContext({});
  vm.runInContext(bundle, context, { timeout: 3000 });
  invoke(context, 'init', { html: detailsHTML, url: 'https://details.example/test' });
  for (const [i, action] of detailsActions.entries()) {
    if (action.script) vm.runInContext(`(()=>{${action.script}})()`, context, { timeout: 3000 });
    drain(context);
    const result = JSON.parse(vm.runInContext(`JSON.stringify(${readDetailsState})`, context));
    assert.deepEqual(result, fixture.states[i].result, action.name);
  }
});
