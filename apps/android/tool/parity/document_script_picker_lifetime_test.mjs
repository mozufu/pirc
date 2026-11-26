import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import nativeVm from 'node:vm';
import { createDocumentScriptHostVm } from './document_script_host_test_helper.mjs';
import {
  scriptPickerLifetimeHTML,
  pickedFiles,
  readScriptPickerState,
} from './document_script_picker_lifetime_fixture.mjs';
const vm = createDocumentScriptHostVm(nativeVm);
const bundle = readFileSync(
  process.env.PIRC_DOCUMENT_SCRIPT_RUNTIME_BUNDLE ||
    new URL('../../assets/document-script-runtime.js', import.meta.url),
  'utf8',
);
const fixture = JSON.parse(
  readFileSync(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-script-picker-lifetime-chromium153.json', import.meta.url),
    'utf8',
  ),
);
function invoke(c, method, arg = {}) {
  return JSON.parse(
    vm.runInContext('__pircDocument.' + method + '(' + JSON.stringify(arg) + ')', c, {
      timeout: 3000,
    }),
  );
}
async function read(c) {
  return JSON.parse(
    JSON.stringify(
      await vm.runInContext('(' + readScriptPickerState.toString() + ')()', c, { timeout: 3000 }),
    ),
  );
}
test('script chooser lifetime reference source and all environments are intact', () => {
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(fixture.html, scriptPickerLifetimeHTML);
  assert.deepEqual(fixture.pickedFiles, pickedFiles);
  assert.equal(fixture.cases.length, 8);
  assert.equal(
    new Set(fixture.cases.map((r) => JSON.stringify([r.viewport, r.dpr, r.theme]))).size,
    8,
  );
  for (const row of fixture.cases) {
    assert.deepEqual(row.hidden, row.resumed);
    assert.deepEqual(row.resumed.files, pickedFiles);
    assert.deepEqual(row.resumed.events, [
      { type: 'input', trusted: true },
      { type: 'change', trusted: true },
    ]);
    assert.deepEqual(row.fresh, row.initial);
  }
});
for (const row of fixture.cases)
  test(`script chooser DOM lifecycle ${row.viewport.width} ${row.theme} dpr${row.dpr}`, async () => {
    const c = vm.createContext({});
    vm.runInContext(bundle, c, { timeout: 3000 });
    invoke(c, 'init', {
      html: scriptPickerLifetimeHTML,
      url: 'https://picker.example/lifetime',
      environment: {
        width: row.viewport.width,
        height: row.viewport.height,
        devicePixelRatio: row.dpr,
        colorScheme: row.theme,
      },
    });
    assert.deepEqual(await read(c), row.initial);
    const id = vm.runInContext(
      'document.getElementById("choose").getAttribute("data-pirc-script-id")',
      c,
    );
    const action = invoke(c, 'dispatch', { id, type: 'click', now: 1 }).filePickerActions[0];
    assert.ok(action);
    invoke(c, 'updateVisibility', { hidden: true, now: 2 });
    invoke(c, 'filePickerResult', {
      id: action.id,
      files: pickedFiles.map((f) => ({
        name: f.name,
        type: f.type,
        size: f.bytes.length,
        lastModified: 1,
        bytesBase64: Buffer.from(f.bytes).toString('base64'),
      })),
    });
    assert.deepEqual(await read(c), row.hidden);
    invoke(c, 'updateVisibility', { hidden: false, now: 3 });
    assert.deepEqual(await read(c), row.resumed);
    // Duplicate native completion cannot dispatch the events a second time.
    invoke(c, 'filePickerResult', { id: action.id, cancelled: true });
    assert.deepEqual(await read(c), row.resumed);
    vm.runInContext('document.getElementById("form").reset()', c);
    assert.deepEqual(await read(c), row.reset);
  });
