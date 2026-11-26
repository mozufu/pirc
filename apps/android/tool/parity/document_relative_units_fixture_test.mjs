import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import {
  relativeUnitCases,
  relativeUnitHTML,
  relativeUnitCSS,
} from './document_relative_units_fixture.mjs';
test('relative-unit reference retains source-identical stages and all environments', () => {
  const f = JSON.parse(
    readFileSync(
      new URL('../../../../packages/pirc_render/test/fixtures/parity/document-relative-units-chromium153.json', import.meta.url),
      'utf8',
    ),
  );
  assert.equal(f.browserVersion, '153.0.8010.12');
  assert.equal(f.cases.length, 64);
  assert.equal(relativeUnitCases.length, 8);
  const seen = new Set();
  let states = 0;
  for (const row of f.cases) {
    assert.deepEqual(
      row.spec,
      relativeUnitCases.find((c) => c.id === row.spec.id),
    );
    assert.equal(row.html, relativeUnitHTML);
    const key = JSON.stringify([row.spec.id, row.viewport.width, row.dpr, row.theme]);
    assert.ok(!seen.has(key));
    seen.add(key);
    assert.ok([390, 768].includes(row.viewport.width));
    assert.ok([1, 3].includes(row.dpr));
    assert.ok(['light', 'dark'].includes(row.theme));
    assert.equal(row.states.length, 3);
    for (const [phase, state] of row.states.entries()) {
      assert.equal(state.phase, phase);
      assert.equal(state.css, relativeUnitCSS(row.spec, phase));
      assert.deepEqual(
        state.viewport,
        phase === 2
          ? { width: row.viewport.width - 40, height: row.viewport.height - 80 }
          : row.viewport,
      );
      assert.equal(state.result.draft, 'retained draft');
      assert.deepEqual(Object.keys(state.result.items), ['parent', 'subject', 'after']);
      assert.equal(state.result.probes.length, 2);
      assert.equal(state.result.pixels.length, 2);
      for (const rgba of state.result.pixels) {
        assert.equal(rgba.length, 4);
        assert.equal(rgba[3], 255);
      }
      assert.deepEqual(state.result.items.subject.rect.slice(2), [60, 32]);
      states++;
    }
  }
  assert.equal(states, 192);
});
