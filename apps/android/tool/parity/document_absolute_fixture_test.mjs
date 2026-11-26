import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
const fixture = JSON.parse(
  readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-absolute-chromium153.json', import.meta.url), 'utf8'),
);
const names = [
  'left_top',
  'right_bottom',
  'percent',
  'stretch',
  'margins',
  'auto_margins',
  'nested_host',
  'flex',
  'grid',
  'viewport',
  'auto_size',
  'clamped_stretch',
  'absolute_span',
  'absolute_img',
  'absolute_canvas',
  'rtl',
  'overlap_z',
  'overlap_source',
  'own_content-box',
  'own_border-box',
  'inline_mixed',
];
test('absolute positioning reference includes every browser profile and required case', () => {
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(fixture.cases.length, 168);
  const actual = new Set(fixture.cases.map((r) => [r.name, r.width, r.dpr, r.theme].join(':')));
  const expected = new Set(
    names.flatMap((n) =>
      [390, 768].flatMap((w) =>
        [1, 3].flatMap((d) => ['light', 'dark'].map((t) => [n, w, d, t].join(':'))),
      ),
    ),
  );
  assert.deepEqual(actual, expected);
  for (const row of fixture.cases) {
    for (const id of ['abs', 'host', 'one', 'two', 'after']) {
      assert.ok(row.observed[id]);
      for (const number of Object.values(row.observed[id])) assert.ok(Number.isFinite(number));
    }
    assert.deepEqual(
      row.pixels.map((p) => p.name),
      ['abs', 'one', 'two', 'abs-left'],
    );
  }
});
test('absolute positioning reference records real solid paint and topmost click targets', () => {
  const colors = {
    abs: [59, 130, 246, 255],
    abs2: [249, 115, 22, 255],
    one: [34, 197, 94, 255],
    two: [34, 197, 94, 255],
  };
  for (const row of fixture.cases)
    for (const sample of row.pixels) {
      assert.ok(sample.hit in colors, row.name + ' ' + sample.name);
      assert.deepEqual(sample.rgba, colors[sample.hit], row.name + ' ' + sample.name);
    }
});
