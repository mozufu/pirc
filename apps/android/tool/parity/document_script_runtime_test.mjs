import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import nativeVm from 'node:vm';
import {createDocumentScriptHostVm} from './document_script_host_test_helper.mjs';
const vm=createDocumentScriptHostVm(nativeVm);

const bundlePath = process.env.PIRC_DOCUMENT_SCRIPT_RUNTIME_BUNDLE || fileURLToPath(
  new URL('../../assets/document-script-runtime.js', import.meta.url)
);
const bundle = readFileSync(bundlePath, 'utf8');
const RUN_TIMEOUT_MS = 3000;
const fragmentWebFixture = JSON.parse(readFileSync(
  new URL(
    '../../../../packages/pirc_render/test/fixtures/parity/document-fragment-scripts-chromium153.json',
    import.meta.url,
  ),
  'utf8',
));
assert.equal(fragmentWebFixture.browserVersion, '153.0.8010.12');
const contextualFragmentWebFixture = JSON.parse(readFileSync(
  new URL(
    '../../../../packages/pirc_render/test/fixtures/parity/document-contextual-fragment-chromium153.json',
    import.meta.url,
  ),
  'utf8',
));
assert.equal(contextualFragmentWebFixture.browserVersion, '153.0.8010.12');

function createRuntime() {
  const context = vm.createContext({});
  new vm.Script(bundle, { filename: 'document-script-runtime.js' }).runInContext(
    context,
    { timeout: RUN_TIMEOUT_MS }
  );
  return context;
}

function invoke(context, method, argument) {
  const expression =
    '__pircDocument.' + method + '(' + JSON.stringify(argument) + ')';
  const serialized = new vm.Script(expression).runInContext(context, {
    timeout: RUN_TIMEOUT_MS
  });
  return JSON.parse(serialized);
}


function jsonEvaluate(context, expression) {
  const value = new vm.Script('JSON.stringify(' + expression + ')').runInContext(
    context,
    { timeout: RUN_TIMEOUT_MS },
  );
  return JSON.parse(value);
}

function elementId(context, selector) {
  const expression =
    'document.querySelector(' +
    JSON.stringify(selector) +
    ').getAttribute("data-pirc-script-id")';
  return new vm.Script(expression).runInContext(context, {
    timeout: RUN_TIMEOUT_MS
  });
}

test('classic scripts mutate DOM and delegated clicks persist across dispatches', () => {
  const context = createRuntime();
  const html = [
    '<!doctype html>',
    '<html><head>',
    '<link rel="stylesheet" href="theme.css">',
    '<style>.active { color: crimson; }</style>',
    '</head><body>',
    '<button id="inline" onclick="window.inlineCount += 1; return false;">Run "猫"</button>',
    '<ul id="items"><li class="item">Start</li></ul>',
    '<div id="generated"></div>',
    '<script>',
    'window.inlineCount = 0;',
    'window.delegatedCount = 0;',
    'const output = document.querySelector("#generated");',
    'for (let index = 0; index < 3; index++) {',
    '  const row = document.createElement("p");',
    '  row.textContent = "Row " + index + " — “quoted”";',
    '  output.appendChild(row);',
    '}',
    'const list = document.querySelector("#items");',
    'list.addEventListener("click", function(event) {',
    '  if (event.target.classList.contains("item")) {',
    '    window.delegatedCount += 1;',
    '    event.target.classList.toggle("active");',
    '    event.target.style.color = "crimson";',
    '    event.preventDefault();',
    '  }',
    '});',
    'document.addEventListener("DOMContentLoaded", function() {',
    '  window.lifecycleReady = true;',
    '});',
    'window.addEventListener("load", function() {',
    '  window.lifecycleLoaded = true;',
    '});',
    '</script>',
    '</body></html>'
  ].join('\n');

  const result = invoke(context, 'init', {
    url: 'https://example.test/document',
    html
  });

  assert.equal(result.diagnostics.some((item) => item.severity === 'error'), false);
  assert.match(result.html, /href="theme\.css"/);
  assert.match(result.html, /<style[^>]*>\.active/);
  assert.doesNotMatch(result.html, /<script\b/i);
  assert.match(result.html, /Row 2 — “quoted”/);
  assert.match(result.html, /data-pirc-script-id="pirc-\d+"/);

  const renderedTags = result.html.match(/<[a-z][\w:-]*\b[^>]*>/gi) ?? [];
  assert.ok(renderedTags.length > 4);
  for (const tag of renderedTags)
    assert.match(tag, /data-pirc-script-id="pirc-\d+"/);

  assert.equal(vm.runInContext('window.lifecycleReady', context), true);
  assert.equal(vm.runInContext('window.lifecycleLoaded', context), undefined);
  const pendingStyles = result.resourceRequests.filter(item => item.kind === 'stylesheet');
  assert.equal(pendingStyles.length, 2);
  for (const request of pendingStyles)
    invoke(context, 'completeResource', {id:request.id, ok:true});
  assert.equal(vm.runInContext('window.lifecycleLoaded', context), true);

  const inlineId = elementId(context, '#inline');
  const inlineClick = invoke(context, 'dispatch', {
    id: inlineId,
    type: 'click'
  });
  assert.equal(inlineClick.defaultPrevented, true);
  assert.equal(vm.runInContext('window.inlineCount', context), 1);

  const itemId = elementId(context, '#items .item');
  const firstClick = invoke(context, 'dispatch', {
    id: itemId,
    type: 'click'
  });
  assert.equal(firstClick.defaultPrevented, true);
  assert.equal(vm.runInContext('window.delegatedCount', context), 1);
  const clickedMarkup = new vm.Script('new DOMParser().parseFromString(' + JSON.stringify(firstClick.html) + ', "text/html")').runInContext(context);
  assert.equal(clickedMarkup.querySelector('#items .item').classList.contains('active'), true);
  assert.equal(clickedMarkup.querySelector('#items .item').style.color, 'crimson');

  const secondClick = invoke(context, 'dispatch', {
    id: itemId,
    type: 'click'
  });
  assert.equal(vm.runInContext('window.delegatedCount', context), 2);
  assert.doesNotMatch(secondClick.html, /class="item active"/);
});

test('native click markers follow onclick, listeners, descendants, removal, and once', () => {
  const context = createRuntime();
  const html = [
    '<a id="link" href="#target"><span id="label">Label</span></a>',
    '<p id="plain"><b id="quiet">No handler</b></p>',
    '<button id="property">Property handler</button>',
    '<div id="inline" onclick="window.inlineCalls += 1;"><i id="inlineChild">Inline</i></div>',
    '<button id="once">Once</button>',
    '<script>',
    'window.linkCalls = 0; window.propertyCalls = 0; window.inlineCalls = 0; window.onceCalls = 0;',
    'const link = document.querySelector("#link");',
    'window.linkHandler = function(event) {',
    '  window.linkCalls += 1;',
    '  window.clickTarget = event.target.id;',
    '  window.clickCurrentTarget = event.currentTarget.id;',
    '  event.preventDefault();',
    '};',
    'link.addEventListener("click", window.linkHandler);',
    'document.querySelector("#property").onclick = function() { window.propertyCalls += 1; };',
    'document.querySelector("#once").addEventListener("click", function() { window.onceCalls += 1; }, { once: true });',
    '</script>'
  ].join('\n');

  const initialized = invoke(context, 'init', { html });
  assert.equal(initialized.diagnostics.some((item) => item.severity === 'error'), false);
  const parsed = new vm.Script(
    'new DOMParser().parseFromString(' + JSON.stringify(initialized.html) + ', "text/html")'
  ).runInContext(context);
  for (const selector of ['#link', '#label', '#property', '#inline', '#inlineChild', '#once'])
    assert.equal(parsed.querySelector(selector).hasAttribute('data-pirc-script-click'), true, selector);
  for (const selector of ['#plain', '#quiet'])
    assert.equal(parsed.querySelector(selector).hasAttribute('data-pirc-script-click'), false, selector);

  const targetClick = invoke(context, 'dispatch', {
    id: elementId(context, '#label'),
    type: 'click'
  });
  assert.equal(targetClick.defaultPrevented, true);
  assert.equal(vm.runInContext('window.linkCalls', context), 1);
  assert.equal(vm.runInContext('window.clickTarget', context), 'label');
  assert.equal(vm.runInContext('window.clickCurrentTarget', context), 'link');

  vm.runInContext('document.querySelector("#link").removeEventListener("click", window.linkHandler)', context);
  vm.runInContext('document.querySelector("#property").onclick = null', context);
  vm.runInContext('document.querySelector("#inline").removeAttribute("onclick")', context);
  const removed = invoke(context, 'snapshot', {});
  const afterRemoval = new vm.Script(
    'new DOMParser().parseFromString(' + JSON.stringify(removed.html) + ', "text/html")'
  ).runInContext(context);
  for (const selector of ['#link', '#label', '#property', '#inline', '#inlineChild'])
    assert.equal(afterRemoval.querySelector(selector).hasAttribute('data-pirc-script-click'), false, selector);

  const onceId = elementId(context, '#once');
  assert.equal(afterRemoval.querySelector('#once').hasAttribute('data-pirc-script-click'), true);
  invoke(context, 'dispatch', { id: onceId, type: 'click' });
  assert.equal(vm.runInContext('window.onceCalls', context), 1);
  const afterOnce = invoke(context, 'snapshot', {});
  const afterOnceMarkup = new vm.Script(
    'new DOMParser().parseFromString(' + JSON.stringify(afterOnce.html) + ', "text/html")'
  ).runInContext(context);
  assert.equal(afterOnceMarkup.querySelector('#once').hasAttribute('data-pirc-script-click'), false);
});

test('onclick property false cancels defaults, replaces inline handlers, and differs from addEventListener', () => {
  const context = createRuntime();
  const html = [
    '<button id="property" onclick="window.calls.push(\'attribute\'); return false;">Property</button>',
    '<button id="listener">Listener</button>',
    '<script>',
    'window.calls = [];',
    'const property = document.querySelector("#property");',
    'window.propertyHandler = function() { window.calls.push("property"); return false; };',
    'property.onclick = window.propertyHandler;',
    'document.querySelector("#listener").addEventListener("click", function() {',
    '  window.calls.push("listener"); return false;',
    '});',
    '</script>'
  ].join('\n');

  const initialized = invoke(context, 'init', { html });
  assert.equal(initialized.diagnostics.some((item) => item.severity === 'error'), false);
  assert.equal(vm.runInContext('document.querySelector("#property").onclick === window.propertyHandler', context), true);

  const propertyId = elementId(context, '#property');
  const propertyClick = invoke(context, 'dispatch', { id: propertyId, type: 'click' });
  assert.equal(propertyClick.defaultPrevented, true);
  assert.deepEqual(Array.from(vm.runInContext('window.calls', context)), ['property']);

  vm.runInContext('window.calls.length = 0', context);
  const listenerClick = invoke(context, 'dispatch', {
    id: elementId(context, '#listener'),
    type: 'click'
  });
  assert.equal(listenerClick.defaultPrevented, false);
  assert.deepEqual(Array.from(vm.runInContext('window.calls', context)), ['listener']);

  vm.runInContext(
    'document.querySelector("#property").setAttribute("onclick", "window.calls.push(\\\"attribute replacement\\\"); return false;")',
    context
  );
  vm.runInContext('window.calls.length = 0', context);
  const attributeClick = invoke(context, 'dispatch', { id: propertyId, type: 'click' });
  assert.equal(attributeClick.defaultPrevented, true);
  assert.deepEqual(Array.from(vm.runInContext('window.calls', context)), ['attribute replacement']);

  vm.runInContext('document.querySelector("#property").onclick = null', context);
  vm.runInContext('window.calls.length = 0', context);
  const nullPropertyClick = invoke(context, 'dispatch', { id: propertyId, type: 'click' });
  assert.equal(nullPropertyClick.defaultPrevented, false);
  assert.deepEqual(Array.from(vm.runInContext('window.calls', context)), []);
  assert.equal(vm.runInContext('document.querySelector("#property").onclick', context), null);
});

test('document and window delegated click listeners mark all elements and bubble from tapped child', () => {
  const context = createRuntime();
  const html = [
    '<main id="main"><section id="section"><span id="target">Tap</span></section></main>',
    '<aside id="aside">Elsewhere</aside>',
    '<script>',
    'window.delegated = [];',
    'window.onDocumentClick = function(event) { window.delegated.push("document:" + event.target.id); };',
    'window.onWindowClick = function(event) { window.delegated.push("window:" + event.target.id); };',
    'document.addEventListener("click", window.onDocumentClick);',
    'window.addEventListener("click", window.onWindowClick);',
    '</script>'
  ].join('\n');

  const initialized = invoke(context, 'init', { html });
  const markup = new vm.Script(
    'new DOMParser().parseFromString(' + JSON.stringify(initialized.html) + ', "text/html")'
  ).runInContext(context);
  for (const element of markup.querySelectorAll('html, body, main, section, span, aside'))
    assert.equal(element.hasAttribute('data-pirc-script-click'), true, element.localName + '#' + element.id);

  const clicked = invoke(context, 'dispatch', {
    id: elementId(context, '#target'),
    type: 'click'
  });
  assert.equal(clicked.defaultPrevented, false);
  assert.deepEqual(Array.from(vm.runInContext('window.delegated', context)), [
    'document:target',
    'window:target'
  ]);

  vm.runInContext('document.removeEventListener("click", window.onDocumentClick)', context);
  const windowOnly = invoke(context, 'snapshot', {});
  const windowOnlyMarkup = new vm.Script(
    'new DOMParser().parseFromString(' + JSON.stringify(windowOnly.html) + ', "text/html")'
  ).runInContext(context);
  assert.equal(windowOnlyMarkup.querySelector('#aside').hasAttribute('data-pirc-script-click'), true);
  vm.runInContext('window.removeEventListener("click", window.onWindowClick)', context);
  const noDelegates = invoke(context, 'snapshot', {});
  const noDelegatesMarkup = new vm.Script(
    'new DOMParser().parseFromString(' + JSON.stringify(noDelegates.html) + ', "text/html")'
  ).runInContext(context);
  for (const element of noDelegatesMarkup.querySelectorAll('*'))
    assert.equal(element.hasAttribute('data-pirc-script-click'), false, element.localName + '#' + element.id);
});

test('summary clicks toggle details unless prevented or targeted through an interactive child', () => {
  const context = createRuntime();
  const html = [
    '<details id="first"><summary id="summary">Text <span id="label">Label</span>',
    '<a id="link" href="#elsewhere"><span id="linkChild">Link</span></a>',
    '<button id="button"><span id="buttonChild">Button</span></button></summary></details>',
    '<details id="groupOne" name="group" open><summary id="groupSummaryOne">One</summary></details>',
    '<details id="groupTwo" name="group"><summary id="groupSummaryTwo">Two</summary></details>',
    '<details id="cancelled"><summary id="cancelledSummary" onclick="event.preventDefault()">Cancel</summary></details>'
  ].join('\n');
  const initialized = invoke(context, 'init', { html });
  assert.equal(initialized.diagnostics.some((item) => item.severity === 'error'), false);
  const markup = new vm.Script(
    'new DOMParser().parseFromString(' + JSON.stringify(initialized.html) + ', "text/html")'
  ).runInContext(context);
  assert.equal(markup.querySelector('#summary').hasAttribute('data-pirc-script-click'), true);
  assert.equal(markup.querySelector('#label').hasAttribute('data-pirc-script-click'), true);
  for (const selector of ['#link', '#linkChild', '#button', '#buttonChild'])
    assert.equal(markup.querySelector(selector).hasAttribute('data-pirc-script-click'), false, selector);

  const firstClick = invoke(context, 'dispatch', {
    id: elementId(context, '#label'),
    type: 'click'
  });
  assert.equal(firstClick.defaultPrevented, false);
  assert.equal(jsonEvaluate(context, 'document.querySelector("#first").hasAttribute("open")'), true);
  invoke(context, 'dispatch', { id: elementId(context, '#summary'), type: 'click' });
  assert.equal(jsonEvaluate(context, 'document.querySelector("#first").hasAttribute("open")'), false);

  invoke(context, 'dispatch', { id: elementId(context, '#linkChild'), type: 'click' });
  assert.equal(jsonEvaluate(context, 'document.querySelector("#first").hasAttribute("open")'), false);
  invoke(context, 'dispatch', { id: elementId(context, '#buttonChild'), type: 'click' });
  assert.equal(jsonEvaluate(context, 'document.querySelector("#first").hasAttribute("open")'), false);

  const prevented = invoke(context, 'dispatch', {
    id: elementId(context, '#cancelledSummary'),
    type: 'click'
  });
  assert.equal(prevented.defaultPrevented, true);
  assert.equal(jsonEvaluate(context, 'document.querySelector("#cancelled").hasAttribute("open")'), false);

  invoke(context, 'dispatch', { id: elementId(context, '#groupSummaryTwo'), type: 'click' });
  assert.equal(jsonEvaluate(context, 'document.querySelector("#groupOne").hasAttribute("open")'), false);
  assert.equal(jsonEvaluate(context, 'document.querySelector("#groupTwo").hasAttribute("open")'), true);
});

test('controls serialize input value, checked state, textarea value, and selected options', () => {
  const context = createRuntime();
  const html = [
    '<input id="field" value="before" checked>',
    '<textarea id="notes">old notes</textarea>',
    '<select id="choice">',
    '  <option value="a">First</option>',
    '  <option value="b">Second</option>',
    '</select>'
  ].join('\n');
  const initialized = invoke(context, 'init', { html });
  assert.equal(initialized.diagnostics.some((item) => item.severity === 'error'), false);

  const result = invoke(context, 'dispatch', {
    id: elementId(context, '#field'),
    type: 'change',
    controls: [
      {
        id: elementId(context, '#field'),
        value: 'A & "猫" &copy;',
        checked: false
      },
      {
        id: elementId(context, '#notes'),
        value: 'new notes — Δ'
      },
      {
        id: elementId(context, '#choice'),
        selectedValues: ['b']
      }
    ]
  });

  assert.match(result.html, /value="A &amp; &quot;猫&quot; &amp;copy;"/);
  assert.doesNotMatch(result.html, /<input[^>]*\schecked(?:=|\s|>)/i);
  assert.match(result.html, /<textarea[^>]*>new notes — Δ<\/textarea>/i);
  const parsed = new vm.Script('new DOMParser().parseFromString(' + JSON.stringify(result.html) + ', "text/html")').runInContext(context);
  assert.equal(parsed.querySelector('#field').value, 'A & "猫" &copy;');
  assert.equal(parsed.querySelector('option[value="b"]').selected, true);
  assert.equal(parsed.querySelector('option[value="a"]').selected, false);
});

test('input, change, and submit dispatch preserve form events and live control state', () => {
  const context = createRuntime();
  const html = [
    '<form id="form">',
    '<input id="field" value="before" oninput="document.querySelector(\'#output\').textContent = this.value + \':\' + event.inputType + \':\' + event.data + \':\' + event.isComposing;">',
    '<input id="check" type="checkbox" checked>',
    '<select id="choice"><option value="a">First</option><option value="b">Second</option></select>',
    '<button id="save" type="submit">Save</button>',
    '<output id="output"></output>',
    '</form>',
    '<input id="external" form="form" value="outside">',
    '<script>',
    'const form = document.querySelector("#form");',
    'window.formElementsAtInit = Array.from(form.elements, element => element.id);',
    'form.addEventListener("input", function(event) {',
    '  const controls = Array.from(form.elements);',
    '  const field = controls.find(element => element.id === "field");',
    '  const check = controls.find(element => element.id === "check");',
    '  const choice = controls.find(element => element.id === "choice");',
    '  window.inputState = {',
    '    target: event.target.id, data: event.data, inputType: event.inputType,',
    '    isComposing: event.isComposing, cancelable: event.cancelable,',
    '    value: field.value, checked: check.checked, selected: choice.value,',
    '    output: document.querySelector("#output").textContent,',
    '    ids: controls.map(element => element.id)',
    '  };',
    '  event.preventDefault();',
    '  window.inputState.defaultPreventedAfter = event.defaultPrevented;',
    '});',
    'form.addEventListener("change", function(event) {',
    '  const controls = Array.from(form.elements);',
    '  window.changeState = {',
    '    target: event.target.id, cancelable: event.cancelable,',
    '    checked: controls.find(element => element.id === "check").checked,',
    '    selected: controls.find(element => element.id === "choice").value',
    '  };',
    '  event.preventDefault();',
    '  window.changeState.defaultPreventedAfter = event.defaultPrevented;',
    '});',
    'form.addEventListener("submit", function(event) {',
    '  window.submitState = {',
    '    target: event.target.id, submitter: event.submitter && event.submitter.id,',
    '    isExpectedSubmitter: event.submitter === document.querySelector("#save"),',
    '    cancelable: event.cancelable',
    '  };',
    '  event.preventDefault();',
    '});',
    '</script>'
  ].join('\n');
  const initialized = invoke(context, 'init', { html });
  assert.equal(initialized.diagnostics.some((item) => item.severity === 'error'), false, JSON.stringify(initialized.diagnostics));
  assert.deepEqual(Array.from(vm.runInContext('window.formElementsAtInit', context)), [
    'field', 'check', 'choice', 'save', 'output', 'external'
  ]);

  const input = invoke(context, 'dispatch', {
    id: elementId(context, '#field'),
    type: 'input',
    data: 'x',
    inputType: 'insertText',
    isComposing: true,
    controls: [{
      id: elementId(context, '#field'),
      value: 'new & "猫"'
    }]
  });
  assert.equal(input.defaultPrevented, false);
  const inputState = vm.runInContext('window.inputState', context);
  assert.equal(inputState.target, 'field');
  assert.equal(inputState.data, 'x');
  assert.equal(inputState.inputType, 'insertText');
  assert.equal(inputState.isComposing, true);
  assert.equal(inputState.cancelable, false);
  assert.equal(inputState.defaultPreventedAfter, false);
  assert.equal(inputState.value, 'new & "猫"');
  assert.equal(inputState.output, 'new & "猫":insertText:x:true');
  assert.ok(inputState.ids.includes('external'));
  const inputMarkup = new vm.Script(
    'new DOMParser().parseFromString(' + JSON.stringify(input.html) + ', "text/html")'
  ).runInContext(context);
  assert.equal(inputMarkup.querySelector('#output').textContent, 'new & "猫":insertText:x:true');

  const change = invoke(context, 'dispatch', {
    id: elementId(context, '#choice'),
    type: 'change',
    controls: [
      { id: elementId(context, '#check'), checked: false },
      { id: elementId(context, '#choice'), selectedValues: ['b'] }
    ]
  });
  assert.equal(change.defaultPrevented, false);
  const changeState = JSON.parse(
    vm.runInContext('JSON.stringify(window.changeState)', context)
  );
  assert.deepEqual(changeState, {
    target: 'choice',
    cancelable: false,
    checked: false,
    selected: 'b',
    defaultPreventedAfter: false
  });

  const submitted = invoke(context, 'dispatch', {
    id: elementId(context, '#form'),
    type: 'submit',
    submitter: elementId(context, '#save')
  });
  assert.equal(submitted.defaultPrevented, true);
  const submitState = JSON.parse(
    vm.runInContext('JSON.stringify(window.submitState)', context)
  );
  assert.deepEqual(submitState, {
    target: 'form',
    submitter: 'save',
    isExpectedSubmitter: true,
    cancelable: true
  });
  assert.equal(submitted.defaultHandled, true);
  assert.deepEqual(submitted.formActions, []);
});

test('form.submit skips validation and submit events while freezing current entries', () => {
  const context = createRuntime();
  const initialized = invoke(context, 'init', {
    url: 'https://example.test/start',
    html: [
      '<form id="form" action="/go" method="post">',
      '<input id="required" name="query" required value="before">',
      '<button id="submitter" type="submit" name="intent" value="send">Send</button>',
      '</form>',
      '<script>',
      'window.formEvents = [];',
      'const form = document.querySelector("#form");',
      'const input = document.querySelector("#required");',
      'form.addEventListener("invalid", () => window.formEvents.push("invalid"));',
      'form.addEventListener("submit", () => window.formEvents.push("submit"));',
      'window.formIsFormElement = form instanceof HTMLFormElement;',
      'window.createdFormIsFormElement = document.createElement("form") instanceof HTMLFormElement;',
      'form.submit();',
      'window.formEventsAfterCall = window.formEvents.slice();',
      'input.value = "after";',
      '</script>'
    ].join('\n')
  });

  assert.equal(initialized.diagnostics.some((item) => item.severity === 'error'), false, JSON.stringify(initialized.diagnostics));
  assert.equal(vm.runInContext('window.formIsFormElement', context), true);
  assert.equal(vm.runInContext('window.createdFormIsFormElement', context), true);
  assert.deepEqual(Array.from(vm.runInContext('window.formEventsAfterCall', context)), []);
  assert.equal(initialized.formActions.length, 1);
  assert.equal(initialized.formActions[0].kind, 'submit');
  assert.equal(initialized.formActions[0].submitterId, null);
  assert.deepEqual(initialized.formActions[0].entries, [
    { name: 'query', value: 'before' }
  ]);
});

test('requestSubmit synchronously validates, dispatches SubmitEvent, captures overrides, and preserves explicit submit()', () => {
  const context = createRuntime();
  const initialized = invoke(context, 'init', {
    url: 'https://example.test/docs/start',
    html: [
      '<form id="form" action="/default" method="get">',
      '<input id="message" name="message" required value="frozen">',
      '<button id="send" type="submit" name="intent" value="send"',
      ' formaction="/override" formmethod="post"',
      ' formenctype="text/plain" formtarget="resultWindow">Send</button>',
      '</form>',
      '<input id="url" type="url" value="https://example.test/path">',
      '<script>',
      'window.submissionOrder = []; window.submitDetails = null;',
      'const form = document.querySelector("#form");',
      'const message = document.querySelector("#message");',
      'const send = document.querySelector("#send");',
      'const url = document.querySelector("#url");',
      'window.urlValidation = [url.validity.valid]; url.value = "/relative"; window.urlValidation.push(url.validity.typeMismatch);',
      'window.actionProperties = [form.action, send.formAction, typeof URL, typeof URLSearchParams, new URLSearchParams("a=1").get("a")];',
      'form.addEventListener("submit", function(event) {',
      '  window.submissionOrder.push("submit");',
      '  window.submitDetails = {',
      '    instance: event instanceof SubmitEvent, target: event.target.id,',
      '    submitter: event.submitter && event.submitter.id,',
      '    bubbles: event.bubbles, cancelable: event.cancelable',
      '  };',
      '});',
      'form.requestSubmit(send);',
      'window.submissionOrder.push("after-call");',
      'message.value = "changed after requestSubmit";',
      '</script>'
    ].join('\n')
  });

  assert.equal(initialized.diagnostics.some((item) => item.severity === 'error'), false, JSON.stringify(initialized.diagnostics));
  assert.deepEqual(Array.from(vm.runInContext('window.submissionOrder', context)), [
    'submit', 'after-call'
  ]);
  assert.deepEqual(JSON.parse(vm.runInContext('JSON.stringify(window.submitDetails)', context)), {
    instance: true,
    target: 'form',
    submitter: 'send',
    bubbles: true,
    cancelable: true
  });
  assert.deepEqual(Array.from(vm.runInContext('window.actionProperties', context)), [
    'https://example.test/default',
    'https://example.test/override',
    'function',
    'function',
    '1'
  ]);
  assert.deepEqual(Array.from(vm.runInContext('window.urlValidation', context)), [true, true]);
  assert.equal(initialized.formActions.length, 1);
  assert.deepEqual(initialized.formActions[0], {
    kind: 'submit',
    actionOrder: 1,
    formId: elementId(context, '#form'),
    action: '/override',
    method: 'post',
    enctype: 'text/plain',
    target: 'resultWindow',
    targetSpecified: true,
    submitterId: 'send',
    entries: [
      { name: 'message', value: 'frozen' },
      { name: 'intent', value: 'send' }
    ]
  });

  const cancelled = createRuntime();
  const cancelledResult = invoke(cancelled, 'init', {
    html: '<form id="f"><input name="q" value="x"><button id="b" name="intent" value="send">Send</button><script>' +
      'const f=document.querySelector("#f"); const b=document.querySelector("#b");' +
      'f.addEventListener("submit", e => { f.submit(); e.preventDefault(); });' +
      'f.requestSubmit(b);</script></form>'
  });
  assert.equal(cancelledResult.formActions.length, 1);
  assert.deepEqual(cancelledResult.formActions[0].entries, [
    { name: 'q', value: 'x' }
  ]);
  assert.equal(cancelledResult.formActions[0].submitterId, null);
});

test('requestSubmit invalid path emits invalid actions and submit cancellation blocks default', () => {
  const invalidContext = createRuntime();
  const invalid = invoke(invalidContext, 'init', {
    html: '<form id="f"><input id="required" name="q" required>' +
      '<button id="send">Send</button><script>' +
      'window.invalidEvents=[]; const f=document.querySelector("#f");' +
      'const field=document.querySelector("#required");' +
      'field.addEventListener("invalid", e => window.invalidEvents.push([' +
      'e.bubbles,e.cancelable,e.defaultPrevented]));' +
      'f.addEventListener("submit", () => window.invalidEvents.push("submit"));' +
      'f.requestSubmit();</script></form>'
  });
  assert.deepEqual(JSON.parse(vm.runInContext('JSON.stringify(window.invalidEvents)', invalidContext)), [
    [false, true, false]
  ]);
  assert.equal(invalid.formActions.some((action) => action.kind === 'submit'), false);
  assert.deepEqual(invalid.formActions.filter((action) => action.kind === 'invalid').map((action) => ({
    formId: action.formId,
    controlId: action.controlId,
    message: action.message
  })), [{
    formId: elementId(invalidContext, '#f'),
    controlId: elementId(invalidContext, '#required'),
    message: 'Please fill out this field.'
  }]);

  const cancelledContext = createRuntime();
  const cancelled = invoke(cancelledContext, 'init', {
    html: '<form id="f"><input name="q" value="x"><script>' +
      'const f=document.querySelector("#f");' +
      'f.addEventListener("submit", e => e.preventDefault());' +
      'f.requestSubmit();</script></form>'
  });
  assert.deepEqual(cancelled.formActions, []);
});

test('host requestSubmit validates synchronously; validated host submit does not revalidate', () => {
  const context = createRuntime();
  const initialized = invoke(context, 'init', {
    html: '<form id="f"><input id="q" name="q" required>' +
      '<button id="send" name="intent" value="go">Send</button>' +
      '<script>window.events=[]; const f=document.querySelector("#f");' +
      'document.querySelector("#q").addEventListener("invalid", () => window.events.push("invalid"));' +
      'f.addEventListener("submit", e => window.events.push("submit:" + (e.submitter && e.submitter.id)));' +
      '</script></form>'
  });
  assert.equal(initialized.diagnostics.some((item) => item.severity === 'error'), false);
  const formId = elementId(context, '#f');
  const fieldId = elementId(context, '#q');
  const submitterId = elementId(context, '#send');
  const invalid = invoke(context, 'dispatch', {
    id: formId,
    type: 'requestSubmit',
    submitter: submitterId
  });
  assert.equal(invalid.defaultHandled, true);
  assert.equal(invalid.defaultPrevented, false);
  assert.deepEqual(Array.from(vm.runInContext('window.events', context)), ['invalid']);
  assert.equal(invalid.formActions.some((action) => action.kind === 'submit'), false);

  const submitted = invoke(context, 'dispatch', {
    id: formId,
    type: 'submit',
    submitter: submitterId
  });
  assert.equal(submitted.defaultHandled, true);
  assert.equal(submitted.defaultPrevented, false);
  assert.deepEqual(Array.from(vm.runInContext('window.events', context)), [
    'invalid', 'submit:send'
  ]);
  assert.equal(submitted.formActions.length, 1);
  assert.deepEqual(submitted.formActions[0].entries, [
    { name: 'q', value: '' },
    { name: 'intent', value: 'go' }
  ]);

  const buttonContext = createRuntime();
  invoke(buttonContext, 'init', {
    html: '<form id="f"><input name="q" value="x"><button id="send" name="intent" value="go">Send</button>' +
      '<script>window.submitCount=0;document.querySelector("#f").addEventListener("submit",()=>window.submitCount++);</script></form>'
  });
  const click = invoke(buttonContext, 'dispatch', {
    id: elementId(buttonContext, '#send'),
    type: 'click'
  });
  assert.equal(click.defaultHandled, true);
  assert.equal(click.formActions.length, 1);
  assert.equal(vm.runInContext('window.submitCount', buttonContext), 1);
});

test('submit click default follows button type, disabled, and form mutations in onclick', () => {
  function clickAfter(handler) {
    const context = createRuntime();
    invoke(context, 'init', {
      html: '<form id="form"><input id="field" name="q" value="default">' +
        '<button id="button" type="submit" onclick="' + handler + '">Go</button></form>' +
        '<script>window.submits=0;window.resets=0;const form=document.querySelector("#form");' +
        'form.addEventListener("submit",e=>{e.preventDefault();window.submits++});' +
        'form.addEventListener("reset",()=>window.resets++);</script>'
    });
    const result = invoke(context, 'dispatch', {
      id: elementId(context, '#button'),
      type: 'click',
      controls: [{ id: elementId(context, '#field'), value: 'edited' }]
    });
    return { context, result };
  }

  const asButton = clickAfter("this.type='button'");
  assert.equal(asButton.result.defaultHandled, true);
  assert.deepEqual(asButton.result.formActions, []);
  assert.equal(vm.runInContext('window.submits', asButton.context), 0);
  assert.equal(vm.runInContext('window.resets', asButton.context), 0);
  assert.equal(vm.runInContext('document.querySelector("#field").value', asButton.context), 'edited');

  const asReset = clickAfter("this.type='reset'");
  assert.equal(asReset.result.defaultHandled, true);
  assert.deepEqual(asReset.result.formActions, []);
  assert.equal(vm.runInContext('window.submits', asReset.context), 0);
  assert.equal(vm.runInContext('window.resets', asReset.context), 1);
  assert.equal(vm.runInContext('document.querySelector("#field").value', asReset.context), 'default');

  const disabled = clickAfter('this.disabled=true');
  assert.equal(disabled.result.defaultHandled, true);
  assert.deepEqual(disabled.result.formActions, []);
  assert.equal(vm.runInContext('window.submits', disabled.context), 0);
  assert.equal(vm.runInContext('document.querySelector("#button").disabled', disabled.context), true);

  const removed = clickAfter('this.form.remove()');
  assert.equal(removed.result.defaultHandled, true);
  assert.deepEqual(removed.result.formActions, []);
  assert.equal(vm.runInContext('window.submits', removed.context), 0);
  assert.equal(vm.runInContext('document.querySelector("#form")', removed.context), null);
});

test('form requestSubmit argument errors and validation bypass flags follow form attributes', () => {
  const context = createRuntime();
  const initialized = invoke(context, 'init', {
    html: '<form id="f"><input id="required" name="q" required>' +
      '<button id="skip" formnovalidate name="intent" value="skip">Skip</button>' +
      '<button id="other" type="button">Other</button></form>' +
      '<script>window.errors=[]; const f=document.querySelector("#f");' +
      'for (const value of [document.querySelector("#required"), document.querySelector("#other"), null]) {' +
      ' try { f.requestSubmit(value); } catch(e) { window.errors.push(e.name); }' +
      '}' +
      'f.requestSubmit(document.querySelector("#skip"));' +
      '</script>'
  });
  assert.deepEqual(Array.from(vm.runInContext('window.errors', context)), [
    'TypeError', 'TypeError', 'TypeError'
  ]);
  assert.equal(initialized.formActions.length, 1);
  assert.equal(initialized.formActions[0].submitterId, 'skip');
  assert.equal(initialized.formActions[0].entries.some((entry) => entry.name === 'intent'), true);

  const foreign = createRuntime();
  const foreignResult = invoke(foreign, 'init', {
    html: '<form id="one"><button id="oneButton">One</button></form>' +
      '<form id="two"><button id="twoButton">Two</button><script>' +
      'window.foreignError=""; try { document.querySelector("#two").requestSubmit(document.querySelector("#oneButton")); }' +
      'catch(error) { window.foreignError=error.name; }</script></form>'
  });
  assert.equal(foreignResult.diagnostics.some((item) => item.severity === 'error'), false);
  assert.equal(vm.runInContext('window.foreignError', foreign), 'NotFoundError');
});

test('number, date, and range values are sanitized before constraint validation reads them', () => {
  const context = createRuntime();
  const initialized = invoke(context, 'init', {
    html: '<form id="f"><input id="number" type="number" required>' +
      '<input id="date" type="date" required>' +
      '<input id="range" type="range" min="1" max="5" step="2" value="4">' +
      '<script>const number=document.querySelector("#number");' +
      'const date=document.querySelector("#date");' +
      'const range=document.querySelector("#range");' +
      'number.value="oops"; date.value="2025-02-30"; range.value="4";' +
      'window.sanitizedValues=[number.value,date.value,range.value];' +
      'window.validities=[number.validity.valueMissing,date.validity.valueMissing];' +
      '</script></form>'
  });
  assert.equal(initialized.diagnostics.some((item) => item.severity === 'error'), false, JSON.stringify(initialized.diagnostics));
  assert.deepEqual(Array.from(vm.runInContext('window.sanitizedValues', context)), ['', '', '5']);
  assert.deepEqual(Array.from(vm.runInContext('window.validities', context)), [true, true]);
});

test('checkbox and radio clicks run activation, cancellation rollback, and followup events', () => {
  const context = createRuntime();
  const html = [
    '<form id="formOne">',
    '<input id="radioA" type="radio" name="group" checked>',
    '<input id="radioB" type="radio" name="group">',
    '</form>',
    '<form id="formTwo"><input id="radioC" type="radio" name="group"></form>',
    '<input id="check" type="checkbox">',
    '<input id="disabled" type="checkbox" disabled>',
    '<fieldset disabled><legend><input id="legendCheck" type="checkbox"></legend>',
    '<input id="fieldsetCheck" type="checkbox"></fieldset>',
    '<script>',
    'window.events = []; window.cancelCheck = false; window.cancelRadio = false;',
    'window.mutateCheck = false; window.selectRadioA = false;',
    'for (const id of ["check", "radioA", "radioB", "radioC", "disabled", "legendCheck", "fieldsetCheck"]) {',
    '  const input = document.querySelector("#" + id);',
    '  input.addEventListener("click", function(event) {',
    '    window.events.push("click:" + id + ":" + this.checked + ":" +',
    '      document.querySelector("#radioA").checked + ":" +',
    '      document.querySelector("#radioB").checked + ":" +',
    '      document.querySelector("#radioC").checked);',
    '    if (id === "check" && window.cancelCheck) event.preventDefault();',
    '    if (id === "check" && window.mutateCheck) this.checked = false;',
    '    if ((id === "radioA" || id === "radioB") && window.cancelRadio) event.preventDefault();',
    '    if (id === "radioB" && window.selectRadioA) document.querySelector("#radioA").checked = true;',
    '  });',
    '  input.addEventListener("input", function() { window.events.push("input:" + id + ":" + this.checked); });',
    '  input.addEventListener("change", function() { window.events.push("change:" + id + ":" + this.checked); });',
    '}',
    '</script>'
  ].join('\n');
  const initialized = invoke(context, 'init', { html });
  assert.equal(initialized.diagnostics.some((item) => item.severity === 'error'), false);
  const id = (selector) => elementId(context, selector);
  const dispatchClick = (selector) => invoke(context, 'dispatch', {
    id: id(selector),
    type: 'click'
  });
  const events = () => Array.from(vm.runInContext('window.events', context));
  const clearEvents = () => vm.runInContext('window.events.length = 0', context);

  const checkboxOn = dispatchClick('#check');
  assert.equal(checkboxOn.defaultPrevented, false);
  assert.deepEqual(events(), [
    'click:check:true:true:false:false',
    'input:check:true',
    'change:check:true'
  ]);
  clearEvents();

  const checkboxOff = dispatchClick('#check');
  assert.equal(checkboxOff.defaultPrevented, false);
  assert.deepEqual(events(), [
    'click:check:false:true:false:false',
    'input:check:false',
    'change:check:false'
  ]);
  clearEvents();

  vm.runInContext('window.cancelCheck = true', context);
  const cancelledCheckbox = dispatchClick('#check');
  assert.equal(cancelledCheckbox.defaultPrevented, true);
  assert.equal(vm.runInContext('document.querySelector("#check").checked', context), false);
  assert.deepEqual(events(), ['click:check:true:true:false:false']);
  clearEvents();

  vm.runInContext('window.cancelCheck = false; window.mutateCheck = true', context);
  dispatchClick('#check');
  assert.deepEqual(events(), [
    'click:check:true:true:false:false',
    'input:check:false',
    'change:check:false'
  ]);
  assert.equal(vm.runInContext('document.querySelector("#check").checked', context), false);
  clearEvents();

  vm.runInContext('window.mutateCheck = false', context);
  const selectedRadio = dispatchClick('#radioB');
  assert.equal(selectedRadio.defaultPrevented, false);
  assert.deepEqual(events(), [
    'click:radioB:true:false:true:false',
    'input:radioB:true',
    'change:radioB:true'
  ]);
  clearEvents();

  dispatchClick('#radioB');
  assert.deepEqual(events(), ['click:radioB:true:false:true:false']);
  clearEvents();

  vm.runInContext('window.cancelRadio = true', context);
  const cancelledRadio = dispatchClick('#radioA');
  assert.equal(cancelledRadio.defaultPrevented, true);
  assert.deepEqual(events(), ['click:radioA:true:true:false:false']);
  assert.equal(vm.runInContext('document.querySelector("#radioA").checked', context), false);
  assert.equal(vm.runInContext('document.querySelector("#radioB").checked', context), true);
  clearEvents();

  // Script assignments use the same radio-group setter as user activation.
  vm.runInContext('window.cancelRadio = false; document.querySelector("#radioA").checked = true', context);
  assert.equal(vm.runInContext('document.querySelector("#radioA").checked', context), true);
  assert.equal(vm.runInContext('document.querySelector("#radioB").checked', context), false);
  assert.equal(vm.runInContext('document.querySelector("#radioC").checked', context), false);
  vm.runInContext('document.querySelector("#radioC").checked = true', context);
  assert.equal(vm.runInContext('document.querySelector("#radioA").checked', context), true);
  assert.equal(vm.runInContext('document.querySelector("#radioC").checked', context), true);

  vm.runInContext('window.selectRadioA = true', context);
  dispatchClick('#radioB');
  assert.deepEqual(events(), [
    'click:radioB:true:false:true:true',
    'input:radioB:false',
    'change:radioB:false'
  ]);
  assert.equal(vm.runInContext('document.querySelector("#radioA").checked', context), true);
  assert.equal(vm.runInContext('document.querySelector("#radioB").checked', context), false);
  assert.equal(vm.runInContext('document.querySelector("#radioC").checked', context), true);
  clearEvents();

  const disabledClick = dispatchClick('#disabled');
  assert.equal(disabledClick.defaultPrevented, false);
  assert.deepEqual(events(), []);
  assert.equal(vm.runInContext('document.querySelector("#disabled").checked', context), false);
  const fieldsetDisabledClick = dispatchClick('#fieldsetCheck');
  assert.equal(fieldsetDisabledClick.defaultPrevented, false);
  assert.deepEqual(events(), []);
  assert.equal(vm.runInContext('document.querySelector("#fieldsetCheck").checked', context), false);

  const legendClick = dispatchClick('#legendCheck');
  assert.equal(legendClick.defaultPrevented, false);
  assert.deepEqual(events(), [
    'click:legendCheck:true:true:false:true',
    'input:legendCheck:true',
    'change:legendCheck:true'
  ]);
});

test('unknown nodes are rejected and script/API failures stay visible in diagnostics', async () => {
  const context = createRuntime();
  const html = [
    '<button id="target">go</button>',
    '<script type="module">window.moduleDidRun = true;</script>',
    '<script id="external" src="remote.js" crossorigin="" integrity="sha256-x" referrerpolicy="no-referrer"',
    ' onload="window.externalLoadEvent = true;"></script>',
    '<script>window.inlineAfterExternal = true;</script>'
  ].join('\n');
  const initialized = invoke(context, 'init', {
    url: 'https://example.test/docs/page',
    html
  });

  const codes = initialized.diagnostics.map((item) => item.code);
  assert.ok(codes.includes('runtime.capability_limit'));
  assert.ok(!codes.includes('script.module_unsupported'));
  assert.equal(initialized.resourceRequests.length, 1);
  assert.deepEqual(initialized.resourceRequests[0], {
    id: 'script-1',
    kind: 'script',
    url: 'https://example.test/docs/remote.js',
    type: '',
    crossOrigin: '',
    integrity: 'sha256-x',
    referrerPolicy: 'no-referrer'
  });
  assert.equal(vm.runInContext('window.moduleDidRun', context), undefined);
  assert.equal(vm.runInContext('window.inlineAfterExternal', context), undefined);
  assert.equal(vm.runInContext('document.readyState', context), 'loading');
  assert.equal(vm.runInContext('document.currentScript', context), null);

  const completed = invoke(context, 'completeResource', {
    id: 'script-1',
    ok: true,
    url: 'https://example.test/docs/remote.js',
    source: [
      'window.externalCurrentScript = document.currentScript === document.querySelector("#external");',
      'window.externalReadyState = document.readyState;'
    ].join('\n')
  });
  assert.deepEqual(completed.resourceRequests, []);
  assert.equal(vm.runInContext('window.externalCurrentScript', context), true);
  assert.equal(vm.runInContext('window.externalReadyState', context), 'loading');
  assert.equal(vm.runInContext('window.externalLoadEvent', context), true);
  assert.equal(vm.runInContext('window.inlineAfterExternal', context), true);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(vm.runInContext('window.moduleDidRun', context), true);
  assert.equal(vm.runInContext('document.readyState', context), 'complete');

  const ignored = invoke(context, 'completeResource', {
    id: 'script-1',
    ok: true,
    source: 'window.duplicateCompletion = true;'
  });
  assert.equal(ignored.resourceIgnored, true);
  assert.equal(vm.runInContext('window.duplicateCompletion', context), undefined);

  const rejected = invoke(context, 'dispatch', {
    id: 'missing-node',
    type: 'click'
  });
  assert.equal(rejected.error, 'unknown_element');
  assert.equal(rejected.defaultPrevented, true);
});

test('parser-blocking external scripts resume the parser and allocate later requests once', () => {
  const context = createRuntime();
  const initialized = invoke(context, 'init', {
    url: 'https://example.test/app/',
    html: [
      '<script src="first.js"></script>',
      '<script>window.parserOrder.push("after-first");</script>',
      '<script src="second.js"></script>',
      '<script>window.parserOrder.push("after-second");</script>'
    ].join('\n')
  });

  assert.deepEqual(initialized.resourceRequests.map((request) => request.id), ['script-1']);
  assert.equal(vm.runInContext('window.parserOrder', context), undefined);
  const first = invoke(context, 'completeResource', {
    id: 'script-1',
    ok: true,
    source: 'window.parserOrder = ["first"];'
  });
  assert.deepEqual(first.resourceRequests.map((request) => request.url), [
    'https://example.test/app/second.js'
  ]);
  assert.deepEqual(Array.from(vm.runInContext('window.parserOrder', context)), [
    'first',
    'after-first'
  ]);
  const second = invoke(context, 'completeResource', {
    id: 'script-2',
    ok: true,
    source: 'window.parserOrder.push("second");'
  });
  assert.deepEqual(second.resourceRequests, []);
  assert.deepEqual(Array.from(vm.runInContext('window.parserOrder', context)), [
    'first',
    'after-first',
    'second',
    'after-second'
  ]);
  assert.equal(vm.runInContext('document.readyState', context), 'complete');
});

test('defer waits for ordered completion, async does not delay DOMContentLoaded, and load waits for both', () => {
  const context = createRuntime();
  const initialized = invoke(context, 'init', {
    url: 'https://example.test/page',
    html: [
      '<script async src="/async.js"></script>',
      '<script defer src="/defer.js"></script>',
      '<script>',
      'window.lifecycleOrder = [];',
      'document.addEventListener("DOMContentLoaded", function() {',
      '  lifecycleOrder.push("dom:" + document.readyState);',
      '});',
      'window.addEventListener("load", function() {',
      '  lifecycleOrder.push("load:" + document.readyState);',
      '});',
      '</script>'
    ].join('\n')
  });

  assert.deepEqual(initialized.resourceRequests.map((request) => request.url), [
    'https://example.test/async.js',
    'https://example.test/defer.js'
  ]);
  assert.equal(vm.runInContext('document.readyState', context), 'interactive');
  assert.equal(vm.runInContext('window.lifecycleOrder.length', context), 0);

  const deferred = invoke(context, 'completeResource', {
    id: 'script-2',
    ok: true,
    source: 'lifecycleOrder.push("defer:" + (document.currentScript !== null));'
  });
  assert.deepEqual(deferred.resourceRequests, []);
  assert.deepEqual(Array.from(vm.runInContext('window.lifecycleOrder', context)), [
    'defer:true',
    'dom:interactive'
  ]);
  assert.equal(vm.runInContext('document.readyState', context), 'interactive');

  invoke(context, 'completeResource', {
    id: 'script-1',
    ok: true,
    source: 'lifecycleOrder.push("async:" + (document.currentScript !== null));'
  });
  assert.deepEqual(Array.from(vm.runInContext('window.lifecycleOrder', context)), [
    'defer:true',
    'dom:interactive',
    'async:true',
    'load:complete'
  ]);
  assert.equal(vm.runInContext('document.readyState', context), 'complete');
});

test('failed parser-blocking external scripts fire error and do not stop later scripts', () => {
  const context = createRuntime();
  const initialized = invoke(context, 'init', {
    url: 'https://example.test/page',
    html: [
      '<script>window.failedEvents = []; document.querySelector("#bad").addEventListener("error", function() { failedEvents.push("error"); });</script>',
      '<script id="bad" src="/bad.js"></script>',
      '<script>window.afterFailedScript = true;</script>'
    ].join('\n')
  });
  assert.equal(vm.runInContext('window.afterFailedScript', context), undefined);

  const failed = invoke(context, 'completeResource', {
    id: initialized.resourceRequests[0].id,
    ok: false,
    error: 'HTTP 404'
  });
  assert.deepEqual(failed.resourceRequests, []);
  assert.deepEqual(Array.from(vm.runInContext('window.failedEvents', context)), ['error']);
  assert.equal(vm.runInContext('window.afterFailedScript', context), true);
  assert.equal(vm.runInContext('document.readyState', context), 'complete');
  assert.ok(failed.diagnostics.some((item) => item.code === 'script.external_load_error'));
});

test('dynamically inserted classic external scripts execute after host completion', () => {
  const context = createRuntime();
  const initialized = invoke(context, 'init', {
    url: 'https://example.test/page',
    html: [
      '<script>',
      'window.dynamicScriptEvents = [];',
      'const script = document.createElement("script");',
      'script.id = "dynamic";',
      'script.onload = function() { dynamicScriptEvents.push("load"); };',
      'script.onerror = function() { dynamicScriptEvents.push("error"); };',
      'script.src = "/dynamic.js";',
      'document.body.appendChild(script);',
      'const changed = document.createElement("script");',
      'changed.id = "changed";',
      'document.body.appendChild(changed);',
      'changed.src = "/changed.js";',
      '</script>'
    ].join('\n')
  });

  assert.equal(initialized.resourceRequests.length, 2);
  assert.equal(initialized.resourceRequests[0].id, 'script-1');
  assert.equal(initialized.resourceRequests[0].url, 'https://example.test/dynamic.js');
  assert.equal(initialized.resourceRequests[1].id, 'script-2');
  assert.equal(initialized.resourceRequests[1].url, 'https://example.test/changed.js');
  assert.deepEqual(Array.from(vm.runInContext('window.dynamicScriptEvents', context)), []);
  assert.equal(vm.runInContext('document.readyState', context), 'interactive');

  invoke(context, 'completeResource', {
    id: 'script-1',
    ok: true,
    source: 'window.dynamicCurrentScript = document.currentScript === document.querySelector("#dynamic");'
  });
  assert.equal(vm.runInContext('window.dynamicCurrentScript', context), true);
  assert.equal(vm.runInContext('document.readyState', context), 'interactive');
  invoke(context, 'completeResource', {
    id: 'script-2',
    ok: true,
    source: 'window.changedCurrentScript = document.currentScript === document.querySelector("#changed");'
  });
  assert.equal(vm.runInContext('window.changedCurrentScript', context), true);
  assert.deepEqual(Array.from(vm.runInContext('window.dynamicScriptEvents', context)), ['load']);
  assert.equal(vm.runInContext('document.readyState', context), 'complete');
});

test('Range.createContextualFragment connects ordinary HTML scripts and handlers like Chromium', () => {
  const context = createRuntime();
  invoke(context, 'init', {
    hostLayout: true,
    url: 'https://example.test/page',
    html: '<div id="host"></div>'
  });
  const markup = '<script>window.fragmentRuns += 1<' + '/script>' +
    '<button id="fragment-button" onclick="window.fragmentRuns += 10">Go</button>';
  const actual = jsonEvaluate(context, `(() => {
    const host = document.querySelector('#host');
    const range = document.createRange();
    range.selectNodeContents(host);
    window.fragmentRuns = 0;
    const fragment = range.createContextualFragment(${JSON.stringify(markup)});
    const beforeConnect = window.fragmentRuns;
    host.appendChild(fragment);
    const afterConnect = window.fragmentRuns;
    document.querySelector('#fragment-button').click();
    const afterClick = window.fragmentRuns;
    const script = host.querySelector('script');
    script.remove();
    host.appendChild(script);
    return {
      beforeConnect, afterConnect, afterClick,
      afterMove: window.fragmentRuns,
      rangeContextTag: range.commonAncestorContainer.localName,
      fragmentEmptied: fragment.childNodes.length === 0,
    };
  })()`);
  assert.deepEqual(actual, contextualFragmentWebFixture.html);
});

test('Range.createContextualFragment parses ordinary table rows like Chromium', () => {
  const context = createRuntime();
  invoke(context, 'init', {
    hostLayout: true,
    url: 'https://example.test/page',
    html: '<table><tbody id="host"></tbody></table>'
  });
  const actual = jsonEvaluate(context, `(() => {
    const host = document.querySelector('#host');
    const range = document.createRange();
    range.selectNodeContents(host);
    const child = range.createContextualFragment('<tr><td>Cell</td></tr>').firstChild;
    return { tag: child.localName, namespace: child.namespaceURI, text: child.textContent };
  })()`);
  assert.deepEqual(actual, contextualFragmentWebFixture.table);
});

test('SVG contextual fragments keep Chromium namespace and live owner', () => {
  const context = createRuntime();
  invoke(context, 'init', {
    hostLayout: true,
    url: 'https://example.test/page',
    html: '<svg id="host" xmlns="http://www.w3.org/2000/svg"><foreignObject id="foreign"></foreignObject></svg>'
  });
  const simple = jsonEvaluate(context, `(() => {
    const range = document.createRange();
    range.selectNodeContents(document.querySelector('#host'));
    const child = range.createContextualFragment('<circle cx="10" cy="10" r="5"/>').firstChild;
    return { tag: child.localName, namespace: child.namespaceURI };
  })()`);
  assert.deepEqual(simple, contextualFragmentWebFixture.svg);
  const nested = jsonEvaluate(context, `(() => {
    const host = document.querySelector('#host');
    const range = document.createRange();
    range.selectNodeContents(host);
    const fragment = range.createContextualFragment(
      '<g id="group"><circle id="circle" cx="10"/></g>');
    const group = fragment.firstChild;
    const circle = group.firstChild;
    const beforeOwner = [group.ownerSVGElement?.id || null, circle.ownerSVGElement?.id || null];
    host.appendChild(fragment);
    const afterOwner = [group.ownerSVGElement?.id || null, circle.ownerSVGElement?.id || null];
    const foreign = document.querySelector('#foreign');
    const foreignRange = document.createRange();
    foreignRange.selectNodeContents(foreign);
    const htmlChild = foreignRange.createContextualFragment('<div>Text</div>').firstChild;
    return {
      beforeOwner, afterOwner,
      namespaces: [group.namespaceURI, circle.namespaceURI, htmlChild.namespaceURI],
      foreignTag: htmlChild.localName,
    };
  })()`);
  assert.deepEqual(nested, contextualFragmentWebFixture.svgNested);
});

test('cloned contextual SVG descendants follow the new owner after reparenting', () => {
  const context = createRuntime();
  invoke(context, 'init', {
    hostLayout: true,
    url: 'https://example.test/page',
    html: '<svg id="a"></svg><svg id="b"></svg>'
  });
  const actual = jsonEvaluate(context, `(() => {
    const first = document.getElementById('a');
    const second = document.getElementById('b');
    const range = document.createRange();
    range.selectNodeContents(first);
    first.appendChild(range.createContextualFragment('<g><circle/></g>'));
    const clone = first.firstChild.cloneNode(true);
    const before = clone.firstChild.ownerSVGElement?.id || null;
    second.appendChild(clone);
    return {
      before,
      after: clone.firstChild.ownerSVGElement?.id || null,
      namespace: clone.firstChild.namespaceURI,
    };
  })()`);
  assert.deepEqual(actual, contextualFragmentWebFixture.svgClone);
});

test('scripts in a connected DocumentFragment execute once after insertion', () => {
  const context = createRuntime();
  const initialized = invoke(context, 'init', {
    hostLayout: true,
    url: 'https://example.test/page',
    html: '<div id="host"></div>'
  });
  assert.deepEqual(initialized.resourceRequests, []);
  vm.runInContext([
    'window.fragmentRuns = 0;',
    'const fragment = document.createDocumentFragment();',
    'const script = document.createElement("script");',
    'script.textContent = "window.fragmentRuns += 1";',
    'fragment.appendChild(script);',
    'document.querySelector("#host").appendChild(fragment);'
  ].join('\n'), context);
  assert.equal(vm.runInContext('window.fragmentRuns', context),
    fragmentWebFixture.result.connectedScriptRuns);
  assert.equal(vm.runInContext('script.isConnected', context), true);
  assert.equal(vm.runInContext('fragment.childNodes.length === 0', context),
    fragmentWebFixture.result.fragmentWasEmptied);
  vm.runInContext('script.remove();document.body.appendChild(script)', context);
  assert.equal(vm.runInContext('window.fragmentRuns', context),
    fragmentWebFixture.result.reinsertedScriptRuns);
});

test('scripts parsed through insertAdjacentHTML remain inert after moving', () => {
  const context = createRuntime();
  invoke(context, 'init', {
    hostLayout: true,
    url: 'https://example.test/page',
    html: '<div id="host"></div>'
  });
  const markup = '<script id="parsed">' +
    'window.markupRuns = (window.markupRuns || 0) + 1<' + '/script>';
  vm.runInContext(
    'document.querySelector("#host").insertAdjacentHTML(' +
      '"beforeend", ' + JSON.stringify(markup) + ')',
    context,
  );
  assert.equal(vm.runInContext('window.markupRuns || 0', context),
    fragmentWebFixture.result.parsedScriptRuns);
  vm.runInContext(
    'const parsed = document.querySelector("#parsed");' +
      'parsed.remove();document.body.appendChild(parsed)',
    context,
  );
  assert.equal(vm.runInContext('window.markupRuns || 0', context),
    fragmentWebFixture.result.reinsertedMarkupRuns);
});

test('scripts parsed through innerHTML remain inert', () => {
  const context = createRuntime();
  const initialized = invoke(context, 'init', {
    url: 'https://example.test/page',
    html: [
      '<div id="host"></div>',
      '<script>',
      'document.querySelector("#host").innerHTML = "<script>window.inertScriptRan = true;<" + "/script>";',
      '</script>'
    ].join('\n')
  });
  assert.deepEqual(initialized.resourceRequests, []);
  assert.equal(vm.runInContext('window.inertScriptRan', context), undefined);
});

test('resource header referrer policy uses the last valid comma-separated value', () => {
  const context = createRuntime();
  const initialized = invoke(context, 'init', {
    url: 'https://example.test/page',
    referrerPolicy: 'no-referrer, unknown, ORIGIN, invalid',
    html: '<script async src="/header.js" crossorigin="unknown" referrerpolicy="unknown"></script>'
  });

  assert.deepEqual(initialized.resourceRequests.map(({ crossOrigin, referrerPolicy }) => ({
    crossOrigin,
    referrerPolicy
  })), [{ crossOrigin: 'anonymous', referrerPolicy: 'origin' }]);
});

test('live referrer meta and per-resource overrides apply to fetch and scripts', () => {
  const context = createRuntime();
  const initialized = invoke(context, 'init', {
    url: 'https://example.test/page',
    referrerPolicy: 'unsafe-url',
    html: [
      '<meta name="ReFeRrEr" content="NO-REFERRER">',
      '<script>',
      'window.defaultPolicyFetch = fetch("/default");',
      'window.explicitPolicyFetch = fetch("/explicit", { referrerPolicy: "origin" });',
      '</script>',
      '<script async src="/script-override.js" crossorigin="AnOnYmOuS" referrerpolicy="StRiCt-OrIgIn"></script>',
      '<script async src="/script-default.js" crossorigin="UsE-CrEdEnTiAlS" referrerpolicy="invalid"></script>'
    ].join('\n')
  });

  assert.deepEqual(initialized.resourceRequests.map(({ kind, crossOrigin, referrerPolicy }) => ({
    kind,
    crossOrigin,
    referrerPolicy
  })), [
    { kind: 'fetch', crossOrigin: undefined, referrerPolicy: 'no-referrer' },
    { kind: 'fetch', crossOrigin: undefined, referrerPolicy: 'origin' },
    { kind: 'script', crossOrigin: 'anonymous', referrerPolicy: 'strict-origin' },
    { kind: 'script', crossOrigin: 'use-credentials', referrerPolicy: 'no-referrer' }
  ]);
});

test('aborted fetches are removed from the shared resource drain', () => {
  const context = createRuntime();
  const initialized = invoke(context, 'init', {
    url: 'https://example.test/page',
    html: [
      '<script>',
      'const controller = new AbortController();',
      'window.abortedFetch = fetch("/cancelled", { signal: controller.signal }).catch(() => {});',
      'controller.abort();',
      'window.liveFetch = fetch("/kept");',
      '</script>',
      '<script async src="/library.js"></script>'
    ].join('\n')
  });

  assert.deepEqual(initialized.resourceRequests.map(({ id, kind, url }) => ({
    id,
    kind,
    url
  })), [
    { id: 'fetch-2', kind: 'fetch', url: 'https://example.test/kept' },
    { id: 'script-1', kind: 'script', url: 'https://example.test/library.js' }
  ]);
  assert.deepEqual(invoke(context, 'snapshot', {}).resourceRequests, []);
});

test('fetch and classic scripts share one-shot resource draining and completion routing', async () => {
  const context = createRuntime();
  const initialized = invoke(context, 'init', {
    url: 'https://example.test/page',
    html: [
      '<base href="/assets/">',
      '<script>',
      'window.fetchResult = fetch("data.txt").then(response => response.text());',
      '</script>',
      '<script id="library" async src="library.js"></script>'
    ].join('\n')
  });

  assert.deepEqual(initialized.resourceRequests.map(({ id, kind, url }) => ({
    id,
    kind,
    url
  })), [
    { id: 'fetch-1', kind: 'fetch', url: 'https://example.test/assets/data.txt' },
    { id: 'script-1', kind: 'script', url: 'https://example.test/assets/library.js' }
  ]);
  assert.deepEqual(invoke(context, 'snapshot', {}).resourceRequests, []);

  const fetchCompletion = invoke(context, 'completeResource', {
    id: 'fetch-1',
    ok: true,
    status: 200,
    statusText: 'OK',
    url: 'https://example.test/assets/data.txt',
    headers: [['content-type', 'text/plain']],
    type: 'basic',
    redirected: false,
    bodyBase64: 'bmF0aXZl'
  });
  assert.deepEqual(fetchCompletion.resourceRequests, []);
  assert.equal(await vm.runInContext('window.fetchResult', context), 'native');

  const scriptCompletion = invoke(context, 'completeResource', {
    id: 'script-1',
    ok: true,
    url: 'https://example.test/assets/library.js',
    source: 'window.libraryLoaded = document.currentScript === document.querySelector("#library");'
  });
  assert.deepEqual(scriptCompletion.resourceRequests, []);
  assert.equal(vm.runInContext('window.libraryLoaded', context), true);
  assert.equal(vm.runInContext('document.readyState', context), 'complete');
});

test('location writes queue one-shot navigation actions without changing getters before host acknowledgment', () => {
  const context = createRuntime();
  const initialized = invoke(context, 'init', {
    url: 'https://example.test/current/page?old=1#start',
    html: [
      '<base href="/assets/">',
      '<form id="form" action="/submit"><input name="value" value="x"></form>',
      '<button id="hash">Hash</button>',
      '<button id="clearHash">Clear hash</button>',
      '<button id="replace">Replace</button>',
      '<button id="reload">Reload</button>',
      '<button id="invalid">Invalid</button>',
      '<script>',
      'document.querySelector("#form").submit();',
      'window.initialHref = location.href;',
      'location.assign("first?q=1#before");',
      'window.afterAssign = window.location.href;',
      'location = "bare";',
      'window.afterBareAssignment = window.location.href;',
      'window.location = "window";',
      'window.afterWindowAssignment = location.href;',
      'document.location = "document";',
      'window.afterDocumentAssignment = document.location.href;',
      'window.location.href = "href";',
      'window.afterHrefAssignment = window.location.href;',
      'document.querySelector("#hash").onclick = function() { location.hash = "next"; };',
      'document.querySelector("#clearHash").onclick = function() { location.hash = ""; };',
      'document.querySelector("#replace").onclick = function() { location.assign("one"); location.replace("two"); };',
      'document.querySelector("#reload").onclick = function() { location.reload(); };',
      'document.querySelector("#invalid").onclick = function() { location.assign("javascript:alert(1)"); };',
      '</script>'
    ].join('\n')
  });

  const originalUrl = 'https://example.test/current/page?old=1#start';
  assert.equal(vm.runInContext('window.initialHref', context), originalUrl);
  assert.equal(initialized.formActions.length, 1);
  assert.equal(initialized.formActions[0].actionOrder, 1);
  assert.equal(vm.runInContext('window.afterAssign', context), originalUrl);
  assert.equal(vm.runInContext('window.afterBareAssignment', context), originalUrl);
  assert.equal(vm.runInContext('window.afterWindowAssignment', context), originalUrl);
  assert.equal(vm.runInContext('window.afterDocumentAssignment', context), originalUrl);
  assert.equal(vm.runInContext('window.afterHrefAssignment', context), originalUrl);
  assert.deepEqual(initialized.navigationActions, [{
    kind: 'navigate',
    url: 'https://example.test/assets/href',
    replace: false,
    target: '_self',
    actionOrder: 6
  }]);

  const drained = invoke(context, 'snapshot', {});
  assert.deepEqual(drained.navigationActions, []);
  const acknowledgedUrl = initialized.navigationActions[0].url;
  const acknowledged = invoke(context, 'updateLocation', { url: acknowledgedUrl });
  assert.deepEqual(acknowledged.navigationActions, []);
  assert.equal(vm.runInContext('location.href', context), acknowledgedUrl);
  assert.equal(vm.runInContext('window.location.origin', context), 'https://example.test');
  assert.equal(vm.runInContext('window.location.protocol', context), 'https:');
  assert.equal(vm.runInContext('document.location.pathname', context), '/assets/href');
  assert.equal(vm.runInContext('document.URL', context), acknowledgedUrl);
  assert.equal(vm.runInContext('document.documentURI', context), acknowledgedUrl);

  const hashChange = invoke(context, 'dispatch', {
    id: elementId(context, '#hash'),
    type: 'click'
  });
  assert.deepEqual(hashChange.navigationActions, [{
    kind: 'navigate',
    url: 'https://example.test/assets/href#next',
    replace: false,
    target: '_self',
    sameDocument: true,
    actionOrder: 7
  }]);
  assert.equal(vm.runInContext('location.href', context), acknowledgedUrl);

  invoke(context, 'updateLocation', { url: hashChange.navigationActions[0].url });
  const clearHash = invoke(context, 'dispatch', {
    id: elementId(context, '#clearHash'),
    type: 'click'
  });
  assert.deepEqual(clearHash.navigationActions, [{
    kind: 'navigate',
    url: 'https://example.test/assets/href#',
    replace: false,
    target: '_self',
    sameDocument: true,
    actionOrder: 8
  }]);

  const replacement = invoke(context, 'dispatch', {
    id: elementId(context, '#replace'),
    type: 'click'
  });
  assert.deepEqual(replacement.navigationActions, [{
    kind: 'navigate',
    url: 'https://example.test/assets/two',
    replace: true,
    target: '_self',
    actionOrder: 10
  }]);

  const reloaded = invoke(context, 'dispatch', {
    id: elementId(context, '#reload'),
    type: 'click'
  });
  assert.deepEqual(reloaded.navigationActions, [{
    kind: 'reload',
    actionOrder: 11
  }]);

  const invalid = invoke(context, 'dispatch', {
    id: elementId(context, '#invalid'),
    type: 'click'
  });
  assert.deepEqual(invalid.navigationActions, []);
  assert.ok(invalid.diagnostics.some((item) => item.code === 'navigation.invalid_url'));
});

test('host location acknowledgments update getters and emit hashchange only within the same document URL', () => {
  const context = createRuntime();
  const initialized = invoke(context, 'init', {
    url: 'https://example.test/docs/start?mode=one#old',
    html: [
      '<script>',
      'window.hashChanges = [];',
      'window.addEventListener("hashchange", function(event) {',
      '  window.hashChanges.push({ oldURL: event.oldURL, newURL: event.newURL });',
      '});',
      '</script>'
    ].join('\n')
  });
  assert.deepEqual(initialized.navigationActions, []);

  const hashUpdate = invoke(context, 'updateLocation', {
    url: 'https://example.test/docs/start?mode=one#new'
  });
  assert.deepEqual(hashUpdate.navigationActions, []);
  assert.equal(vm.runInContext('location.hash', context), '#new');
  assert.deepEqual(jsonEvaluate(context, 'window.hashChanges'), [{
    oldURL: 'https://example.test/docs/start?mode=one#old',
    newURL: 'https://example.test/docs/start?mode=one#new'
  }]);

  invoke(context, 'updateLocation', {
    url: 'https://example.test/docs/start?mode=one#new'
  });
  assert.equal(vm.runInContext('window.hashChanges.length', context), 1);
  invoke(context, 'updateLocation', {
    url: 'https://example.test/docs/other#different'
  });
  assert.equal(vm.runInContext('location.href', context), 'https://example.test/docs/other#different');
  assert.equal(vm.runInContext('window.hashChanges.length', context), 1);

  const invalid = invoke(context, 'updateLocation', { url: 'javascript:alert(1)' });
  assert.equal(vm.runInContext('location.href', context), 'https://example.test/docs/other#different');
  assert.ok(invalid.diagnostics.some((item) => item.code === 'navigation.invalid_url'));
});

test('window.open queues distinct _blank requests only during host-dispatched user events', () => {
  const context = createRuntime();
  const initialized = invoke(context, 'init', {
    url: 'https://example.test/docs/start',
    html: [
      '<button id="open">Open</button>',
      '<script>',
      'window.loadPopup = window.open("/load", "_blank");',
      'window.unsupportedTarget = window.open("/named", "namedWindow");',
      'window.selfNavigation = window.open("/self", "_self");',
      'window.timer = setTimeout(function() { window.timerPopup = window.open("/timer"); }, 0);',
      'document.querySelector("#open").addEventListener("click", function() {',
      '  window.firstPopup = window.open("/first", "_blank");',
      '  window.secondPopup = window.open("/second", "_blank");',
      '  window.clickSelf = window.open("/click-self", "_self");',
      '});',
      '</script>'
    ].join('\n')
  });
  assert.deepEqual(initialized.navigationActions, [{
    kind: 'navigate',
    url: 'https://example.test/self',
    replace: false,
    target: '_self',
    actionOrder: 1
  }]);
  assert.equal(vm.runInContext('window.loadPopup', context), null);
  assert.equal(vm.runInContext('window.unsupportedTarget', context), null);

  const timer = invoke(context, 'pump', { now: 0 });
  assert.deepEqual(timer.navigationActions, []);
  assert.equal(vm.runInContext('window.timerPopup', context), null);

  const clicked = invoke(context, 'dispatch', {
    id: elementId(context, '#open'),
    type: 'click'
  });
  assert.deepEqual(clicked.navigationActions, [
    {
      kind: 'navigate',
      url: 'https://example.test/first',
      replace: false,
      target: '_blank',
      actionOrder: 2
    },
    {
      kind: 'navigate',
      url: 'https://example.test/second',
      replace: false,
      target: '_blank',
      actionOrder: 3
    },
    {
      kind: 'navigate',
      url: 'https://example.test/click-self',
      replace: false,
      target: '_self',
      actionOrder: 4
    }
  ]);
  assert.equal(vm.runInContext('window.firstPopup', context), null);
  assert.equal(vm.runInContext('window.secondPopup', context), null);
  assert.ok(clicked.diagnostics.some((item) => item.code === 'navigation.popup_blocked'));
  assert.ok(clicked.diagnostics.some((item) => item.code === 'navigation.window_open_target_unsupported'));
  assert.ok(clicked.diagnostics.some((item) => item.code === 'navigation.window_proxy_unsupported'));
});

test('native same-window anchor defaults arbitrate earlier script navigation requests', () => {
  const context = createRuntime();
  invoke(context, 'init', {
    url: 'https://example.test/docs/start',
    html: [
      '<base href="/assets/" target="_parent">',
      '<a id="native" href="/default"><span id="native-child">Native</span></a>',
      '<a id="cancel" href="/default-cancel"><span id="cancel-child">Cancel</span></a>',
      '<a id="blank" href="/popup" target="_blank">Popup</a>',
      '<a id="download" href="/file" download="file.bin">Download</a>',
      '<a id="named" href="/named" target="report">Named</a>',
      '<script>',
      'document.querySelector("#native").addEventListener("click", function() {',
      '  location.assign("/script");',
      '});',
      'document.querySelector("#cancel").addEventListener("click", function(event) {',
      '  location.assign("/script-cancel");',
      '  event.preventDefault();',
      '});',
      'document.querySelector("#blank").addEventListener("click", function() {',
      '  location.assign("/script-blank");',
      '});',
      'document.querySelector("#download").addEventListener("click", function() {',
      '  location.assign("/script-download");',
      '});',
      'document.querySelector("#named").addEventListener("click", function() {',
      '  location.assign("/script-named");',
      '});',
      '</script>'
    ].join('\n')
  });

  const native = invoke(context, 'dispatch', {
    id: elementId(context, '#native-child'),
    type: 'click'
  });
  assert.equal(native.defaultPrevented, false);
  assert.deepEqual(native.navigationActions, [{
    kind: 'navigate',
    url: 'https://example.test/script',
    replace: false,
    target: '_self',
    actionOrder: 1
  }]);
  assert.equal(native.nativeLinkDefaultOrder, 2);

  const cancelled = invoke(context, 'dispatch', {
    id: elementId(context, '#cancel-child'),
    type: 'click'
  });
  assert.equal(cancelled.defaultPrevented, true);
  assert.deepEqual(cancelled.navigationActions, [{
    kind: 'navigate',
    url: 'https://example.test/script-cancel',
    replace: false,
    target: '_self',
    actionOrder: 3
  }]);
  assert.equal(Object.hasOwn(cancelled, 'nativeLinkDefaultOrder'), false);

  for (const [selector, expectedUrl] of [
    ['#blank', 'https://example.test/script-blank'],
    ['#download', 'https://example.test/script-download'],
    ['#named', 'https://example.test/script-named']
  ]) {
    const click = invoke(context, 'dispatch', {
      id: elementId(context, selector),
      type: 'click'
    });
    assert.equal(click.navigationActions.length, 1);
    assert.equal(click.navigationActions[0].url, expectedUrl);
    assert.equal(Object.hasOwn(click, 'nativeLinkDefaultOrder'), false);
  }
});

test('documents in different VM contexts do not share script state', () => {
  const first = createRuntime();
  const second = createRuntime();
  const html = [
    '<button id="counter" onclick="window.count += 1; return false;">Count</button>',
    '<script>window.count = 0;</script>'
  ].join('\n');

  invoke(first, 'init', { html });
  invoke(second, 'init', { html });
  const firstId = elementId(first, '#counter');
  const secondId = elementId(second, '#counter');

  invoke(first, 'dispatch', { id: firstId, type: 'click' });
  assert.equal(vm.runInContext('window.count', first), 1);
  assert.equal(vm.runInContext('window.count', second), 0);

  invoke(second, 'dispatch', { id: secondId, type: 'click' });
  assert.equal(vm.runInContext('window.count', second), 1);
});

test('form reset keeps live edits separate from defaults and supports cancellation and reentry', () => {
  const context = createRuntime();
  const html = [
    '<form id="form">',
    '<input id="text" value="original">',
    '<input id="check" type="checkbox" checked>',
    '<textarea id="notes">original notes</textarea>',
    '<select id="choice">',
    '  <option id="first" value="duplicate" selected>First</option>',
    '  <option id="second" value="duplicate">Second</option>',
    '  <option id="third" value="other">Third</option>',
    '</select>',
    '</form>',
    '<script>',
    'const form = document.querySelector("#form");',
    'const text = document.querySelector("#text");',
    'const notes = document.querySelector("#notes");',
    'window.eventCounts = { input: 0, change: 0, reset: 0 };',
    'window.cancelReset = false;',
    'window.changeDefaults = false;',
    'window.reenterReset = false;',
    'form.addEventListener("input", function() { window.eventCounts.input += 1; });',
    'form.addEventListener("change", function() { window.eventCounts.change += 1; });',
    'form.addEventListener("reset", function(event) {',
    '  window.eventCounts.reset += 1;',
    '  if (window.changeDefaults) {',
    '    text.defaultValue = "handler default";',
    '    notes.defaultValue = "handler notes";',
    '  }',
    '  if (window.reenterReset) {',
    '    window.reenterReset = false;',
    '    window.nestedResetResult = form.reset();',
    '  }',
    '  if (window.cancelReset) event.preventDefault();',
    '});',
    '</script>'
  ].join('\n');
  const initialized = invoke(context, 'init', { html });
  assert.equal(initialized.diagnostics.some((item) => item.severity === 'error'), false);

  const getState = () => jsonEvaluate(context, `(() => {
    const text = document.querySelector('#text');
    const check = document.querySelector('#check');
    const notes = document.querySelector('#notes');
    const choice = document.querySelector('#choice');
    const first = document.querySelector('#first');
    const second = document.querySelector('#second');
    return {
      textValue: text.value,
      textDefaultValue: text.defaultValue,
      checked: check.checked,
      defaultChecked: check.defaultChecked,
      notesValue: notes.value,
      notesDefaultValue: notes.defaultValue,
      selectedIndex: choice.selectedIndex,
      firstSelected: first.selected,
      secondSelected: second.selected,
      firstDefaultSelected: first.defaultSelected,
      secondDefaultSelected: second.defaultSelected,
      eventCounts: window.eventCounts
    };
  })()`);

  const edited = invoke(context, 'dispatch', {
    id: elementId(context, '#text'),
    type: 'input',
    controls: [
      { id: elementId(context, '#text'), value: 'edited text' },
      { id: elementId(context, '#check'), checked: false },
      { id: elementId(context, '#notes'), value: 'edited notes' },
      {
        id: elementId(context, '#choice'),
        selectedValues: ['duplicate'],
        selectedIndices: [1]
      }
    ]
  });
  assert.equal(edited.defaultPrevented, false);
  assert.deepEqual(getState(), {
    textValue: 'edited text',
    textDefaultValue: 'original',
    checked: false,
    defaultChecked: true,
    notesValue: 'edited notes',
    notesDefaultValue: 'original notes',
    selectedIndex: 1,
    firstSelected: false,
    secondSelected: true,
    firstDefaultSelected: true,
    secondDefaultSelected: false,
    eventCounts: { input: 1, change: 0, reset: 0 }
  });

  vm.runInContext('window.cancelReset = true', context);
  const cancelled = invoke(context, 'dispatch', {
    id: elementId(context, '#form'),
    type: 'reset'
  });
  assert.equal(cancelled.defaultPrevented, true);
  const afterCancelledReset = getState();
  assert.equal(afterCancelledReset.textValue, 'edited text');
  assert.equal(afterCancelledReset.checked, false);
  assert.equal(afterCancelledReset.notesValue, 'edited notes');
  assert.equal(afterCancelledReset.selectedIndex, 1);
  assert.equal(afterCancelledReset.textDefaultValue, 'original');
  assert.equal(afterCancelledReset.defaultChecked, true);
  assert.equal(afterCancelledReset.notesDefaultValue, 'original notes');
  assert.deepEqual(afterCancelledReset.eventCounts, { input: 1, change: 0, reset: 1 });

  vm.runInContext('window.cancelReset = false; window.changeDefaults = true', context);
  const allowed = invoke(context, 'dispatch', {
    id: elementId(context, '#form'),
    type: 'reset'
  });
  assert.equal(allowed.defaultPrevented, false);
  const afterAllowedReset = getState();
  assert.equal(afterAllowedReset.textValue, 'handler default');
  assert.equal(afterAllowedReset.textDefaultValue, 'handler default');
  assert.equal(afterAllowedReset.checked, true);
  assert.equal(afterAllowedReset.defaultChecked, true);
  assert.equal(afterAllowedReset.notesValue, 'handler notes');
  assert.equal(afterAllowedReset.notesDefaultValue, 'handler notes');
  assert.equal(afterAllowedReset.selectedIndex, 0);
  assert.equal(afterAllowedReset.firstSelected, true);
  assert.equal(afterAllowedReset.secondSelected, false);
  assert.equal(afterAllowedReset.firstDefaultSelected, true);
  assert.equal(afterAllowedReset.secondDefaultSelected, false);
  assert.deepEqual(afterAllowedReset.eventCounts, { input: 1, change: 0, reset: 2 });

  const directReset = jsonEvaluate(context, `(() => {
    const form = document.querySelector('#form');
    document.querySelector('#text').value = 'later text';
    document.querySelector('#check').checked = false;
    document.querySelector('#notes').value = 'later notes';
    document.querySelector('#choice').selectedIndex = 2;
    window.changeDefaults = false;
    window.reenterReset = true;
    const result = form.reset();
    return {
      resultType: typeof result,
      nestedResultType: typeof window.nestedResetResult
    };
  })()`);
  assert.deepEqual(directReset, { resultType: 'undefined', nestedResultType: 'undefined' });
  const afterDirectReset = getState();
  assert.equal(afterDirectReset.textValue, 'handler default');
  assert.equal(afterDirectReset.notesValue, 'handler notes');
  assert.equal(afterDirectReset.checked, true);
  assert.equal(afterDirectReset.selectedIndex, 0);
  assert.deepEqual(afterDirectReset.eventCounts, { input: 1, change: 0, reset: 3 });
});

test('file metadata syncs and a clear epoch rejects stale file selections', () => {
  const context = createRuntime();
  const html = [
    '<form id="form"><input id="upload" type="file"></form>',
    '<script>',
    'const upload = document.querySelector("#upload");',
    'window.clearOnChange = false;',
    'upload.addEventListener("change", function() {',
    '  if (window.clearOnChange) {',
    '    window.clearOnChange = false;',
    '    upload.value = "";',
    '  }',
    '});',
    '</script>'
  ].join('\n');
  const initialized = invoke(context, 'init', { html });
  assert.equal(initialized.diagnostics.some((item) => item.severity === 'error'), false);
  const uploadId = elementId(context, '#upload');
  const selected = invoke(context, 'dispatch', {
    id: uploadId,
    type: 'file-state',
    controls: [{
      id: uploadId,
      files: [{ name: 'report.csv', type: 'text/csv', size: 17 }],
      fileResetVersion: 0
    }]
  });
  assert.match(selected.html, /data-pirc-file-reset-version="0"/);
  assert.deepEqual(jsonEvaluate(context, `(() => {
    const upload = document.querySelector('#upload');
    return {
      value: upload.value,
      files: upload.files.map(file => ({ name: file.name, type: file.type, size: file.size }))
    };
  })()`), {
    value: 'C:\\fakepath\\report.csv',
    files: [{ name: 'report.csv', type: 'text/csv', size: 17 }]
  });

  vm.runInContext('window.clearOnChange = true', context);
  const cleared = invoke(context, 'dispatch', {
    id: uploadId,
    type: 'change',
    controls: [{
      id: uploadId,
      files: [{ name: 'report.csv', type: 'text/csv', size: 17 }],
      fileResetVersion: 0
    }]
  });
  assert.match(cleared.html, /data-pirc-file-reset-version="1"/);
  assert.deepEqual(jsonEvaluate(context, `(() => {
    const upload = document.querySelector('#upload');
    return { value: upload.value, fileCount: upload.files.length };
  })()`), { value: '', fileCount: 0 });

  const stale = invoke(context, 'dispatch', {
    id: uploadId,
    type: 'file-state',
    controls: [{
      id: uploadId,
      files: [{ name: 'stale.csv', type: 'text/csv', size: 99 }],
      fileResetVersion: 0
    }]
  });
  assert.match(stale.html, /data-pirc-file-reset-version="1"/);
  assert.deepEqual(jsonEvaluate(context, `(() => {
    const upload = document.querySelector('#upload');
    return { value: upload.value, fileCount: upload.files.length };
  })()`), { value: '', fileCount: 0 });
});


test('host-pumped timers sort by deadline and insertion order, pass args, and can be cancelled cross-kind', () => {
  const context = createRuntime();
  const html = [
    '<button id="touch">touch</button>',
    '<script>',
    'window.timerEvents = [];',
    'window.cancelledTimerId = setTimeout(function() { window.timerEvents.push("cancelled"); }, 5);',
    'clearInterval(window.cancelledTimerId);',
    'setTimeout(function(label, value) {',
    '  window.timerEvents.push(label + value + ":" + performance.now() + ":" + (this === window));',
    '}, 10, "late", 7);',
    'setTimeout(function() { window.timerEvents.push("first"); }, 5);',
    'setTimeout(function() { window.timerEvents.push("second"); }, 5);',
    '</script>'
  ].join('\n');
  const initialized = invoke(context, 'init', { html, now: 0 });
  assert.equal(initialized.now, 0);
  assert.deepEqual(initialized.scheduler, { timerDelayMs: 5, animationFrame: false });

  const untouched = invoke(context, 'snapshot', { now: 4 });
  assert.equal(untouched.now, 4);
  assert.deepEqual(untouched.scheduler, { timerDelayMs: 1, animationFrame: false });
  const rewound = invoke(context, 'snapshot', { now: 2 });
  assert.equal(rewound.now, 4);
  assert.deepEqual(rewound.scheduler, { timerDelayMs: 1, animationFrame: false });
  assert.deepEqual(Array.from(vm.runInContext('window.timerEvents', context)), []);

  invoke(context, 'pump', { now: 5, animationFrame: false });
  assert.deepEqual(Array.from(vm.runInContext('window.timerEvents', context)), ['first']);
  assert.deepEqual(invoke(context, 'snapshot', { now: 5 }).scheduler, {
    timerDelayMs: 0,
    animationFrame: false
  });
  invoke(context, 'pump', { now: 5, animationFrame: false });
  assert.deepEqual(Array.from(vm.runInContext('window.timerEvents', context)), [
    'first',
    'second'
  ]);
  invoke(context, 'pump', { now: 10, animationFrame: false });
  assert.deepEqual(Array.from(vm.runInContext('window.timerEvents', context)), [
    'first',
    'second',
    'late7:10:true'
  ]);
  assert.deepEqual(invoke(context, 'snapshot', { now: 10 }).scheduler, {
    timerDelayMs: null,
    animationFrame: false
  });
});

test('timer callbacks accept source strings and deeply nested timers clamp to four milliseconds', () => {
  const context = createRuntime();
  const html = [
    '<script>',
    'window.nestedCalls = 0;',
    'window.stringCalls = 0;',
    'function scheduleNext() {',
    '  window.nestedCalls += 1;',
    '  if (window.nestedCalls < 7) setTimeout(scheduleNext, 0);',
    '}',
    'setTimeout(scheduleNext, 0);',
    'setTimeout("window.stringCalls += 1", 0);',
    '</script>'
  ].join('\n');
  const initialized = invoke(context, 'init', { html, now: 0 });
  assert.deepEqual(initialized.scheduler, { timerDelayMs: 0, animationFrame: false });

  invoke(context, 'pump', { now: 0 });
  assert.equal(vm.runInContext('window.nestedCalls', context), 1);
  assert.equal(vm.runInContext('window.stringCalls', context), 0);
  invoke(context, 'pump', { now: 0 });
  assert.equal(vm.runInContext('window.stringCalls', context), 1);
  for (let index = 0; index < 3; index++)
    invoke(context, 'pump', { now: 0 });
  assert.equal(vm.runInContext('window.nestedCalls', context), 4);
  invoke(context, 'pump', { now: 0 });
  assert.equal(vm.runInContext('window.nestedCalls', context), 5);
  assert.equal(invoke(context, 'snapshot', { now: 0 }).scheduler.timerDelayMs, 0);
  invoke(context, 'pump', { now: 0 });
  assert.equal(vm.runInContext('window.nestedCalls', context), 6);
  assert.equal(invoke(context, 'snapshot', { now: 0 }).scheduler.timerDelayMs, 4);

  invoke(context, 'pump', { now: 3 });
  assert.equal(vm.runInContext('window.nestedCalls', context), 6);
  invoke(context, 'pump', { now: 4 });
  assert.equal(vm.runInContext('window.nestedCalls', context), 7);
  assert.equal(invoke(context, 'snapshot', { now: 4 }).scheduler.timerDelayMs, null);
});

test('animation frames only run when requested and callbacks queued in a frame wait for the next frame', () => {
  const context = createRuntime();
  const html = [
    '<script>',
    'window.frameEvents = [];',
    'window.cancelledFrame = requestAnimationFrame(function() { window.frameEvents.push("cancelled"); });',
    'cancelAnimationFrame(window.cancelledFrame);',
    'requestAnimationFrame(function(timestamp) {',
    '  window.frameEvents.push("first:" + timestamp + ":" + (this === window));',
    '  requestAnimationFrame(function(nextTimestamp) {',
    '    window.frameEvents.push("second:" + nextTimestamp);',
    '  });',
    '});',
    '</script>'
  ].join('\n');
  const initialized = invoke(context, 'init', { html, now: 12 });
  assert.deepEqual(initialized.scheduler, { timerDelayMs: null, animationFrame: true });

  invoke(context, 'pump', { now: 12, animationFrame: false });
  assert.deepEqual(Array.from(vm.runInContext('window.frameEvents', context)), []);
  assert.equal(invoke(context, 'snapshot', { now: 12 }).scheduler.animationFrame, true);

  const firstFrame = invoke(context, 'pump', { now: 12, animationFrame: true });
  assert.deepEqual(Array.from(vm.runInContext('window.frameEvents', context)), [
    'first:12:true'
  ]);
  assert.deepEqual(firstFrame.scheduler, { timerDelayMs: null, animationFrame: true });

  const secondFrame = invoke(context, 'pump', { now: 16, animationFrame: true });
  assert.deepEqual(Array.from(vm.runInContext('window.frameEvents', context)), [
    'first:12:true',
    'second:16'
  ]);
  assert.deepEqual(secondFrame.scheduler, { timerDelayMs: null, animationFrame: false });
});

test('intervals reschedule from pump time, avoid catch-up, and clearTimeout cancels them', () => {
  const context = createRuntime();
  const html = [
    '<script>',
    'window.intervalCalls = 0;',
    'window.intervalId = setInterval(function(marker) {',
    '  window.intervalCalls += 1;',
    '  window.intervalMarker = marker;',
    '}, 10, "interval-arg");',
    '</script>'
  ].join('\n');
  const initialized = invoke(context, 'init', { html, now: 0 });
  assert.equal(initialized.scheduler.timerDelayMs, 10);

  invoke(context, 'pump', { now: 35 });
  assert.equal(vm.runInContext('window.intervalCalls', context), 1);
  assert.equal(vm.runInContext('window.intervalMarker', context), 'interval-arg');
  assert.deepEqual(invoke(context, 'snapshot', { now: 35 }).scheduler, {
    timerDelayMs: 10,
    animationFrame: false
  });

  invoke(context, 'pump', { now: 44 });
  assert.equal(vm.runInContext('window.intervalCalls', context), 1);
  invoke(context, 'pump', { now: 45 });
  assert.equal(vm.runInContext('window.intervalCalls', context), 2);
  vm.runInContext('clearTimeout(window.intervalId)', context);
  assert.deepEqual(invoke(context, 'snapshot', { now: 45 }).scheduler, {
    timerDelayMs: null,
    animationFrame: false
  });
});

test('callback failures remain diagnostic while later timer and frame callbacks still run', () => {
  const context = createRuntime();
  const html = [
    '<script>',
    'window.afterTimerError = false;',
    'window.afterFrameError = false;',
    'setTimeout(function() { throw new Error("timer boom"); }, 0);',
    'setTimeout(function() { window.afterTimerError = true; }, 0);',
    'requestAnimationFrame(function() { throw new Error("frame boom"); });',
    'requestAnimationFrame(function() { window.afterFrameError = true; });',
    '</script>'
  ].join('\n');
  const initialized = invoke(context, 'init', { html, now: 0 });

  const firstTimer = invoke(context, 'pump', { now: 0 });
  assert.equal(vm.runInContext('window.afterTimerError', context), false);
  assert.ok(firstTimer.diagnostics.some((item) =>
    item.code === 'scheduler.callback_error' && item.message === 'timer boom'
  ));
  invoke(context, 'pump', { now: 0 });
  assert.equal(vm.runInContext('window.afterTimerError', context), true);

  const frameResult = invoke(context, 'pump', { now: 0, animationFrame: true });
  assert.equal(vm.runInContext('window.afterFrameError', context), true);
  assert.ok(frameResult.diagnostics.some((item) =>
    item.code === 'scheduler.callback_error' && item.message === 'frame boom'
  ));
  assert.equal(initialized.scheduler.animationFrame, true);
  assert.deepEqual(frameResult.scheduler, { timerDelayMs: null, animationFrame: false });
});

test('scheduler limits all pending timer and frame callbacks to 256', () => {
  const context = createRuntime();
  const html = [
    '<script>',
    'window.limitCallbacksRun = 0;',
    'for (let index = 0; index < 257; index++) {',
    '  setTimeout(function() { window.limitCallbacksRun += 1; }, 0);',
    '}',
    '</script>'
  ].join('\n');
  const initialized = invoke(context, 'init', { html, now: 0 });
  assert.ok(initialized.diagnostics.some((item) =>
    item.code === 'scheduler.pending_limit' && item.severity === 'error'
  ));

  for (let index = 0; index < 256; index++)
    invoke(context, 'pump', { now: 0 });
  const drained = jsonEvaluate(context, '({ calls: window.limitCallbacksRun, scheduler: JSON.parse(__pircDocument.snapshot({ now: 0 })).scheduler })');
  assert.equal(drained.calls, 256);
  assert.deepEqual(drained.scheduler, { timerDelayMs: null, animationFrame: false });
});


test('init, dispatch, pump, and snapshot bind a monotonic performance clock', () => {
  const context = createRuntime();
  const html = [
    '<button id="clock" onclick="window.clickTime = performance.now();">Clock</button>',
    '<script>',
    'window.initialTime = performance.now();',
    'window.initialOrigin = performance.timeOrigin;',
    'setTimeout(function() { window.timerTime = performance.now(); }, 20);',
    '</script>'
  ].join('\n');
  const initialized = invoke(context, 'init', { html, now: 1000 });
  assert.equal(initialized.now, 1000);
  assert.equal(vm.runInContext('window.initialTime', context), 1000);
  const initialOrigin = vm.runInContext('window.initialOrigin', context);
  assert.ok(Number.isFinite(initialOrigin));
  assert.ok(Math.abs(initialOrigin + 1000 - Date.now()) < 1000);

  const staleSnapshot = invoke(context, 'snapshot', { now: 900 });
  assert.equal(staleSnapshot.now, 1000);
  assert.equal(vm.runInContext('performance.now()', context), 1000);

  const click = invoke(context, 'dispatch', {
    id: elementId(context, '#clock'),
    type: 'click',
    now: 1010
  });
  assert.equal(click.now, 1010);
  assert.equal(vm.runInContext('window.clickTime', context), 1010);
  assert.equal(click.scheduler.timerDelayMs, 10);

  const fired = invoke(context, 'pump', { now: 1020, animationFrame: false });
  assert.equal(fired.now, 1020);
  assert.equal(vm.runInContext('window.timerTime', context), 1020);
  assert.equal(invoke(context, 'snapshot', { now: 1015 }).now, 1020);
});

test('a nested pump does not re-enter the scheduler callback loop', () => {
  const context = createRuntime();
  const html = [
    '<script>',
    'window.pumpEvents = [];',
    'setTimeout(function() {',
    '  window.pumpEvents.push("outer-start");',
    '  const nested = JSON.parse(__pircDocument.pump({ now: 50 }));',
    '  window.nestedPumpWarned = nested.diagnostics.some(item => item.code === "scheduler.reentrant_pump");',
    '  window.pumpEvents.push("outer-end");',
    '}, 0);',
    'setTimeout(function() { window.pumpEvents.push("next"); }, 0);',
    '</script>'
  ].join('\n');
  invoke(context, 'init', { html, now: 0 });

  const outer = invoke(context, 'pump', { now: 0 });
  assert.deepEqual(Array.from(vm.runInContext('window.pumpEvents', context)), [
    'outer-start',
    'outer-end'
  ]);
  assert.equal(vm.runInContext('window.nestedPumpWarned', context), true);
  assert.equal(outer.now, 50);
  assert.equal(outer.scheduler.timerDelayMs, 0);

  invoke(context, 'pump', { now: 50 });
  assert.deepEqual(Array.from(vm.runInContext('window.pumpEvents', context)), [
    'outer-start',
    'outer-end',
    'next'
  ]);
});


test('repeating zero-delay intervals accumulate nesting and apply the four millisecond clamp', () => {
  const context = createRuntime();
  const html = [
    '<script>',
    'window.intervalNestingCalls = 0;',
    'window.nestingInterval = setInterval(function() { window.intervalNestingCalls += 1; }, 0);',
    '</script>'
  ].join('\n');
  invoke(context, 'init', { html, now: 0 });

  for (let index = 0; index < 6; index++)
    invoke(context, 'pump', { now: 0 });
  assert.equal(vm.runInContext('window.intervalNestingCalls', context), 6);
  assert.equal(invoke(context, 'snapshot', { now: 0 }).scheduler.timerDelayMs, 4);

  invoke(context, 'pump', { now: 3 });
  assert.equal(vm.runInContext('window.intervalNestingCalls', context), 6);
  invoke(context, 'pump', { now: 4 });
  assert.equal(vm.runInContext('window.intervalNestingCalls', context), 7);
  vm.runInContext('clearInterval(window.nestingInterval)', context);
  assert.equal(invoke(context, 'snapshot', { now: 4 }).scheduler.timerDelayMs, null);
});

test('timer delays follow WebIDL signed 32-bit conversion before zero clamping', () => {
  const context = createRuntime();
  const html = [
    '<script>',
    'window.wrappedLongCount = 0;',
    'window.wrappedOneCount = 0;',
    'setTimeout(function() { window.wrappedLongCount += 1; }, 2147483648);',
    'setTimeout(function() { window.wrappedOneCount += 1; }, 4294967297);',
    '</script>'
  ].join('\n');
  const initialized = invoke(context, 'init', { html, now: 0 });
  assert.equal(initialized.scheduler.timerDelayMs, 0);

  invoke(context, 'pump', { now: 0 });
  assert.equal(vm.runInContext('window.wrappedLongCount', context), 1);
  assert.equal(vm.runInContext('window.wrappedOneCount', context), 0);
  assert.equal(invoke(context, 'snapshot', { now: 0 }).scheduler.timerDelayMs, 1);

  invoke(context, 'pump', { now: 1 });
  assert.equal(vm.runInContext('window.wrappedOneCount', context), 1);
  assert.equal(invoke(context, 'snapshot', { now: 1 }).scheduler.timerDelayMs, null);
});


test('public text encoders are installed on the isolated global and window before scripts', () => {
  const context = createRuntime();
  const result = invoke(context, 'init', {
    url: 'https://example.test/encoding',
    html: `<p id="result"></p><script>
      const encoder = new TextEncoder();
      const encoded = encoder.encode('中文🙂');
      window.encodingResult = {
        same: window.TextEncoder === TextEncoder && window.TextDecoder === TextDecoder,
        utf8: new TextDecoder().decode(encoded),
        big5: new TextDecoder('big5').decode(new Uint8Array([0xa5,0x78,0xa5,0x5f])),
        bytes: [...encoded]
      };
      document.querySelector('#result').textContent = window.encodingResult.utf8;
    </script>`
  });
  assert.deepEqual(result.diagnostics.filter(item => item.severity !== 'info'), []);
  assert.match(result.html, /中文🙂/);
  assert.deepEqual(jsonEvaluate(context, 'window.encodingResult'), {
    same: true, utf8: '中文🙂', big5: '台北', bytes: [...new TextEncoder().encode('中文🙂')]
  });
  assert.equal(jsonEvaluate(context, "Object.getOwnPropertyDescriptor(globalThis,'TextDecoder').writable"), false);
});
