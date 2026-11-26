import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  transformScrollModes,
  transformScrollHTML,
  buildTransformScrollDriver,
  buildTransformScrollClickObserver,
} from './document_transform_scroll_fixture.mjs';
test('192 independent transform scroll profiles preserve sources, clipping pixels and offset parents', () => {
  const f = JSON.parse(
    readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-transform-scroll-chromium153.json', import.meta.url)),
  );
  assert.equal(f.browserVersion, '153.0.8010.12');
  assert.equal(f.cases.length, 192);
  assert.equal(transformScrollModes.length, 24);
  assert.equal(
    new Set(f.cases.map((r) => [r.mode, r.viewport.width, r.dpr, r.theme].join('/'))).size,
    192,
  );
  let clipped = 0,
    visible = 0;
  for (const r of f.cases) {
    assert.equal(r.html, transformScrollHTML(r.mode));
    assert.equal(r.driverSource, buildTransformScrollDriver());
    assert.equal(r.clickObserverSource, buildTransformScrollClickObserver());
    assert.equal(r.clicks.before, Number(r.pixels.before.hit === 'target'));
    assert.equal(r.clicks.changed, r.clicks.before + Number(r.pixels.changed.hit === 'target'));
    for (const phase of ['before', 'scrolled', 'changed']) {
      const state = r.result[phase];
      const initiallyViewport = r.mode.startsWith('viewport-') || r.mode === 'add-transform';
      const viewport = phase === 'changed' ? r.mode === 'remove-transform' : initiallyViewport;
      assert.equal(state.boxes.target.offset.parentId, viewport ? null : 'host');
      for (const k of ['left', 'top', 'width', 'height', 'clientWidth', 'clientHeight'])
        assert.ok(Number.isInteger(state[k]));
    }
    for (const sample of Object.values(r.pixels)) {
      assert.equal(sample.rgba.length, 4);
      if (sample.hit === 'target') visible++;
      else clipped++;
    }
  }
  assert.ok(clipped > 0);
  assert.ok(visible > 0);
});
