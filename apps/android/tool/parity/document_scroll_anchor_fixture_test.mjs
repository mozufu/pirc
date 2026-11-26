import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { scrollAnchorModes, buildScrollAnchorPage } from './document_scroll_anchor_fixture.mjs';
const fixture = JSON.parse(
  readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-scroll-anchor-chromium153.json', import.meta.url)),
);
test('root anchoring includes all frozen phone/tablet, density and theme profiles', () => {
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(fixture.cases.length, 144);
  assert.deepEqual(
    new Set(fixture.cases.map((r) => [r.mode, r.viewport.width, r.dpr, r.theme].join(':'))),
    new Set(
      scrollAnchorModes.flatMap((m) =>
        [390, 768].flatMap((w) =>
          [1, 3].flatMap((d) => ['light', 'dark'].map((t) => [m, w, d, t].join(':'))),
        ),
      ),
    ),
  );
  for (const row of fixture.cases) {
    assert.deepEqual(row.errors, []);
    assert.deepEqual(row.requests, []);
    assert.deepEqual(
      row.states.map((s) => s.state.phase),
      [0, 1, 2, 3],
    );
    for (const s of row.states) {
      assert.deepEqual(s.point, { x: 10, y: 100 });
      assert.equal(s.rgba.length, 4);
      assert.equal(s.rgba[3], 255);
      assert.ok(s.state.scrollY >= 0);
    }
  }
});
test('frozen anchoring source and driver bytes match the shared generator', () => {
  for (const row of fixture.cases) {
    const generated = buildScrollAnchorPage(row.mode);
    assert.equal(row.html, generated.html);
    assert.equal(row.driverSource, generated.driverSource);
  }
  assert.throws(() => buildScrollAnchorPage('unknown'));
});
test('reference distinguishes compensation, suppression, explicit scrolling and deleted-anchor reselection', () => {
  for (const row of fixture.cases) {
    const y = row.states.map((s) => s.state.scrollY);
    if (
      [
        'root_none',
        'subtree_none',
        'anchor_height',
        'ancestor_padding',
        'anchor_margin',
        'root_padding',
        'below',
      ].includes(row.mode)
    )
      assert.deepEqual(y, [0, 240, 240, 240], row.mode);
    if (row.mode === 'expand') assert.deepEqual(y, [0, 240, 360, 200]);
    if (row.mode === 'scroll_by') assert.deepEqual(y, [0, 240, 390, 210]);
    if (row.mode === 'scroll_to') assert.deepEqual(y, [0, 240, 400, 200]);
    if (row.mode === 'at_top') assert.deepEqual(y, [0, 0, 0, 0]);
    if (row.mode === 'fully_visible') assert.deepEqual(y, [0, 320, 400, 220]);
    if (row.mode === 'anchor_removed')
      assert.deepEqual(y, row.viewport.width === 390 ? [0, 340, 340, 340] : [0, 340, 0, 0]);
  }
});
