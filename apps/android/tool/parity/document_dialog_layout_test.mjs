import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { dialogLayoutHTML } from './document_dialog_layout_fixture.mjs';
test('default dialog reference is bound to its captured source and eight complete profiles', () => {
  const fixture = JSON.parse(
    readFileSync(
      new URL('../../../../packages/pirc_render/test/fixtures/parity/document-dialog-layout-chromium153.json', import.meta.url),
      'utf8',
    ),
  );
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(fixture.html, dialogLayoutHTML);
  assert.equal(fixture.cases.length, 8);
  assert.equal(
    new Set(fixture.cases.map((p) => JSON.stringify([p.viewport, p.dpr, p.theme]))).size,
    8,
  );
  for (const p of fixture.cases) {
    assert.deepEqual(
      p.steps.map((s) => s.name),
      ['closed', 'open', 'close', 'reopen', 'author-color'],
    );
    for (const s of p.steps) {
      if (s.value.rect) {
        assert.equal(s.value.points.length, 3);
        assert.equal(s.value.pixels.length, 3);
      } else {
        assert.ok(['closed', 'close'].includes(s.name));
      }
    }
  }
});
