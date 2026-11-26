import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { elementAnchorModes, buildElementAnchorPage } from './document_element_anchor_fixture.mjs';
const fixture = JSON.parse(
  readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-element-anchor-chromium153.json', import.meta.url)),
);
test('element anchoring has all 168 exact-browser profiles and 672 states', () => {
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(fixture.cases.length, 168);
  assert.deepEqual(
    new Set(fixture.cases.map((r) => [r.mode, r.viewport.width, r.dpr, r.theme].join(':'))),
    new Set(
      elementAnchorModes.flatMap((m) =>
        [390, 768].flatMap((w) =>
          [1, 3].flatMap((d) => ['light', 'dark'].map((t) => [m, w, d, t].join(':'))),
        ),
      ),
    ),
  );
  assert.equal(
    fixture.cases.reduce((n, r) => n + r.states.length, 0),
    672,
  );
  for (const r of fixture.cases) {
    assert.deepEqual(r.errors, []);
    assert.deepEqual(r.requests, []);
    assert.deepEqual(
      r.states.map((s) => s.state.phase),
      [0, 1, 2, 3],
    );
    for (const s of r.states) {
      assert.deepEqual(s.point, { x: 30, y: 60 });
      assert.equal(s.rgba.length, 4);
      assert.equal(s.rgba[3], 255);
    }
  }
});
test('element reference uses shared generator source and driver bytes exactly', () => {
  for (const row of fixture.cases) {
    const source = buildElementAnchorPage(row.mode);
    assert.equal(row.html, source.html);
    assert.equal(row.driverSource, source.driverSource);
  }
  assert.throws(() => buildElementAnchorPage('unknown'));
});
test('browser reference retains independent opt-out scopes, coupled layers and native object replacement', () => {
  for (const row of fixture.cases) {
    const states = row.states.map((s) => s.state),
      root = states.map((s) => s.scrollY),
      outer = states.map((s) => s.scroll.outer.top);
    if (row.mode === 'expand') {
      assert.deepEqual(root, [0, 80, 200, 0]);
      assert.deepEqual(outer, [0, 240, 360, 200]);
    }
    if (row.mode === 'ancestor_none') {
      assert.deepEqual(root, [0, 80, 80, 80]);
      assert.deepEqual(outer, [0, 240, 360, 200]);
    }
    if (['owner_none', 'subtree_none', 'owner_resize'].includes(row.mode)) {
      assert.deepEqual(root, [0, 80, 80, 80]);
      assert.deepEqual(outer, [0, 240, 240, 240]);
    }
    if (row.mode === 'clip_scroll') assert.deepEqual(outer, [0, 0, 0, 0]);
    if (row.mode === 'replace_owner') {
      assert.deepEqual(outer, [0, 240, 0, 0]);
      assert.deepEqual(
        states.map((s) => s.scroll.outer.generation),
        ['1', '1', '2', '2'],
      );
    }
    if (row.mode === 'hide_show') assert.deepEqual(outer, [0, 240, 0, 240]);
    if (row.mode === 'deep_both') {
      assert.deepEqual(root, [0, 80, 320, 0]);
      assert.deepEqual(outer, [0, 200, 440, 0]);
      assert.deepEqual(
        states.map((s) => s.scroll.inner.top),
        [0, 240, 360, 200],
      );
    }
    if (row.mode === 'clamp_end') {
      assert.deepEqual(root, [0, 80, 200, 80]);
      assert.deepEqual(outer, [0, 1800, 1920, 1760]);
    }
  }
});
