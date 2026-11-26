import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { controlLifetimeHTML, editedControlValues } from './document_control_lifetime_fixture.mjs';
test('retained-control reference keeps source, all environments and fresh/reset boundaries', () => {
  const f = JSON.parse(
    readFileSync(
      new URL('../../../../packages/pirc_render/test/fixtures/parity/document-control-lifetime-chromium153.json', import.meta.url),
      'utf8',
    ),
  );
  assert.equal(f.browserVersion, '153.0.8010.12');
  assert.equal(f.html, controlLifetimeHTML);
  assert.deepEqual(f.editedValues, editedControlValues);
  assert.equal(f.cases.length, 8);
  const profiles = new Set();
  for (const row of f.cases) {
    const key = JSON.stringify([row.viewport.width, row.dpr, row.theme]);
    assert.ok(!profiles.has(key));
    profiles.add(key);
    assert.deepEqual(row.edited.values, editedControlValues);
    assert.deepEqual(row.resumed, row.edited);
    assert.deepEqual(row.edited.selection, [1, 4]);
    assert.deepEqual(row.edited.files, [
      { name: 'fixture.bin', type: 'application/octet-stream', bytes: [0, 127, 128, 255] },
    ]);
    assert.deepEqual(row.fresh, row.initial);
    assert.deepEqual(row.reset.values, row.initial.values);
    assert.deepEqual(row.reset.files, []);
  }
});
