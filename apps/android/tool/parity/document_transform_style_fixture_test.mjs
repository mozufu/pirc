import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  transformStyleModes,
  transformStyleHTML,
  buildTransformStyleDriver,
} from './document_transform_style_fixture.mjs';
test('128 independent Chromium transform profiles retain exact shared HTML and live-declaration drivers', () => {
  const fixture = JSON.parse(
    readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-transform-style-chromium153.json', import.meta.url)),
  );
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(transformStyleModes.length, 16);
  assert.equal(fixture.cases.length, 128);
  assert.equal(
    new Set(fixture.cases.map((r) => [r.mode, r.viewport.width, r.dpr, r.theme].join('/'))).size,
    128,
  );
  for (const row of fixture.cases) {
    assert.equal(row.html, transformStyleHTML(row.mode));
    assert.equal(row.driverSource, buildTransformStyleDriver());
    for (const stage of ['before', 'after']) {
      const value = row.result[stage];
      assert.equal(value.transform, value.transformValue);
      assert.equal(value.origin, value.originValue);
      assert.ok(value.transform === 'none' || /^matrix\([^)]+\)$/.test(value.transform));
    }
  }
});
