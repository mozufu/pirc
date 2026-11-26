import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import {
  scrollRetentionHTML,
  scrollRetentionDriver,
} from './document_scroll_retention_fixture.mjs';
const fixture = JSON.parse(
  readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-scroll-retention-chromium153.json', import.meta.url)),
);
test('scroll retention reference uses the same authored source and sandbox driver', () => {
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(fixture.html, scrollRetentionHTML);
  assert.equal(fixture.driverSource, scrollRetentionDriver);
  assert.equal(fixture.cases.length, 8);
  assert.equal(
    new Set(
      fixture.cases.map((c) => [c.viewport.width, c.viewport.height, c.dpr, c.theme].join('/')),
    ).size,
    8,
  );
});
test('browser restores root history per entry but keeps nested offsets with the document', () => {
  for (const row of fixture.cases) {
    const states = Object.fromEntries(row.states.map((s) => [s.name, s]));
    assert.equal(row.states.length, 8);
    assert.equal(states['back-auto'].root, 100);
    assert.equal(states['forward-auto'].root, 200);
    assert.deepEqual(states['back-auto'].scroll, states.second.scroll);
    assert.deepEqual(states['forward-auto'].scroll, states.second.scroll);
    assert.equal(states['back-manual'].root, 300);
    assert.deepEqual(states['back-manual'].scroll, states.third.scroll);
    assert.equal(states['back-first-auto'].root, 100);
    assert.deepEqual(states['back-first-auto'].scroll, states.third.scroll);
    for (const port of Object.values(states['fresh-response'].scroll)) {
      assert.equal(port.left, 0);
      assert.equal(port.top, 0);
    }
    assert.equal(states['fresh-response'].root, 100);
    assert.equal(row.retainedEntry.root, 160);
    assert.equal(row.movedEntry.root, 0);
    assert.deepEqual(row.movedEntry.scroll, row.retainedEntry.scroll);
  }
});
