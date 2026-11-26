import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import test from 'node:test';
const fixture = JSON.parse(
  readFileSync(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-chart-animation-chromium153.json', import.meta.url),
    'utf8',
  ),
);
const types = ['bar', 'line', 'pie', 'doughnut', 'scatter', 'bubble', 'radar', 'polarArea'];
const stages = [
  'initial',
  'touchFirst',
  'touchSecond',
  'outside',
  'legendHide',
  'legendShow',
  'updated',
  'resized',
];
test('default-animation reference pins the real library, driver and browser', () => {
  const library = readFileSync(new URL('./vendor/chart.js-4.5.1/chart.umd.js', import.meta.url));
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(fixture.chartJs.version, '4.5.1');
  assert.equal(fixture.chartJs.sha256, createHash('sha256').update(library).digest('hex'));
  assert.equal(
    fixture.driverSource,
    readFileSync(new URL('./document_chart_animation_driver.js', import.meta.url), 'utf8'),
  );
});
test('default-animation reference includes every required type, profile and operation', () => {
  assert.equal(fixture.cases.length, 64);
  const expected = new Set(
    types.flatMap((type) =>
      [390, 768].flatMap((width) =>
        [1, 3].flatMap((dpr) =>
          ['light', 'dark'].map((theme) => type + '_' + width + '_' + dpr + '_' + theme),
        ),
      ),
    ),
  );
  const actual = new Set(
    fixture.cases.map(
      (row) => row.type + '_' + row.viewport.width + '_' + row.dpr + '_' + row.theme,
    ),
  );
  assert.deepEqual(actual, expected);
  for (const row of fixture.cases) {
    assert.deepEqual(
      row.steps.map((step) => step.name),
      stages,
      row.caseId,
    );
    assert.deepEqual(row.unexpectedRequests, []);
    assert.deepEqual(row.pageErrors, []);
  }
});
test('default-animation reference proves full-duration initialization and updates', () => {
  for (const row of fixture.cases)
    for (const step of row.steps) {
      const a = step.state.animation,
        label = row.caseId + ' ' + step.name;
      assert.equal(a.duration, 1000, label);
      assert.equal(a.easing, 'easeOutQuart', label);
      if (step.name !== 'initial' && step.name !== 'updated') continue;
      assert.ok(a.progressCount > 1, label);
      assert.ok(a.completeCount > 0, label);
      assert.equal(a.monotone, true, label);
      assert.ok(a.elapsed >= 900 && a.elapsed <= 5000, label);
      assert.equal(a.samples.at(-1).step, a.samples.at(-1).total, label);
    }
});
test('default-animation data updates contain actual changing numeric poses', () => {
  for (const row of fixture.cases) {
    const a = row.steps.find((step) => step.name === 'updated').state.animation;
    assert.ok(a.distinctPoses > 1, row.caseId);
    assert.notDeepEqual(a.samples[0].current, a.samples.at(-1).current, row.caseId);
    for (const sample of a.samples)
      for (const value of Object.values(sample.current))
        assert.ok(Number.isFinite(value), row.caseId);
  }
});
