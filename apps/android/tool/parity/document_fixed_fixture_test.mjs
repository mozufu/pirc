import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';
const fixture = JSON.parse(
  readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-fixed-chromium153.json', import.meta.url)),
);
const modes = [
  'top_left',
  'bottom_right',
  'percent',
  'stretch',
  'clipped_ancestor',
  'nested_scroll',
  'short_document',
  'fixed_button',
  'fixed_button_ua',
  'fixed_canvas',
  'absolute_child',
  'overlap_z',
  'pointer_none',
  'hidden_dynamic',
  'resize',
];
test('fixed positioning reference includes all profiles and ordered native-frame states', () => {
  assert.equal(fixture.schemaVersion, 1);
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(fixture.cases.length, 120);
  const actual = new Set(
    fixture.cases.map((r) => [r.mode, r.viewport.width, r.dpr, r.theme].join(':')),
  );
  const expected = new Set(
    modes.flatMap((m) =>
      [390, 768].flatMap((w) =>
        [1, 3].flatMap((d) => ['light', 'dark'].map((t) => [m, w, d, t].join(':'))),
      ),
    ),
  );
  assert.deepEqual(actual, expected);
  assert.equal(
    fixture.cases.reduce((n, r) => n + r.states.length, 0),
    368,
  );
  for (const row of fixture.cases) {
    assert.deepEqual(row.errors, []);
    assert.deepEqual(row.requests, []);
    assert.deepEqual(
      row.states.map((s) => s.state.phase),
      row.mode === 'resize' ? [0, 1, 1, 2] : [0, 1, 2],
    );
    for (const step of row.states) {
      assert.deepEqual(step.state.viewport, step.viewport);
      assert.deepEqual(step.state.clicks, []);
      assert.equal(
        step.state.scrollY,
        row.mode === 'short_document'
          ? 0
          : row.mode === 'hidden_dynamic' && step.state.phase === 2
            ? 300
            : step.state.phase
              ? 180
              : 0,
      );
    }
  }
});
test('fixed boxes remain pinned while flow moves and clipping/pointer policy stay distinct', () => {
  for (const row of fixture.cases) {
    const [initial, scrolled] = row.states;
    assert.deepEqual(initial.state.boxes.fixed, scrolled.state.boxes.fixed, row.mode);
    assert.equal(scrolled.state.hostScrollTop, row.mode === 'nested_scroll' ? 60 : 0);
    if (row.mode === 'short_document')
      for (const step of row.states) assert.equal(step.state.scrollHeight, step.viewport.height);
    if (row.mode === 'pointer_none')
      for (const step of row.states) {
        assert.notEqual(step.target, 'fixed');
        assert.deepEqual(step.rgba, [59, 130, 246, 255]);
      }
    if (row.mode === 'hidden_dynamic') {
      assert.equal(initial.state.boxes.fixed.width, 0);
      assert.equal(row.states.at(-1).state.boxes.fixed.width, 60);
    }
    if (row.mode === 'overlap_z') {
      assert.equal(initial.target, 'absolute');
      assert.equal(scrolled.target, 'fixed');
    }
    if (row.mode === 'absolute_child')
      for (const step of row.states) {
        assert.equal(step.target, 'inside');
        assert.deepEqual(step.rgba, [249, 115, 22, 255]);
      }
    if (row.mode === 'fixed_button_ua') {
      assert.equal(initial.state.boxes.fixed.width, 60);
      assert.equal(initial.state.boxes.fixed.height, 40);
    }
  }
});
test('fixed frozen HTML and drivers match the capture generator exactly', () => {
  const source = readFileSync(
    new URL('./capture_document_fixed_chromium153.mjs', import.meta.url),
    'utf8',
  );
  const start = source.indexOf('const short ='),
    end = source.indexOf('const context =');
  assert.ok(start >= 0 && end > start);
  for (const row of fixture.cases) {
    const generated = JSON.parse(
      vm.runInNewContext(
        source.slice(start, end) + '\nJSON.stringify({html,driverSource})',
        { mode: row.mode },
        { timeout: 1000 },
      ),
    );
    assert.equal(row.html, generated.html);
    assert.equal(row.driverSource, generated.driverSource);
  }
});
