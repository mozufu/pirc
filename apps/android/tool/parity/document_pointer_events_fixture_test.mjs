import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
const fixture = JSON.parse(
  readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-pointer-events-chromium153.json', import.meta.url)),
);
const modes = [
  'none',
  'auto',
  'inherited_none',
  'restore_block',
  'restore_inline',
  'inline_none',
  'initial',
  'unset',
  'inherit',
  'invalid',
  'variable',
  'invalid_variable',
  'clipped_restore',
  'overflow_restore',
  'higher_cover',
  'transparent_cover',
  'button_restore',
  'canvas_none',
  'canvas_restore',
  'svg_keyword_html',
  'dynamic',
  'programmatic',
];
test('pointer policy reference covers every frozen browser profile without external requests', () => {
  assert.equal(fixture.schemaVersion, 1);
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(fixture.cases.length, 176);
  const keys = new Set(
    fixture.cases.map((r) => [r.name, r.viewport.width, r.dpr, r.theme].join(':')),
  );
  const expected = new Set(
    modes.flatMap((n) =>
      [390, 768].flatMap((w) =>
        [1, 3].flatMap((d) => ['light', 'dark'].map((t) => [n, w, d, t].join(':'))),
      ),
    ),
  );
  assert.deepEqual(keys, expected);
  for (const row of fixture.cases) {
    assert.deepEqual(row.errors, []);
    assert.deepEqual(row.requests, []);
    assert.ok(row.html.includes('pointer-events:'));
    assert.deepEqual(row.initial.trace, []);
    for (const step of row.steps) {
      assert.ok(step.html.includes('id="host"'));
      if (step.action === 'tap') {
        assert.ok(Number.isFinite(step.point.x));
        assert.ok(Number.isFinite(step.point.y));
        assert.equal(step.state.trace.at(-1).target, step.target);
        assert.equal(step.state.trace.at(-1).current, 'host');
        assert.equal(step.state.trace.at(-1).trusted, true);
      }
    }
  }
});
test('frozen driver is the exact production integration driver emitted by capture', () => {
  const source = readFileSync(
    new URL('./capture_document_pointer_events_chromium153.mjs', import.meta.url),
    'utf8',
  );
  const match = source.match(/const driverSource\s*=\s*`([\s\S]*?)`;/);
  assert.ok(match);
  assert.equal(match[1], fixture.driverSource);
});
test('pointer policy distinguishes inheritance, restoration, clipping and paint from hit targets', () => {
  const targets = {
    none: ['base', 'base'],
    auto: ['overlay', 'base'],
    inherited_none: ['base'],
    restore_block: ['child', 'base'],
    restore_inline: ['child', 'child', 'base'],
    inline_none: ['overlay'],
    initial: ['child'],
    unset: ['base'],
    inherit: ['base'],
    invalid: ['child'],
    variable: ['child'],
    invalid_variable: ['base'],
    clipped_restore: ['child', 'base'],
    overflow_restore: ['child', 'child'],
    higher_cover: ['cover', 'base'],
    transparent_cover: ['child', 'base'],
    button_restore: ['child', 'base'],
    canvas_none: ['base'],
    canvas_restore: ['child'],
    svg_keyword_html: ['child'],
  };
  for (const row of fixture.cases) {
    if (targets[row.name])
      assert.deepEqual(
        row.steps.map((s) => s.target),
        targets[row.name],
        row.name,
      );
    const green = ['clipped_restore', 'overflow_restore'].includes(row.name);
    assert.deepEqual(row.paint.rgba, green ? [34, 197, 94, 255] : [59, 130, 246, 255], row.name);
    if (
      ['restore_block', 'restore_inline', 'button_restore', 'canvas_restore'].includes(row.name)
    ) {
      assert.deepEqual(
        row.steps[0].state.trace.map((e) => e.current),
        ['child', 'overlay', 'host'],
      );
      assert.equal(row.steps[0].state.pointer.overlay, 'none');
    }
  }
});
test('dynamic policy restores then withdraws hits and programmatic activation bypasses pointer policy', () => {
  for (const row of fixture.cases) {
    if (row.name === 'dynamic') {
      assert.deepEqual(
        row.steps.filter((s) => s.action === 'tap').map((s) => s.target),
        ['base', 'base', 'overlay', 'base'],
      );
      assert.deepEqual(
        row.steps.filter((s) => s.action === 'toggle').map((s) => s.state.pointer.overlay),
        ['auto', 'none'],
      );
    }
    if (row.name === 'programmatic') {
      const state = row.steps.at(-1).state;
      assert.equal(state.phase, 'program');
      assert.equal(state.pointer.overlay, 'none');
      assert.deepEqual(state.trace.slice(-2), [
        { target: 'overlay', current: 'overlay', trusted: false },
        { target: 'overlay', current: 'host', trusted: false },
      ]);
    }
  }
});
