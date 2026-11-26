import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import {
  liveResourceHTML,
  liveResourcePayload,
  liveResourceExtraScript,
} from './document_live_resource_fixture.mjs';
test('live native resource corpus retains source, all profiles and operation sequence', () => {
  const fixture = JSON.parse(
    readFileSync(
      new URL('../../../../packages/pirc_render/test/fixtures/parity/document-live-resources-chromium153.json', import.meta.url),
      'utf8',
    ),
  );
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(fixture.html, liveResourceHTML);
  assert.deepEqual(fixture.payload, liveResourcePayload);
  assert.equal(fixture.extraScript, liveResourceExtraScript);
  assert.equal(fixture.cases.length, 8);
  assert.equal(
    new Set(fixture.cases.map((r) => JSON.stringify([r.viewport, r.dpr, r.theme]))).size,
    8,
  );
  for (const r of fixture.cases) {
    for (const state of ['initial', 'loading', 'resumed', 'extended', 'cancelled'])
      assert.equal(r[state].probe.boots, 1);
    assert.equal(r.resumed.value, liveResourcePayload.title);
    assert.equal(r.extended.value, liveResourcePayload.title + ' + script');
    assert.equal(r.extended.probe.extra, 1);
    assert.deepEqual(r.cancelled.probe.trace, [
      'start',
      'loaded',
      'extra-loaded',
      'start',
      'cancelled',
    ]);
    assert.equal(r.cancelled.value, r.extended.value);
    assert.deepEqual(r.cancelled.rect, r.extended.rect);
    assert.equal(r.resumed.rect[3], 48);
    assert.equal(r.extended.rect[3], 72);
  }
});
