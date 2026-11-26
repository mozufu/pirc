import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {test} from 'node:test';

const fixtureUrl = new URL('../../../../packages/pirc_render/test/fixtures/parity/document-referrer-navigation-chromium153.json', import.meta.url);
const runnerUrl = new URL('./verify_document_referrer_navigation_browser.mjs', import.meta.url);
const fixtureBytes = readFileSync(fixtureUrl);
const fixture = JSON.parse(fixtureBytes);
const digest = bytes => createHash('sha256').update(bytes).digest('hex');

test('navigation referrer oracle pins actual loopback Chromium 153 requests and lifecycle', () => {
  assert.equal(digest(readFileSync(runnerUrl)), fixture.runnerSha256);
  assert.equal(fixture.runnerSha256, '19f5b6b641a93d5e944c137a552ed059830efc2408c15c81e99b7108bb8fc9e8');
  assert.equal(digest(fixtureBytes), 'a04563eff19dbbac1985720f388fef1774db0cf491c4638df130c6452824882f');
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(fixture.cases.length, 16);
  assert.equal(fixture.serverRequests.length, 37);
  assert.deepEqual(fixture.blockedRequests, []);
  const origins = new Set(Object.values(fixture.origins));
  for (const item of fixture.cases) {
    assert.deepEqual(item.pageErrors, [], item.caseId);
    assert.match(item.sourceHtml, /referrer-observation/, item.caseId);
    assert.ok(item.snapshots.length >= 2, item.caseId);
    assert.ok(item.requests.length >= 2, item.caseId);
  }
  for (const request of fixture.serverRequests) {
    assert.ok(origins.has(new URL(request.url).origin), request.url);
    assert.equal(typeof request.response.bodyText, 'string');
  }
});
