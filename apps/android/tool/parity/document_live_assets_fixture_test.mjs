import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import {
  assetHTML,
  startupAssetHTML,
  assetCSS,
  assetEntry,
  assetDep,
  assetPng,
} from './document_live_assets_fixture.mjs';
test('live asset reference keeps sources, profiles, pixels and module cache outcomes', () => {
  const f = JSON.parse(
    readFileSync(
      new URL('../../../../packages/pirc_render/test/fixtures/parity/document-live-assets-chromium153.json', import.meta.url),
      'utf8',
    ),
  );
  assert.equal(f.browserVersion, '153.0.8010.12');
  assert.equal(f.html, assetHTML);
  assert.equal(f.startupHtml, startupAssetHTML);
  assert.equal(f.css, assetCSS);
  assert.equal(f.entry, assetEntry);
  assert.equal(f.dep, assetDep);
  assert.equal(f.png, assetPng);
  assert.equal(f.cases.length, 8);
  assert.equal(new Set(f.cases.map((r) => JSON.stringify([r.viewport, r.dpr, r.theme]))).size, 8);
  for (const r of f.cases) {
    assert.equal(r.states.length, 5);
    const cached = r.states.at(-1);
    assert.deepEqual(cached.probe, {
      boots: 1,
      style: 1,
      image: 1,
      entry: 1,
      dep: 1,
      runs: 2,
      trace: ['style', 'image', 'dep', 'entry', 'run', 'run'],
    });
    for (const s of [r.startup, ...r.states.filter((s) => s.pixels)]) {
      assert.deepEqual(s.natural, [2, 2]);
      assert.equal(s.pixels.length, 8);
      assert.deepEqual(s.pixels.slice(0, 4), s.pixels.slice(4));
      assert.deepEqual(s.pixels[0], [255, 0, 0, 255]);
    }
  }
});
