import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { fragmentScrollHTML, fragmentScrollModes } from './document_fragment_scroll_fixture.mjs';

test('fragment scroll oracle retains exact source, viewport and control profile coverage', () => {
  const fixture = JSON.parse(
    readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-fragment-scroll-chromium153.json', import.meta.url)),
  );
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(fixture.cases.length, 280);
  const keys = new Set();
  for (const row of fixture.cases) {
    assert.ok(fragmentScrollModes.includes(row.mode));
    assert.equal(row.html, fragmentScrollHTML(row.mode, row.scripted));
    assert.deepEqual(row.viewport, { width: row.screen.width, height: row.screen.height - 48 });
    const key = JSON.stringify([row.mode, row.scripted, row.screen, row.dpr, row.theme]);
    assert.ok(!keys.has(key));
    keys.add(key);
    assert.equal(row.result.requestCount, 1);
    for (const phase of ['initial', 'before', 'first', 'repeated'])
      assert.deepEqual(row.result[phase].viewport, row.viewport);
    assert.equal(row.result.initial.hash, '#target');
    assert.equal(row.result.first.hash, '#target');
    assert.equal(row.result.repeated.hash, '#target');
    assert.equal(row.result.repeated.length, row.result.first.length);
  }
  assert.equal(fixture.cases.filter((row) => ['button', 'input'].includes(row.mode)).length, 32);
});
