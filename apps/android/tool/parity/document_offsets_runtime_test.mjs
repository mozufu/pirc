import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import vm from 'node:vm';

const bundlePath = process.env.PIRC_DOCUMENT_SCRIPT_RUNTIME_BUNDLE || fileURLToPath(
  new URL('../../assets/document-script-runtime.js', import.meta.url),
);
const bundle = readFileSync(bundlePath, 'utf8');
const offsetsFixture = JSON.parse(readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-offsets-chromium153.json', import.meta.url), 'utf8'));

function createRuntime() {
  const context = vm.createContext({}, { microtaskMode: 'afterEvaluate' });
  new vm.Script(bundle, { filename: 'document-script-runtime.js' }).runInContext(context);
  return context;
}

function invoke(context, method, argument) {
  const expression = '__pircDocument.' + method + '(' + JSON.stringify(argument) + ')';
  return JSON.parse(new vm.Script(expression).runInContext(context));
}

function evaluate(context, expression) {
  return new vm.Script(expression).runInContext(context);
}

function elementId(context, selector) {
  return evaluate(
    context,
    'document.querySelector(' + JSON.stringify(selector) + ').getAttribute("data-pirc-script-id")',
  );
}

function createBox(x, y, width, height, { offset, scroll } = {}) {
  return {
    kind: 'box',
    x,
    y,
    width,
    height,
    ...(offset ? { offset } : {}),
    ...(scroll ? { scroll } : {}),
  };
}

function nativePacket(response, generation, overrides = {}, viewport = {}) {
  assert.ok(response.layout && Array.isArray(response.layout.ids));
  return {
    revision: response.layout.revision,
    generation,
    viewport: { scrollX: 0, scrollY: 0, width: 390, height: 844, ...viewport },
    boxes: response.layout.ids.map((id) => ({
      id,
      ...(Object.hasOwn(overrides, id) ? overrides[id] : { kind: 'none' }),
    })),
  };
}

function fixtureCase(name) {
  const item = offsetsFixture.cases.find((entry) => entry.name === name && entry.viewportWidth === 390);
  assert.ok(item, `missing Chromium fixture case ${name}`);
  return item;
}

function fixtureObservation(item, stateName = 'initial') {
  if (!item.states) return { name: 'initial', expected: item.expected, windowScroll: item.windowScroll };
  const state = item.states.find((entry) => entry.name === stateName);
  assert.ok(state, `missing state ${stateName} in ${item.name}`);
  return state;
}

function fixturePacket(context, response, item, observation, generation) {
  const ids = Object.fromEntries(item.targets.map((domId) => [domId, elementId(context, `#${domId}`)]));
  const overrides = {};
  for (const [domId, expected] of Object.entries(observation.expected)) {
    const parentId = expected.offsetParentId === null ? null : ids[expected.offsetParentId];
    assert.ok(expected.offsetParentId === null || parentId, `${domId} offset parent is represented by the fixture targets`);
    const rect = expected.rect;
    overrides[ids[domId]] = createBox(
      rect.x + observation.windowScroll.x,
      rect.y + observation.windowScroll.y,
      rect.width,
      rect.height,
      {
        offset: { top: expected.offsetTop, left: expected.offsetLeft, parentId },
        ...(domId === 'scroller' ? {
          scroll: {
            left: expected.scrollLeft,
            top: expected.scrollTop,
            width: 310,
            height: 310,
          },
        } : {}),
      },
    );
  }
  return nativePacket(response, generation, overrides, {
    scrollX: observation.windowScroll.x,
    scrollY: observation.windowScroll.y,
    width: item.viewportWidth,
    height: item.viewportHeight,
  });
}

function runClassicTask(context, response) {
  assert.ok(response.classicScript, 'a classic Script task should be pending');
  const id = response.classicScript.id;
  const task = JSON.parse(evaluate(
    context,
    '__pircDocument.beginClassicScript(' + JSON.stringify({ id }) + ')',
  ));
  assert.equal(task.id, id);
  const source = task.source + '\n;__pircDocument.endClassicScriptTurn(' + id + ');void 0;';
  let error;
  try {
    new vm.Script(source).runInContext(context);
  } catch (failure) {
    error = String(failure?.stack || failure);
  }
  return invoke(context, 'finishClassicScript', { id, ...(error ? { error } : {}) });
}

test('fixture mapped through the host frame gate returns actual offsetParent identity and scroll-adjusted rectangles', () => {
  const capture = fixtureCase('nested_scroll_container_relative');
  const initial = fixtureObservation(capture, 'initial');
  const scrolled = fixtureObservation(capture, 'scroll_40_60');
  const script = [
    '<script>',
    'var target = document.querySelector("#target"), scroller = document.querySelector("#scroller");',
    'window.offsetRead = { top: target.offsetTop, left: target.offsetLeft, parentIsElement: target.offsetParent === scroller, rootParentIsNull: document.documentElement.offsetParent === null, rect: [target.getBoundingClientRect().x, target.getBoundingClientRect().y], scroll: [scroller.scrollLeft, scroller.scrollTop] };',
    '</script>',
  ].join('');
  const context = createRuntime();
  const initialized = invoke(context, 'init', {
    url: 'https://example.test/document-offsets-frame-gate',
    hostLayout: true,
    html: capture.authoredHTML.replace('</body>', `${script}</body>`),
  });
  assert.equal(initialized.layout.required, true);
  assert.equal(evaluate(context, 'window.offsetRead'), undefined,
    'a nonmutating offset read stays behind the native layout frame gate');

  const baseline = invoke(context, 'updateLayout', fixturePacket(context, initialized, capture, initial, 1));
  assert.equal(baseline.layoutAccepted, true);
  const completed = runClassicTask(context, baseline);
  assert.equal(completed.layout.required, false);
  assert.deepEqual(JSON.parse(evaluate(context, 'JSON.stringify(window.offsetRead)')), {
    top: initial.expected.target.offsetTop,
    left: initial.expected.target.offsetLeft,
    parentIsElement: true,
    rootParentIsNull: true,
    rect: [initial.expected.target.rect.x, initial.expected.target.rect.y],
    scroll: [initial.expected.scroller.scrollLeft, initial.expected.scroller.scrollTop],
  });

  const afterScroll = invoke(context, 'updateLayout', fixturePacket(context, completed, capture, scrolled, 2));
  assert.equal(afterScroll.layoutAccepted, true);
  assert.equal(afterScroll.layout.required, false);
  assert.deepEqual(JSON.parse(evaluate(context, [
    'JSON.stringify((function(){',
    'var target=document.querySelector("#target"), scroller=document.querySelector("#scroller");',
    'return {top:target.offsetTop,left:target.offsetLeft,parentIsElement:target.offsetParent===scroller,rect:[target.getBoundingClientRect().x,target.getBoundingClientRect().y],scroll:[scroller.scrollLeft,scroller.scrollTop]};',
    '})())',
  ].join(''))), {
    top: initial.expected.target.offsetTop,
    left: initial.expected.target.offsetLeft,
    parentIsElement: true,
    rect: [scrolled.expected.target.rect.x, scrolled.expected.target.rect.y],
    scroll: [scrolled.expected.scroller.scrollLeft, scrolled.expected.scroller.scrollTop],
  }, 'native scrolling changes BCR while the supplied offset values and parent identity stay fixed');
});

test('negative Chromium fixture offsets remain signed integers and null parents remain null', () => {
  const capture = fixtureCase('relative_parent_negative_half_margins');
  const state = fixtureObservation(capture);
  const context = createRuntime();
  const initialized = invoke(context, 'init', {
    url: 'https://example.test/document-offsets-signed',
    hostLayout: true,
    html: capture.authoredHTML,
  });
  const updated = invoke(context, 'updateLayout', fixturePacket(context, initialized, capture, state, 1));
  assert.equal(updated.layoutAccepted, true);
  assert.deepEqual(JSON.parse(evaluate(context, [
    'JSON.stringify((function(){',
    'var seven=document.querySelector("#negativeSevenHalf"), half=document.querySelector("#negativeHalf"), parent=document.querySelector("#parent");',
    'return {sevenLeft:seven.offsetLeft,sevenX:seven.getBoundingClientRect().x,halfLeft:half.offsetLeft,halfX:half.getBoundingClientRect().x,parentIsElement:seven.offsetParent===parent,htmlParentIsNull:document.documentElement.offsetParent===null};',
    '})())',
  ].join(''))), {
    sevenLeft: state.expected.negativeSevenHalf.offsetLeft,
    sevenX: state.expected.negativeSevenHalf.rect.x,
    halfLeft: state.expected.negativeHalf.offsetLeft,
    halfX: state.expected.negativeHalf.rect.x,
    parentIsElement: true,
    htmlParentIsNull: true,
  });
  assert.equal(updated.layout.required, false);
});

test('style mutation and reparenting stale offsets until fresh parent metadata is accepted', () => {
  const context = createRuntime();
  const initialized = invoke(context, 'init', {
    url: 'https://example.test/document-offsets-stale-parent',
    hostLayout: true,
    html: '<!doctype html><html><body><div id="left"><div id="target"></div></div><div id="right"></div></body></html>',
  });
  const ids = {
    html: elementId(context, 'html'),
    body: elementId(context, 'body'),
    left: elementId(context, '#left'),
    right: elementId(context, '#right'),
    target: elementId(context, '#target'),
  };
  const makeOverrides = (targetParentId, targetTop, targetLeft) => ({
    [ids.html]: createBox(0, 0, 390, 844, { offset: { top: 0, left: 0, parentId: null } }),
    [ids.body]: createBox(0, 0, 390, 160, { offset: { top: 0, left: 0, parentId: null } }),
    [ids.left]: createBox(10, 10, 80, 40, { offset: { top: 10, left: 10, parentId: ids.body } }),
    [ids.right]: createBox(120, 10, 80, 40, { offset: { top: 10, left: 120, parentId: ids.body } }),
    [ids.target]: createBox(130, 20, 20, 10, { offset: { top: targetTop, left: targetLeft, parentId: targetParentId } }),
  });
  const baseline = invoke(context, 'updateLayout', nativePacket(initialized, 1, makeOverrides(ids.left, 10, 10)));
  assert.equal(baseline.layoutAccepted, true);
  assert.equal(evaluate(context, 'document.querySelector("#target").offsetParent === document.querySelector("#left")'), true);

  evaluate(context, 'document.querySelector("#target").setAttribute("style", "color: red")');
  assert.throws(
    () => evaluate(context, 'document.querySelector("#target").offsetTop'),
    (error) => error.name === 'NotSupportedError',
    'a style mutation crosses the layout revision barrier',
  );
  evaluate(context, 'document.querySelector("#right").appendChild(document.querySelector("#target"))');
  const recapture = invoke(context, 'snapshot', {});
  assert.equal(recapture.layout.required, true);
  assert.throws(
    () => evaluate(context, 'document.querySelector("#target").offsetParent'),
    (error) => error.name === 'NotSupportedError',
    'reparenting leaves the previous measured offset parent stale',
  );

  const fresh = invoke(context, 'updateLayout', nativePacket(recapture, 2, makeOverrides(ids.right, 23, 17)));
  assert.equal(fresh.layoutAccepted, true);
  assert.equal(fresh.layout.required, false);
  assert.deepEqual(JSON.parse(evaluate(context, [
    'JSON.stringify((function(){var target=document.querySelector("#target"),right=document.querySelector("#right");return {top:target.offsetTop,left:target.offsetLeft,parentIsFreshElement:target.offsetParent===right};})())',
  ].join(''))), { top: 23, left: 17, parentIsFreshElement: true });
});

test('none and detached elements expose zero offsets, while missing offset metadata throws', () => {
  const context = createRuntime();
  const initialized = invoke(context, 'init', {
    url: 'https://example.test/document-offsets-none-detached',
    hostLayout: true,
    html: '<!doctype html><html><body><div id="missing"></div><div id="none" style="display:none"></div><div id="detached"></div></body></html>',
  });
  const ids = {
    html: elementId(context, 'html'),
    body: elementId(context, 'body'),
    missing: elementId(context, '#missing'),
    none: elementId(context, '#none'),
    detached: elementId(context, '#detached'),
  };
  const updated = invoke(context, 'updateLayout', nativePacket(initialized, 1, {
    [ids.html]: createBox(0, 0, 390, 844, { offset: { top: 0, left: 0, parentId: null } }),
    [ids.body]: createBox(0, 0, 390, 80, { offset: { top: 0, left: 0, parentId: null } }),
    [ids.missing]: createBox(0, 0, 20, 10),
    [ids.none]: { kind: 'none' },
    [ids.detached]: createBox(0, 0, 20, 10, { offset: { top: 5, left: 6, parentId: ids.body } }),
  }));
  assert.equal(updated.layoutAccepted, true);
  assert.throws(
    () => evaluate(context, 'document.querySelector("#missing").offsetTop'),
    (error) => error.name === 'NotSupportedError',
    'a measured box without offset data must not leak undefined',
  );
  assert.deepEqual(JSON.parse(evaluate(context, [
    'JSON.stringify((function(){var none=document.querySelector("#none");return {top:none.offsetTop,left:none.offsetLeft,parent:none.offsetParent,rect:[none.getBoundingClientRect().x,none.getBoundingClientRect().y,none.getBoundingClientRect().width,none.getBoundingClientRect().height]};})())',
  ].join(''))), { top: 0, left: 0, parent: null, rect: [0, 0, 0, 0] });

  evaluate(context, 'window.savedDetached = document.querySelector("#detached"); window.savedDetached.remove()');
  assert.deepEqual(JSON.parse(evaluate(context, [
    'JSON.stringify((function(){var element=window.savedDetached,rect=element.getBoundingClientRect();return {top:element.offsetTop,left:element.offsetLeft,parent:element.offsetParent,rect:[rect.x,rect.y,rect.width,rect.height]};})())',
  ].join(''))), { top: 0, left: 0, parent: null, rect: [0, 0, 0, 0] });
});
