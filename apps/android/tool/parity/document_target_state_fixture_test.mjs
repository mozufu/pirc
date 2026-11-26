import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import {
  targetStateHTML,
  targetStateSteps,
  scriptedTargetStateSteps,
} from './document_target_state_fixture.mjs';
test('target state corpus uses identical sources, full environments and actual navigation states', () => {
  const fixture = JSON.parse(
    readFileSync(
      new URL('../../../../packages/pirc_render/test/fixtures/parity/document-target-state-chromium153.json', import.meta.url),
      'utf8',
    ),
  );
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(fixture.cases.length, 16);
  const keys = new Set();
  let states = 0;
  for (const row of fixture.cases) {
    const key = JSON.stringify([row.viewport, row.dpr, row.theme, row.scripted]);
    assert.ok(!keys.has(key));
    keys.add(key);
    assert.equal(row.viewport.width, row.screen.width);
    assert.equal(row.viewport.height, row.screen.height - 48);
    assert.equal(row.html, targetStateHTML(row.scripted));
    assert.equal(
      row.results.length,
      (row.scripted ? scriptedTargetStateSteps : targetStateSteps).length,
    );
    states += row.results.length;
    assert.deepEqual(row.results[0].target, ['one']);
    assert.deepEqual(row.results[6].target, ['hidden']);
    assert.deepEqual(row.results[7].target, []);
    if (row.scripted) {
      assert.deepEqual(row.results[11].target, ['one']);
      assert.deepEqual(row.results[12].target, ['one']);
      assert.deepEqual(row.results[13].target, ['one']);
      assert.deepEqual(row.results[14].target, []);
      assert.deepEqual(row.results[15].target, ['named']);
      assert.deepEqual(row.results[21].target, ['duplicate']);
      assert.deepEqual(row.results[0].script.lifecycle, [
        ['script', []],
        ['DOMContentLoaded', []],
        ['load', ['one']],
      ]);
      for (const result of row.results) assert.deepEqual(result.script.target, result.target);
    }
  }
  assert.equal(states, 256);
});
