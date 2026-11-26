import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import test from 'node:test';

const fixtureBytes = readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-referrer-chromium153.json', import.meta.url));
const oracle = JSON.parse(fixtureBytes);
const digest = bytes => createHash('sha256').update(bytes).digest('hex');

test('navigation referrer oracle is bound to its exact Chromium 153 runner and capture', () => {
  const runner = readFileSync(new URL('./verify_document_referrer_browser.mjs', import.meta.url));
  assert.equal(digest(runner), oracle.runnerSha256);
  assert.equal(oracle.runnerSha256, '3dbed150817b6b3562d9135dd83f2e6d3f37bc8a71aab15e03970d289e59a043');
  assert.equal(digest(fixtureBytes), 'da0868dda15e70edb0300b235a78c62ab21617e82ccda48134390084988d49ac');
  assert.equal(oracle.browserVersion, '153.0.8010.12');
  assert.equal(oracle.cases.length, 30);
  assert.equal(oracle.serverRequests.length, 62);
  assert.deepEqual(oracle.blockedRequests, []);
  assert.ok(oracle.cases.every(entry => entry.requestHops.length > 0));
});
