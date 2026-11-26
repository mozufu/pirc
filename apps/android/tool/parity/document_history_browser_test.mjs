import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import nativeVm from 'node:vm';
import {createDocumentScriptHostVm} from './document_script_host_test_helper.mjs';
const vm=createDocumentScriptHostVm(nativeVm);

const runtimeBundle = readFileSync(
  new URL('../../assets/document-script-runtime.js', import.meta.url),
  'utf8'
);
const fixtureBytes = readFileSync(
  new URL('../../../../packages/pirc_render/test/fixtures/parity/document-history-chrome155.json', import.meta.url)
);
const chrome = JSON.parse(fixtureBytes.toString('utf8'));
const fixtureSha256 = 'b28ceb218bc504c21f54503963b37b2a5c18b3b5e8a467781a99e340727995da';
const timeoutMs = 3000;

// Replay only synchronous History API operations. Actions that need native
// navigation/traversal are deliberately not dispatched by this Node test.
const synchronousSteps = new Map([
  ['history-url-argument-matrix', [
    'push-empty',
    'replace-empty',
    'push-undefined-url',
    'push-null-url',
    'push-relative',
    'push-root',
    'push-query',
    'push-hash',
  ]],
  ['history-base-href-resolution', ['push-relative-with-base']],
  ['history-replace-current-entry', ['replace-state', 'replace-same-url']],
  ['history-state-clone-mutation-traversal', ['push-object-state', 'mutate-state-objects']],
  ['history-state-supported-structured-values', ['push-structured-values']],
  ['history-state-clone-rejections-and-arity', [
    'push-function',
    'push-symbol',
    'push-dom-node',
    'push-missing-args',
    'push-one-arg',
    'replace-missing-args',
    'replace-one-arg',
  ]],
  ['history-url-security-errors', [
    'push-cross-origin',
    'push-different-scheme',
    'push-credentials-url',
    'push-created-blob-url',
  ]],
]);

const nativeHostExclusions = [
  ['history-blob-fragment-update', 'Blob child-document navigation and Blob URL state'],
  ['history-out-of-bounds-traversals', 'asynchronous history.go traversal'],
  ['history-queued-traversal-calls', 'queued back/forward traversal'],
  ['history-go-zero-reloads-entry-state', 'history.go(0) reload'],
  ['history-native-fragment-and-push-mixed', 'location.hash, anchor-fragment, and traversal behavior'],
  ['history-sync-back-then-push', 'back traversal interleaved with synchronous pushes'],
  ['history-sync-push-back-back', 'multiple back traversals and about:blank navigation'],
  ['history-replace-state-native-fragment-replace', 'location.replace fragment navigation'],
  ['history-no-store-leave-return-state', 'cross-document no-store navigation and Back'],
  ['history-go-zero-out-of-bounds-after-back', 'Back and history.go boundary traversal'],
];
const nativeHostStepExclusions = [
  ['history-base-href-resolution', 'base-anchor', 'ordinary cross-document link navigation'],
  ['history-state-clone-mutation-traversal', 'back', 'asynchronous back traversal'],
  ['history-state-clone-mutation-traversal', 'forward', 'asynchronous forward traversal'],
];

const observedSnapshotFields = [
  'href',
  'documentURL',
  'baseURI',
  'historyLength',
  'historyState',
  'historyStateReadIdentity',
];

function invoke(context, method, args = {}) {
  const argument = JSON.stringify(args);
  return JSON.parse(vm.runInContext(
    `__pircDocument.${method}(${argument})`,
    context,
    {timeout: timeoutMs}
  ));
}

function evaluate(context, source) {
  return vm.runInContext(source, context, {timeout: timeoutMs});
}

function readJson(context, expression) {
  return JSON.parse(evaluate(context, `JSON.stringify(${expression})`));
}

function makePage(caseFixture) {
  const context = vm.createContext({});
  vm.runInContext(runtimeBundle, context, {timeout: timeoutMs});
  const initial = invoke(context, 'init', {
    html: caseFixture.sourceHtml,
    url: caseFixture.sourceUrl,
    objectUrlNonce: '47'.repeat(24),
    history: {entryKey: 'chrome-oracle-source', index: 1, length: 2},
  });
  return {context, initial};
}

function snapshot(context) {
  return readJson(context, 'window.__historySnapshot()');
}

function selectSnapshot(snapshotValue) {
  return Object.fromEntries(observedSnapshotFields.map(field => [field, snapshotValue[field]]));
}

function dispatchButton(context, id) {
  const marker = evaluate(context, `document.querySelector('button[data-history-action="${id}"]').getAttribute('data-pirc-script-id')`);
  assert.equal(typeof marker, 'string', `missing runtime script id for button ${id}`);
  return invoke(context, 'dispatch', {id: marker, type: 'click'});
}

function caseAction(caseFixture, id) {
  const action = caseFixture.finalDocument.actions.find(item => item.id === id);
  assert.ok(action, `${caseFixture.caseId} Chrome fixture has action ${id}`);
  return action;
}

test('History API fixture is pinned to its Chrome 155 browser observation', () => {
  assert.equal(createHash('sha256').update(fixtureBytes).digest('hex'), fixtureSha256);
  assert.match(chrome.browserVersion, /^155\./);
  assert.equal(chrome.caseCount, 17);
  assert.equal(chrome.cases.length, 17);
  for (const [caseId, ids] of synchronousSteps) {
    const entry = chrome.cases.find(item => item.caseId === caseId);
    assert.ok(entry, `missing frozen Chrome case ${caseId}`);
    assert.equal(entry.initialHistoryLength, 2, `${caseId} keeps the page.goto history entry`);
    for (const id of ids) assert.ok(entry.interaction.steps.some(step => step.id === id), `${caseId} includes ${id}`);
  }
});

test('native-host traversal, Blob-child, and cross-document cases are explicitly excluded', () => {
  const selected = new Set(synchronousSteps.keys());
  for (const [caseId, reason] of nativeHostExclusions) {
    assert.ok(chrome.cases.some(item => item.caseId === caseId), `missing excluded Chrome case ${caseId}`);
    assert.equal(selected.has(caseId), false, `${caseId} must stay out of this synchronous replay`);
    assert.ok(reason.length > 0);
  }
  for (const [caseId, id, reason] of nativeHostStepExclusions) {
    const entry = chrome.cases.find(item => item.caseId === caseId);
    assert.ok(entry?.interaction.steps.some(step => step.id === id), `missing native-host step ${caseId}/${id}`);
    assert.equal(synchronousSteps.get(caseId).includes(id), false, `${caseId}/${id} is excluded: ${reason}`);
  }
  assert.deepEqual(synchronousSteps.get('history-base-href-resolution'), ['push-relative-with-base']);
  assert.deepEqual(synchronousSteps.get('history-state-clone-mutation-traversal'), [
    'push-object-state',
    'mutate-state-objects',
  ]);
});

for (const [caseId, actionIds] of synchronousSteps) {
  test(`production runtime matches Chrome synchronous History API behavior: ${caseId}`, () => {
    const caseFixture = chrome.cases.find(item => item.caseId === caseId);
    const {context} = makePage(caseFixture);
    let sourceSnapshot = snapshot(context);
    const chromeInitial = caseFixture.snapshots[0];
    assert.deepEqual(selectSnapshot(sourceSnapshot), selectSnapshot(chromeInitial), `${caseId} initial document snapshot`);

    for (const id of actionIds) {
      const expected = caseAction(caseFixture, id);
      assert.deepEqual(selectSnapshot(snapshot(context)), selectSnapshot(expected.before), `${caseId}/${id} before`);

      dispatchButton(context, id);

      const actualAction = readJson(context, 'window.__historyOracle.actions.at(-1)');
      assert.equal(actualAction.id, id, `${caseId}/${id} dispatched the authored button`);
      assert.deepEqual(
        selectSnapshot(actualAction.before),
        selectSnapshot(expected.before),
        `${caseId}/${id} authored click listener observed the same starting snapshot`
      );
      assert.deepEqual(
        selectSnapshot(actualAction.afterImmediate),
        selectSnapshot(expected.afterImmediate),
        `${caseId}/${id} immediate snapshot`
      );
      assert.equal(actualAction.outcome.ok, expected.outcome.ok, `${caseId}/${id} success status`);
      assert.equal(actualAction.outcome.error?.name ?? null, expected.outcome.error?.name ?? null,
        `${caseId}/${id} error name`);
    }
  });
}
