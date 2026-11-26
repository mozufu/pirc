import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { fragmentFocusHTML, fragmentFocusModes } from './document_fragment_focus_fixture.mjs';
test('fragment focus oracle binds authored source, native viewport and trusted event reports', () => {
  const fixture = JSON.parse(
    readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-fragment-focus-chromium153.json', import.meta.url)),
  );
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(fixture.cases.length, 312);
  const keys = new Set();
  for (const row of fixture.cases) {
    assert.ok(fragmentFocusModes.includes(row.mode));
    assert.equal(row.html, fragmentFocusHTML(row.mode, row.scripted));
    assert.deepEqual(row.viewport, { width: row.screen.width, height: row.screen.height - 48 });
    const key = JSON.stringify([row.mode, row.scripted, row.screen, row.dpr, row.theme]);
    assert.ok(!keys.has(key));
    keys.add(key);
    assert.equal(row.result.requestCount, 1);
    assert.equal(row.result.first.length, row.result.repeated.length);
    for (const phase of ['initial', 'before', 'first', 'repeated']) {
      const result = row.result[phase];
      assert.deepEqual(result.viewport, row.viewport);
      assert.ok(['target', 'jump', 'body'].includes(result.active));
      if (row.scripted) {
        assert.ok(Array.isArray(result.events));
        assert.ok(result.events.every((event) => event.trusted === true));
      } else assert.equal(result.events, null);
    }
    if (row.scripted) assert.deepEqual(row.result.before.events, []);
  }
});
