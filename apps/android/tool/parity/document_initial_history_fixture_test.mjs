import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { initialHistoryCases, initialHistoryHTML } from './document_initial_history_fixture.mjs';
test('initial History browser corpus covers complete environments and source-identical lifecycle phases', () => {
  const fixture = JSON.parse(
    readFileSync(
      new URL('../../../../packages/pirc_render/test/fixtures/parity/document-initial-history-chromium153.json', import.meta.url),
      'utf8',
    ),
  );
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(initialHistoryCases.length, 36);
  assert.equal(fixture.cases.length, 288);
  const seen = new Set();
  let states = 0;
  for (const row of fixture.cases) {
    const key = JSON.stringify([row.spec.id, row.viewport.width, row.dpr, row.theme]);
    assert.ok(!seen.has(key));
    seen.add(key);
    assert.equal(row.html, initialHistoryHTML(row.spec));
    assert.equal(row.viewport.height, row.screen.height - 48);
    assert.ok([1, 3].includes(row.dpr));
    assert.ok(['light', 'dark'].includes(row.theme));
    assert.ok([390, 768].includes(row.viewport.width));
    const { loaded, rewritten, back, forward } = row.result;
    assert.deepEqual(loaded.events, []);
    assert.deepEqual(rewritten.events, []);
    assert.equal(rewritten.target, loaded.target);
    assert.equal(rewritten.top, loaded.top);
    assert.deepEqual(rewritten.state, { stage: 'post' });
    const growth = (row.spec.sequence || [[row.spec.method, row.spec.next]]).filter(
      ([method]) => method === 'pushState',
    ).length;
    assert.equal(loaded.growth, growth);
    assert.equal(rewritten.growth, growth);
    if (growth > 0) {
      assert.ok(back && forward);
      assert.ok(back.events.some((e) => e.type === 'popstate'));
      assert.ok(forward.events.length > back.events.length);
      states += 4;
    } else {
      assert.equal(back, null);
      assert.equal(forward, null);
      states += 2;
    }
    if (row.spec.phase === 'load') {
      assert.equal(loaded.target, 'one');
      assert.equal(
        loaded.top,
        row.spec.scrollBefore ? row.spec.scrollBefore + (row.spec.scrollByBefore || 0) : 600,
      );
    }
    if (row.spec.id.endsWith('-keep')) {
      assert.equal(loaded.target, null);
      assert.equal(loaded.top, 240);
    }
  }
  assert.equal(states, 880);
});
