import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import nativeVm from 'node:vm';
import { createDocumentScriptHostVm } from './document_script_host_test_helper.mjs';
import {
  lateFragmentHTML,
  lateFragmentResource,
  lateFragmentModes,
  heldLateFragmentModes,
} from './document_late_fragment_fixture.mjs';
const vm = createDocumentScriptHostVm(nativeVm),
  bundle = readFileSync(
    new URL('../../assets/document-script-runtime.js', import.meta.url),
    'utf8',
  );
test('initial fragment readiness follows parser/defer/module and retains the DCL-selected node', async () => {
  for (const mode of lateFragmentModes) {
    const context = vm.createContext({}),
      run = (source) => new vm.Script(source).runInContext(context, { timeout: 3000 });
    run(bundle);
    const call = (name, input) =>
      JSON.parse(run(`__pircDocument.${name}(${JSON.stringify(input)})`));
    const initial = call('init', {
      url: 'https://gateway.example/late-fragment?mode=' + mode + '#target',
      html: lateFragmentHTML(mode),
    });
    assert.deepEqual(
      initial.diagnostics.filter((x) => x.severity === 'error'),
      [],
      mode,
    );
    for (const request of initial.resourceRequests.filter((r) => r.kind === 'stylesheet')) {
      call('completeResource', { id: request.id, ok: true });
    }
    if (heldLateFragmentModes.has(mode)) {
      assert.equal(initial.fragmentTargetReady, mode === 'async', mode);
      const resource = initial.resourceRequests.find((r) => r.kind === 'script');
      assert.ok(resource, mode);
      let loaded = call('completeResource', {
        id: resource.id,
        ok: true,
        url: 'https://gateway.example/late.js',
        source: lateFragmentResource(),
      });
      for (let turn = 0; !loaded.fragmentTargetReady && turn < 20; turn++) {
        await new Promise((resolve) => setImmediate(resolve));
        loaded = call('snapshot', {});
      }
      assert.equal(loaded.fragmentTargetReady, true, mode);
    } else assert.equal(initial.fragmentTargetReady, true, mode);
    assert.equal(
      run("document.querySelector(':target')?.dataset.key||null"),
      ['async', 'load'].includes(mode) ? null : 'target',
      mode,
    );
    if (mode === 'load-rename')
      assert.equal(run("document.querySelector(':target').id"), 'renamed');
    if (mode === 'load-duplicate')
      assert.equal(run("document.getElementById('target').dataset.key"), 'duplicate');
  }
});
test('late fragment browser corpus covers all environments with identical page/resource sources', () => {
  const fixture = JSON.parse(
    readFileSync(
      new URL('../../../../packages/pirc_render/test/fixtures/parity/document-late-fragment-chromium153.json', import.meta.url),
      'utf8',
    ),
  );
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(fixture.cases.length, 88);
  const seen = new Set();
  for (const row of fixture.cases) {
    const key = JSON.stringify([row.mode, row.viewport, row.dpr, row.theme]);
    assert.ok(!seen.has(key));
    seen.add(key);
    assert.equal(row.html, lateFragmentHTML(row.mode));
    assert.equal(row.resource, lateFragmentResource());
    assert.equal(row.viewport.height, row.screen.height - 48);
    for (const phase of ['loaded', 'shifted']) {
      assert.equal(row.result[phase].ready, 'complete');
      assert.equal(
        row.result[phase].target,
        ['load', 'async'].includes(row.mode) ? null : 'target',
      );
    }
    if (row.mode === 'parser-scroll') assert.equal(row.result.before.top, 240);
  }
});
