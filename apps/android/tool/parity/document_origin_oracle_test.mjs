import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {test} from 'node:test';

const fixtureBytes = readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-origin-chromium153.json', import.meta.url));
const fixture = JSON.parse(fixtureBytes);
const digest = bytes => createHash('sha256').update(bytes).digest('hex');

test('Origin oracle pins Chromium 153 form hops, guards, policies, reload and Blob observations', () => {
  const runner = readFileSync(new URL('./verify_document_origin_browser.mjs', import.meta.url));
  assert.equal(digest(runner), fixture.runnerSha256);
  assert.equal(fixture.runnerSha256, '0e10ff4282a2e70008515976adb984c559fccf18fb463407fbd0a85ad2c51631');
  assert.equal(digest(fixtureBytes), '80cb3812406df4227947140300a077f2b684932feb96d9c903e9d2a3ea44d664');
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(fixture.cases.length, 42);
  assert.equal(fixture.serverRequests.length, 97);
  assert.equal(fixture.serverRequests.filter(r => new URL(r.url).pathname === '/favicon.ico').length, 0);
  assert.equal(fixture.cases.reduce((n, c) => n + c.requestHops.length, 0), 97);
  assert.equal(fixture.externalProxy.forwardsRequests, false);
  assert.equal(fixture.externalProxy.blockedRequestCount, 0);
  assert.equal(fixture.externalProxy.pageRequestsStayedOnLoopbackOrBlob, true);
  const origins = new Set(['a', 'b', 'c'].map(k => fixture.origins[k]));
  for (const r of fixture.serverRequests) {
    assert.ok(origins.has(new URL(r.url).origin), r.url);
    assert.equal(typeof r.responseBody, 'string');
  }
  for (const c of fixture.cases) {
    assert.deepEqual(c.pageErrors, [], c.caseId);
    assert.deepEqual(c.navigationErrors, [], c.caseId);
    assert.deepEqual(c.unexpectedPageRequests, [], c.caseId);
    assert.match(c.sourceHtml, /referrer-observation/);
    assert.equal(typeof c.finalDocument.referrerObservation.referrer, 'string');
    if (c.guard) assert.equal(c.guard.accepted, true, c.caseId);
  }
  for (const policy of fixture.policyNames) {
    assert.ok(fixture.cases.some(c => c.caseId === `post-policy-${policy}`));
    assert.ok(fixture.cases.some(c => c.caseId === `post-policy-element-${policy}`));
  }
});
