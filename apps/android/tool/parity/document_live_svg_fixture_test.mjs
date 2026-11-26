import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { fixture, svgSource } from './document_live_svg_fixture.mjs';

test('SVG reference records real browser states, source identity and HTML/Canvas pixels', () => {
  const f = JSON.parse(
    readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-live-svg-chromium153.json', import.meta.url), 'utf8'),
  );
  assert.equal(f.browserVersion, '153.0.8010.12');
  assert.equal(f.html, fixture.assetHTML);
  assert.equal(f.startupHtml, fixture.startupAssetHTML);
  assert.equal(f.css, fixture.assetCSS);
  assert.equal(f.entry, fixture.assetEntry);
  assert.equal(f.dep, fixture.assetDep);
  assert.equal(Buffer.from(f.imageBase64, 'base64').toString(), svgSource);
  assert.equal(f.imageMime, 'image/svg+xml');
  assert.equal(f.imagePath, '/photo.svg');
  assert.equal(f.cases.length, 8);
  assert.equal(new Set(f.cases.map((r) => JSON.stringify([r.viewport, r.dpr, r.theme]))).size, 8);
  for (const row of f.cases) {
    assert.deepEqual(
      row.states.map((s) => s.phase),
      ['initial', 'style', 'image', 'module', 'cached'],
    );
    assert.deepEqual(row.states.at(-1).probe, {
      boots: 1,
      style: 1,
      image: 1,
      entry: 1,
      dep: 1,
      runs: 2,
      trace: ['style', 'image', 'dep', 'entry', 'run', 'run'],
    });
    for (const state of [row.startup, ...row.states.filter((s) => s.pixels)]) {
      assert.deepEqual(state.natural, [2, 2]);
      assert.deepEqual(state.pixels, [
        [255, 0, 0, 255],
        [0, 255, 0, 255],
        [0, 0, 255, 255],
        [255, 255, 255, 255],
        [255, 0, 0, 255],
        [0, 255, 0, 255],
        [0, 0, 255, 255],
        [255, 255, 255, 255],
      ]);
    }
  }
});
