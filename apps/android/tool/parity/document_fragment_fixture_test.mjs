import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fragmentScenes, fragmentHTML } from './document_fragment_fixture.mjs';
const f = JSON.parse(
  readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-fragment-chromium153.json', import.meta.url)),
);
test('152 fragment profiles use exact shared browser sources and single document requests', () => {
  assert.equal(f.browserVersion, '153.0.8010.12');
  assert.equal(f.cases.length, 152);
  assert.equal(Object.keys(fragmentScenes).length, 19);
  assert.equal(
    new Set(f.cases.map((r) => [r.mode, r.viewport.width, r.dpr, r.theme].join('/'))).size,
    152,
  );
  for (const row of f.cases) {
    assert.equal(row.html, fragmentHTML(row.mode));
    assert.equal(row.hash, fragmentScenes[row.mode].hash);
    assert.equal(row.result.requestCount, 1);
    assert.ok(Number.isFinite(row.result.initial.root));
    assert.equal(typeof row.result.initial.hash, 'string');
  }
});
