import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';
const fixture = JSON.parse(
  readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-text-style-chromium153.json', import.meta.url)),
);
const modes = ['replace', 'character', 'append', 'remove', 'replace_children', 'hidden'];
test('text mutation reference covers all frozen profiles without external requests', () => {
  assert.equal(fixture.schemaVersion, 1);
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(fixture.cases.length, 48);
  const actual = new Set(
    fixture.cases.map((r) => [r.mode, r.viewport.width, r.dpr, r.theme].join(':')),
  );
  const expected = new Set(
    modes.flatMap((m) =>
      [390, 768].flatMap((w) =>
        [1, 3].flatMap((d) => ['light', 'dark'].map((t) => [m, w, d, t].join(':'))),
      ),
    ),
  );
  assert.deepEqual(actual, expected);
  for (const row of fixture.cases) {
    assert.deepEqual(row.errors, []);
    assert.deepEqual(row.requests, []);
    assert.ok(row.driverSource.includes('var synchronous=style();'));
    assert.ok(!row.driverSource.includes('await'));
  }
});
test('synchronous cascade values survive actual text changes and native frame geometry is independently measured', () => {
  const style = {
    color: 'rgb(1, 2, 3)',
    font: 'monospace',
    size: '16px',
    pointer: 'none',
    whiteSpace: 'pre',
    theme: 'night',
  };
  for (const row of fixture.cases) {
    assert.deepEqual(row.initial, { phase: 'ready', style });
    assert.deepEqual(row.result.synchronous, style);
    assert.deepEqual(row.result.settled, style);
    assert.deepEqual(row.result.rect, {
      x: 0,
      y: 0,
      width: 100,
      height: row.mode === 'remove' ? 0 : row.mode === 'hidden' ? 20 : 40,
    });
  }
});

test('frozen text drivers match the current capture generator byte for byte', () => {
  const source = readFileSync(
    new URL('./capture_document_text_style_chromium153.mjs', import.meta.url),
    'utf8',
  );
  const start = source.indexOf('const mutations = {');
  const end = source.indexOf('const browser = ');
  assert.ok(start >= 0 && end > start);
  const drivers = JSON.parse(
    vm.runInNewContext(
      source.slice(start, end) +
        '\nJSON.stringify(Object.fromEntries(Object.entries(mutations).map(([mode,mutation]) => [mode,driver(mutation)])))',
      {},
      { timeout: 1000 },
    ),
  );
  for (const row of fixture.cases) assert.equal(row.driverSource, drivers[row.mode]);
});
