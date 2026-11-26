import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import nativeVm from 'node:vm';
import {createDocumentScriptHostVm} from './document_script_host_test_helper.mjs';
const vm=createDocumentScriptHostVm(nativeVm);

const bundlePath = process.env.PIRC_DOCUMENT_SCRIPT_RUNTIME_BUNDLE ||
  new URL('../../assets/document-script-runtime.js', import.meta.url);
const bundle = readFileSync(bundlePath, 'utf8');
const RUN_TIMEOUT_MS = 3000;
const fixtureSource = readFileSync(new URL('../../integration_test/document_focus_fixture.dart', import.meta.url), 'utf8');
const fixtureMatch = fixtureSource.match(/const documentFocusFixture\s*=\s*r'''([\s\S]*?)''';/);
assert.ok(fixtureMatch, 'Could not extract documentFocusFixture.');
const fixtureHtml = fixtureMatch[1];
const oracle = JSON.parse(readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-focus-chrome155.json', import.meta.url), 'utf8'));
assert.equal(
  createHash('sha256').update(fixtureSource).digest('hex'),
  oracle.fixtureSha256,
  'The Chrome oracle must describe the current shared focus fixture.',
);

function createRuntime() {
  const context = vm.createContext({});
  new vm.Script(bundle, { filename: 'document-script-runtime.js' }).runInContext(context, {
    timeout: RUN_TIMEOUT_MS,
  });
  return context;
}

function invoke(context, method, argument = {}) {
  const expression = '__pircDocument.' + method + '(' + JSON.stringify(argument) + ')';
  return JSON.parse(new vm.Script(expression).runInContext(context, {
    timeout: RUN_TIMEOUT_MS,
  }));
}

function read(context, expression) {
  return new vm.Script('JSON.stringify(' + expression + ')').runInContext(context, {
    timeout: RUN_TIMEOUT_MS,
  });
}

function normalizeChromeComparison(value) {
  if (Array.isArray(value))
    return value.map(normalizeChromeComparison);
  if (!value || typeof value !== 'object')
    return value;
  const result = {};
  for (const [key, child] of Object.entries(value)) {
    if (key === 'timeStamp' || key === 'scroll')
      continue;
    result[key] = normalizeChromeComparison(child);
  }
  return result;
}

test('script focus and blur update activeElement, events, and ordered host actions', () => {
  const context = createRuntime();
  const initialized = invoke(context, 'init', {
    html: [
      '<input id="origin"><input id="target"><script>',
      'window.focusEvents = [];',
      'for (const type of ["blur", "focusout", "focus", "focusin"]) {',
      '  for (const element of [document.querySelector("#origin"), document.querySelector("#target")]) {',
      '    element.addEventListener(type, event => focusEvents.push({',
      '      type: event.type, target: event.target.id, related: event.relatedTarget && event.relatedTarget.id,',
      '      active: document.activeElement.id || document.activeElement.localName,',
      '      trusted: event.isTrusted, composed: event.composed, bubbles: event.bubbles, cancelable: event.cancelable,',
      '      focusEvent: event instanceof FocusEvent',
      '    }));',
      '  }',
      '}',
      'document.querySelector("#origin").focus();',
      'window.focusEvents = [];',
      'document.querySelector("#target").focus({preventScroll: true});',
      'document.querySelector("#target").focus();',
      '</script>',
    ].join('\n'),
  });

  const targetId = vm.runInContext(
    'document.querySelector("#target").getAttribute("data-pirc-script-id")',
    context,
  );
  const originId = vm.runInContext(
    'document.querySelector("#origin").getAttribute("data-pirc-script-id")',
    context,
  );
  assert.equal(vm.runInContext('document.activeElement.id', context), 'target');
  assert.deepEqual(initialized.focusActions, [
    { kind: 'focus', controlId: originId, preventScroll: false, actionOrder: 1 },
    { kind: 'focus', controlId: targetId, preventScroll: true, actionOrder: 2 },
  ]);
  assert.deepEqual(JSON.parse(read(context, 'window.focusEvents')), [
    {
      type: 'blur', target: 'origin', related: 'target', active: 'body',
      trusted: true, composed: true, bubbles: false, cancelable: false, focusEvent: true,
    },
    {
      type: 'focusout', target: 'origin', related: 'target', active: 'body',
      trusted: true, composed: true, bubbles: true, cancelable: false, focusEvent: true,
    },
    {
      type: 'focus', target: 'target', related: 'origin', active: 'target',
      trusted: true, composed: true, bubbles: false, cancelable: false, focusEvent: true,
    },
    {
      type: 'focusin', target: 'target', related: 'origin', active: 'target',
      trusted: true, composed: true, bubbles: true, cancelable: false, focusEvent: true,
    },
  ]);

  vm.runInContext('document.querySelector("#target").blur()', context, {
    timeout: RUN_TIMEOUT_MS,
  });
  assert.equal(vm.runInContext('document.activeElement.localName', context), 'body');
  const blurred = invoke(context, 'snapshot');
  assert.deepEqual(blurred.focusActions, [
    { kind: 'blur', controlId: targetId, preventScroll: false, actionOrder: 3 },
  ]);
  vm.runInContext('document.querySelector("#target").blur()', context, {
    timeout: RUN_TIMEOUT_MS,
  });
  assert.deepEqual(invoke(context, 'snapshot').focusActions, []);
});

test('reentrant focus from blur keeps the inner target and completes the old focusout', () => {
  const context = createRuntime();
  const initialized = invoke(context, 'init', {
    html: [
      '<input id="origin"><input id="redirect"><input id="target"><script>',
      'window.events = [];',
      'const origin = document.querySelector("#origin");',
      'const redirect = document.querySelector("#redirect");',
      'const target = document.querySelector("#target");',
      'for (const element of [origin, redirect, target]) {',
      '  for (const type of ["blur", "focusout", "focus", "focusin"]) {',
      '    element.addEventListener(type, event => events.push({',
      '      type: event.type, target: event.target.id, related: event.relatedTarget && event.relatedTarget.id,',
      '      active: document.activeElement.id || document.activeElement.localName',
      '    }));',
      '  }',
      '}',
      'origin.focus(); events = [];',
      'origin.addEventListener("blur", () => redirect.focus());',
      'target.focus();',
      '</script>',
    ].join('\n'),
  });

  assert.equal(vm.runInContext('document.activeElement.id', context), 'redirect');
  assert.deepEqual(JSON.parse(read(context, 'window.events')), [
    { type: 'blur', target: 'origin', related: 'target', active: 'body' },
    { type: 'focus', target: 'redirect', related: null, active: 'redirect' },
    { type: 'focusin', target: 'redirect', related: null, active: 'redirect' },
    { type: 'focusout', target: 'origin', related: null, active: 'redirect' },
  ]);
  assert.deepEqual(initialized.focusActions.map(action => action.controlId), [
    'pirc-1', 'pirc-2',
  ]);
  assert.deepEqual(initialized.focusActions.map(action => action.actionOrder), [1, 2]);
});

test('focus handler blur cancels the outer focusin and leaves the final host action blurred', () => {
  const context = createRuntime();
  const initialized = invoke(context, 'init', {
    html: [
      '<input id="origin"><input id="target"><script>',
      'window.events = [];',
      'const origin = document.querySelector("#origin");',
      'const target = document.querySelector("#target");',
      'for (const element of [origin, target]) {',
      '  for (const type of ["blur", "focusout", "focus", "focusin"]) {',
      '    element.addEventListener(type, event => events.push({',
      '      type: event.type, target: event.target.id, related: event.relatedTarget && event.relatedTarget.id,',
      '      active: document.activeElement.id || document.activeElement.localName',
      '    }));',
      '  }',
      '}',
      'origin.focus(); events = [];',
      'target.addEventListener("focus", () => target.blur(), { once: true });',
      'target.focus();',
      '</script>',
    ].join('\n'),
  });

  assert.equal(vm.runInContext('document.activeElement.localName', context), 'body');
  assert.deepEqual(JSON.parse(read(context, 'window.events')), [
    { type: 'blur', target: 'origin', related: 'target', active: 'body' },
    { type: 'focusout', target: 'origin', related: 'target', active: 'body' },
    { type: 'focus', target: 'target', related: 'origin', active: 'target' },
    { type: 'blur', target: 'target', related: null, active: 'body' },
    { type: 'focusout', target: 'target', related: null, active: 'body' },
  ]);
  assert.deepEqual(initialized.focusActions.map(action => action.kind), ['focus', 'blur']);
  assert.deepEqual(initialized.focusActions.map(action => action.actionOrder), [1, 2]);
});

test('dirty host input dispatches change before script-driven blur', () => {
  const context = createRuntime();
  invoke(context, 'init', {
    html: [
      '<input id="origin"><input id="target"><script>',
      'window.events = [];',
      'const origin = document.querySelector("#origin");',
      'const target = document.querySelector("#target");',
      'for (const type of ["input", "change", "blur", "focusout", "focus", "focusin"]) {',
      '  origin.addEventListener(type, event => events.push({',
      '    type: event.type, related: event.relatedTarget && event.relatedTarget.id,',
      '    active: document.activeElement.id || document.activeElement.localName,',
      '    trusted: event.isTrusted, composed: event.composed, bubbles: event.bubbles',
      '  }));',
      '  target.addEventListener(type, event => events.push({',
      '    type: event.type, target: event.target.id, related: event.relatedTarget && event.relatedTarget.id,',
      '    active: document.activeElement.id || document.activeElement.localName,',
      '    trusted: event.isTrusted, composed: event.composed, bubbles: event.bubbles',
      '  }));',
      '}',
      'target.addEventListener("input", () => {});',
      'target.addEventListener("change", () => {});',
      'target.addEventListener("blur", () => {});',
      'window.moveFocus = () => target.focus();',
      '</script>',
    ].join('\n'),
  });
  const originId = vm.runInContext(
    'document.querySelector("#origin").getAttribute("data-pirc-script-id")', context,
  );
  invoke(context, 'dispatch', { id: originId, type: 'focus' });
  invoke(context, 'dispatch', { id: originId, type: 'focusin' });
  vm.runInContext('window.events = []', context);
  vm.runInContext('document.querySelector("#origin").addEventListener("input", moveFocus)', context);

  const inputResult = invoke(context, 'dispatch', { id: originId, type: 'input' });
  const events = JSON.parse(read(context, 'window.events'));
  assert.deepEqual(events.map(event => event.type), [
    'input', 'change', 'blur', 'focusout', 'focus', 'focusin',
  ]);
  assert.equal(events[0].trusted, true);
  assert.equal(events[0].composed, true);
  assert.equal(events[1].trusted, true);
  assert.equal(events[1].composed, false);
  assert.equal(events[2].related, 'target');
  assert.equal(events[2].active, 'body');
  assert.equal(events[3].related, 'target');
  assert.equal(events[4].related, 'origin');
  assert.equal(events[5].related, 'origin');
  assert.deepEqual(inputResult.focusActions.map(action => action.kind), ['focus']);
});

test('focusability handles controls, disabled fieldsets, inline hidden state, and tabindex', () => {
  const context = createRuntime();
  const initialized = invoke(context, 'init', {
    html: [
      '<input id="origin">',
      '<input id="disabled" disabled>',
      '<fieldset disabled><legend><input id="legend"></legend><input id="disabled-descendant"></fieldset>',
      '<div id="plain"></div><div id="tab" tabindex="-1"></div>',
      '<div style="display:none"><input id="hidden-ancestor"></div>',
      '<input id="detached"><a id="link" href="#focus-destination">link</a>',
    ].join(''),
  });
  const initialId = vm.runInContext(
    'document.querySelector("#origin").getAttribute("data-pirc-script-id")', context,
  );
  vm.runInContext('document.querySelector("#origin").focus()', context);
  for (const selector of ['#disabled', '#disabled-descendant', '#plain', '#hidden-ancestor']) {
    vm.runInContext('document.querySelector(' + JSON.stringify(selector) + ').focus()', context);
    assert.equal(vm.runInContext('document.activeElement.id', context), 'origin', selector);
  }
  vm.runInContext('const detached = document.querySelector("#detached"); detached.remove(); detached.focus()', context);
  assert.equal(vm.runInContext('document.activeElement.id', context), 'origin');
  vm.runInContext('document.querySelector("#legend").focus()', context);
  assert.equal(vm.runInContext('document.activeElement.id', context), 'legend');
  vm.runInContext('document.querySelector("#tab").focus()', context);
  assert.equal(vm.runInContext('document.activeElement.id', context), 'tab');
  vm.runInContext('document.querySelector("#link").focus()', context);
  assert.equal(vm.runInContext('document.activeElement.id', context), 'link');
  const actions = invoke(context, 'snapshot').focusActions;
  assert.deepEqual(actions.map(action => action.kind), ['focus', 'focus', 'focus', 'focus']);
  assert.equal(actions[0].controlId, initialId);
  assert.equal(actions.every(action => action.actionOrder > 0), true);
  // External computed styles are unavailable; focusability uses hidden and inline style attributes.
  assert.equal(initialized.diagnostics.some(item => item.severity === 'error'), false);
});

test('host focusin queued before a reentrant focus is suppressed without rolling back activeElement', () => {
  const context = createRuntime();
  invoke(context, 'init', {
    html: [
      '<input id="origin"><input id="target"><input id="redirect"><script>',
      'window.events = [];',
      'const target = document.querySelector("#target");',
      'const redirect = document.querySelector("#redirect");',
      'for (const element of [target, redirect]) {',
      '  for (const type of ["focus", "focusin"]) {',
      '    element.addEventListener(type, event => events.push({type: event.type, target: event.target.id}));',
      '  }',
      '}',
      'target.addEventListener("focus", () => redirect.focus());',
      '</script>',
    ].join('\n'),
  });
  const id = selector => vm.runInContext(
    'document.querySelector(' + JSON.stringify(selector) + ').getAttribute("data-pirc-script-id")',
    context,
  );
  invoke(context, 'dispatch', { id: id('#origin'), type: 'focus' });
  invoke(context, 'dispatch', { id: id('#origin'), type: 'focusin' });
  invoke(context, 'dispatch', { id: id('#target'), type: 'focus' });
  const staleFocusIn = invoke(context, 'dispatch', { id: id('#target'), type: 'focusin' });
  assert.equal(staleFocusIn.focusEventSuppressed, true);
  assert.equal(vm.runInContext('document.activeElement.id', context), 'redirect');
  assert.deepEqual(JSON.parse(read(context, 'window.events')), [
    { type: 'focus', target: 'target' },
    { type: 'focus', target: 'redirect' },
    { type: 'focusin', target: 'redirect' },
  ]);
});

test('startup focus handlers do not create popup or file picker activation', () => {
  const context = createRuntime();
  const initialized = invoke(context, 'init', {
    url: 'https://example.test/start',
    html: [
      '<input id="origin"><input id="file" type="file"><script>',
      'const origin = document.querySelector("#origin");',
      'const file = document.querySelector("#file");',
      'window.popup = false;',
      'window.pickerError = "";',
      'origin.onfocus = () => {',
      '  window.popup = window.open("/popup", "_blank");',
      '  try { file.showPicker(); } catch (error) { window.pickerError = error.name; }',
      '  file.click();',
      '};',
      'origin.focus();',
      '</script>',
    ].join('\n'),
  });
  assert.equal(vm.runInContext('window.popup', context), null);
  assert.equal(vm.runInContext('window.pickerError', context), 'NotAllowedError');
  assert.deepEqual(initialized.navigationActions, []);
  assert.deepEqual(initialized.filePickerActions, []);
  assert.deepEqual(initialized.focusActions.map(action => action.kind), ['focus']);
});

test('host input followed by script focus matches the dirty Chrome oracle case', () => {
  const expected = oracle.cases.find(item => item.caseId === 'dirty-user-edit-script-focus');
  assert.ok(expected, 'The frozen Chrome fixture must include the dirty text edit case.');
  const context = createRuntime();
  invoke(context, 'init', {
    html: fixtureHtml,
    url: 'http://127.0.0.1:64690/fixture?case=' + encodeURIComponent(expected.caseId),
  });

  const caseId = JSON.stringify(expected.caseId);
  const initialCapture = JSON.parse(read(context, 'window.prepareDocumentFocusCase(' + caseId + ')'));
  invoke(context, 'snapshot');
  assert.equal(initialCapture.activeElement.id, 'target');
  const targetId = vm.runInContext(
    'document.querySelector("#target").getAttribute("data-pirc-script-id")', context,
  );
  const inputResult = invoke(context, 'dispatch', { id: targetId, type: 'input' });
  assert.equal(inputResult.defaultPrevented, false);
  const actual = JSON.parse(read(
    context,
    'window.runDocumentFocusCase(' + caseId + ', "trusted-visible-button")',
  ));
  assert.deepEqual(
    normalizeChromeComparison(actual),
    normalizeChromeComparison(expected.fixtureResult),
    'dirty input/change/focus stable runtime fields; timeStamp and scroll are excluded',
  );
});

const chromeComparableCases = oracle.cases.filter(item =>
  !['focus-prevent-scroll', 'dirty-user-edit-script-focus'].includes(item.caseId),
);
assert.equal(chromeComparableCases.length, 27);

// `window.scrollTo` and global scroll coordinates are not modeled; preventScroll
// is carried to the native host. External computed CSS (including body
// visibility), full inert semantics, contenteditable, iframe focus, and
// autofocus behavior remain outside this comparison fixture.

for (const expected of chromeComparableCases) {
  test('script focus behavior matches Chrome 155: ' + expected.caseId, () => {
    const context = createRuntime();
    const initialized = invoke(context, 'init', {
      html: fixtureHtml,
      url: 'http://127.0.0.1:64690/fixture?case=' + encodeURIComponent(expected.caseId),
    });
    assert.equal(
      initialized.diagnostics.some(item => item.severity === 'error'),
      false,
      expected.caseId + ' runtime initialization',
    );

    const caseId = JSON.stringify(expected.caseId);
    const initialCapture = JSON.parse(read(context, 'window.prepareDocumentFocusCase(' + caseId + ')'));
    invoke(context, 'snapshot');
    const actual = JSON.parse(read(
      context,
      'window.runDocumentFocusCase(' + caseId + ', "trusted-visible-button")',
    ));
    const actions = invoke(context, 'snapshot').focusActions;
    assert.ok(Array.isArray(actions), expected.caseId + ' focus action response');
    assert.equal(initialCapture.activeElement.id,
      expected.caseId === 'dirty-user-edit-script-focus' ? 'target' : 'origin');
    assert.deepEqual(
      normalizeChromeComparison(actual),
      normalizeChromeComparison(expected.fixtureResult),
      expected.caseId + ' stable runtime fields; timeStamp and scroll are excluded',
    );
  });
}

test('focus/input/change listeners retain capture, once, removal, abort and property handlers', () => {
  const context = createRuntime();
  invoke(context, 'init', {html:'<div id="parent"><input id="target"></div>'});
  vm.runInContext(`
    window.contract=[];
    const parent=document.getElementById('parent'), target=document.getElementById('target');
    const controller=new AbortController();
    parent.addEventListener('focus',()=>contract.push('aborted'),{capture:true,signal:controller.signal});
    controller.abort();
    parent.addEventListener('focus',()=>contract.push('capture-once'),{capture:true,once:true});
    const removed=()=>contract.push('removed');
    target.addEventListener('focus',()=>{contract.push('first');target.removeEventListener('focus',removed)});
    target.addEventListener('focus',removed);
    target.onfocus=()=>contract.push('focus-property');
    target.focus();target.blur();target.focus();
    window.focusContract=contract.slice();contract=[];
    window.addEventListener('input',()=>contract.push('window-capture'),true);
    parent.addEventListener('input',()=>contract.push('parent-capture'),true);
    target.oninput=()=>contract.push('input-property');
    target.addEventListener('input',()=>contract.push('input-listener'));
    parent.addEventListener('input',()=>contract.push('parent-bubble'));
    window.addEventListener('input',()=>contract.push('window-bubble'));
    target.dispatchEvent(new Event('input',{bubbles:true}));
    target.onchange=()=>contract.push('change-property');
    target.dispatchEvent(new Event('change',{bubbles:true}));
    window.inputContract=contract.slice();contract=[];
    target.addEventListener('focusin',e=>{contract.push('stop');e.stopImmediatePropagation()});
    target.addEventListener('focusin',()=>contract.push('should-not-run'));
    parent.addEventListener('focusin',()=>contract.push('should-not-bubble'));
    target.dispatchEvent(new FocusEvent('focusin',{bubbles:true}));
    window.stopContract=contract.slice();
  `,context,{timeout:RUN_TIMEOUT_MS});
  assert.deepEqual(JSON.parse(read(context,'window.focusContract')),
    ['capture-once','first','focus-property','first','focus-property']);
  assert.deepEqual(JSON.parse(read(context,'window.inputContract')),
    ['window-capture','parent-capture','input-property','input-listener','parent-bubble','window-bubble','change-property']);
  assert.deepEqual(JSON.parse(read(context,'window.stopContract')),['stop']);
});
