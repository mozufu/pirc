import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  transformCBModes,
  transformCBHTML,
  buildTransformCBDriver,
} from './document_transform_cb_fixture.mjs';
test('136 independent transformed containing-block profiles preserve shared sources, actual clicks and pixels', () => {
  const fixture = JSON.parse(
    readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-transform-cb-chromium153.json', import.meta.url)),
  );
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(fixture.cases.length, 136);
  assert.equal(transformCBModes.length, 17);
  assert.equal(
    new Set(fixture.cases.map((r) => [r.mode, r.viewport.width, r.dpr, r.theme].join('/'))).size,
    136,
  );
  for (const row of fixture.cases) {
    assert.equal(row.html, transformCBHTML(row.mode));
    assert.equal(row.driverSource, buildTransformCBDriver());
    assert.equal(row.result.clicks, 1);
    for (const phase of ['before', 'changed']) {
      const sample = row.pixels[phase];
      assert.equal(sample.hit, 'target');
      assert.equal(sample.rgba.length, 4);
      assert.ok(Number.isFinite(sample.x) && Number.isFinite(sample.y));
    }
  }
});
