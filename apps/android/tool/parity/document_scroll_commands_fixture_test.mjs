import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import {
  scrollCommandModes,
  scrollCommandsHTML,
  buildScrollCommandDriver,
} from './document_scroll_commands_fixture.mjs';
const fixture = JSON.parse(
  readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-scroll-commands-chromium153.json', import.meta.url)),
);
test('scroll command source and all 160 browser profiles are frozen independently of Flutter', () => {
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(fixture.html, scrollCommandsHTML);
  assert.equal(fixture.cases.length, 160);
  for (const row of fixture.cases) {
    assert.deepEqual(row.commands, scrollCommandModes[row.mode]);
    assert.equal(row.driverSource, buildScrollCommandDriver(row.mode, row.target));
  }
  assert.equal(
    new Set(
      fixture.cases.map((c) => [c.mode, c.target, c.viewport.width, c.dpr, c.theme].join('/')),
    ).size,
    160,
  );
});
test('Chromium distinguishes current pixels from an animation destination and cancels no-op vectors', () => {
  for (const row of fixture.cases) {
    const result = row.result,
      at = result.immediate[row.target],
      end = result.settled[row.target];
    if (row.mode === 'instant-smooth') {
      assert.equal(at.top, 100);
      assert.equal(end.top, 180);
    }
    if (row.mode === 'smooth-instant-by') {
      assert.equal(at.top, 20);
      assert.equal(end.top, 20);
    }
    if (row.mode === 'smooth-smooth-by') {
      assert.equal(at.top, 0);
      assert.equal(end.top, 20);
    }
    if (
      ['smooth-same-position', 'smooth-other-axis', 'smooth-zero-by', 'smooth-empty-to'].includes(
        row.mode,
      )
    ) {
      assert.equal(at.top, 0);
      assert.equal(end.top, 0);
    }
  }
});
test('shipped JS forwards every command including cancellation-only calls', () => {
  const bundle = readFileSync(
    new URL('../../assets/document-script-runtime.js', import.meta.url),
    'utf8',
  );
  for (const target of ['root', 'element'])
    for (const [mode, commands] of Object.entries(scrollCommandModes)) {
      const c = vm.createContext({}, { microtaskMode: 'afterEvaluate' });
      const run = (s) => new vm.Script(s).runInContext(c);
      run(bundle);
      const invoke = (method, args) =>
        JSON.parse(run(`__pircDocument.${method}(${JSON.stringify(args)})`));
      const initial = invoke('init', {
        hostLayout: true,
        url: 'https://example.test/commands',
        html: scrollCommandsHTML,
      });
      const elementId = run('document.getElementById("port").getAttribute("data-pirc-script-id")');
      invoke('updateLayout', {
        revision: initial.layout.revision,
        generation: 1,
        viewport: {
          width: 390,
          height: 844,
          scrollX: 0,
          scrollY: 0,
          contentWidth: 390,
          contentHeight: 2200,
          scrollRange: {minLeft: 0, maxLeft: 0, minTop: 0, maxTop: 1356},
        },
        boxes: initial.layout.ids.map((id) =>
          id === elementId
            ? {
                id,
                kind: 'box',
                x: 0,
                y: 0,
                width: 180,
                height: 100,
                clientWidth: 180,
                clientHeight: 100,
                scroll: { left: 0, top: 0, width: 600, height: 800,
                  range: {minLeft: 0, maxLeft: 420, minTop: 0, maxTop: 700} },
              }
            : { id, kind: 'none' },
        ),
      });
      run(buildScrollCommandDriver(mode, target));
      run('document.getElementById("run").click()');
      const output = invoke('snapshot', {});
      assert.deepEqual(
        output.diagnostics.filter((d) => d.severity !== 'info'),
        [],
      );
      assert.deepEqual(
        output.scrollActions,
        commands.map((command, i) => ({
          actionId: i + 1,
          ...command,
          ...(target === 'element' ? { elementId } : {}),
        })),
        `${target}/${mode}`,
      );
    }
});

test('empty and null options cancel while lone primitive calls remain ignored', () => {
  const bundle = readFileSync(
    new URL('../../assets/document-script-runtime.js', import.meta.url),
    'utf8',
  );
  for (const target of ['root', 'element']) {
    const context = vm.createContext({}, { microtaskMode: 'afterEvaluate' });
    const run = (source) => new vm.Script(source).runInContext(context);
    run(bundle);
    run(
      `__pircDocument.init(${JSON.stringify({ hostLayout: true, url: 'https://example.test/options', html: scrollCommandsHTML })})`,
    );
    const elementId = run('document.getElementById("port").getAttribute("data-pirc-script-id")');
    run(
      `globalThis.target=${target === 'root' ? 'window' : 'document.getElementById("port")'};target.scrollTo();target.scrollTo(null);target.scrollBy();target.scrollBy(null);target.scrollTo(20)`,
    );
    const output = JSON.parse(run('__pircDocument.snapshot({})'));
    assert.deepEqual(
      output.scrollActions,
      [
        { actionId: 1, kind: 'to', x: null, y: null, behavior: 'auto' },
        { actionId: 2, kind: 'to', x: null, y: null, behavior: 'auto' },
        { actionId: 3, kind: 'by', x: 0, y: 0, behavior: 'auto' },
        { actionId: 4, kind: 'by', x: 0, y: 0, behavior: 'auto' },
      ].map((action) => ({ ...action, ...(target === 'element' ? { elementId } : {}) })),
    );
    assert.deepEqual(
      output.diagnostics.filter((d) => d.severity !== 'info'),
      [],
    );
  }
});
