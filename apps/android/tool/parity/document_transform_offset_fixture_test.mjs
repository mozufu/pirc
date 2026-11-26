import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  transformOffsetModes,
  transformOffsetHTML,
  buildTransformOffsetDriver,
} from './document_transform_offset_fixture.mjs';
test('224 independent transformed-offset profiles preserve sources, parent identities and scroll-independent layout', () => {
  const fixture = JSON.parse(
    readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-transform-offset-chromium153.json', import.meta.url)),
  );
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(fixture.cases.length, 224);
  assert.equal(transformOffsetModes.length, 28);
  assert.equal(
    new Set(fixture.cases.map((r) => [r.mode, r.viewport.width, r.dpr, r.theme].join('/'))).size,
    224,
  );
  for (const row of fixture.cases) {
    assert.equal(row.html, transformOffsetHTML(row.mode));
    assert.equal(row.driverSource, buildTransformOffsetDriver());
    assert.deepEqual(row.result.before, row.result.scrolled);
    for (const phase of ['before', 'scrolled', 'changed'])
      for (const value of Object.values(row.result[phase])) {
        assert.equal(value.parentIdentity, true);
        for (const key of ['left', 'top', 'width', 'height'])
          assert.ok(Number.isInteger(value[key]));
      }
  }
});
