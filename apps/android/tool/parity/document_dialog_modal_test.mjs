import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import nativeVm from 'node:vm';
import test from 'node:test';
import { createDocumentScriptHostVm } from './document_script_host_test_helper.mjs';

const vm = createDocumentScriptHostVm(nativeVm);
const bundle = readFileSync(
  new URL('../../assets/document-script-runtime.js', import.meta.url),
  'utf8',
);
const backdropOracle = JSON.parse(readFileSync(
  new URL('../../../../packages/pirc_render/test/fixtures/parity/document-dialog-modal-backdrop-chromium153.json', import.meta.url),
  'utf8',
));
const markup =
  '<button id="outside">Outside</button><dialog id="first"><button id="first-control">First</button></dialog><dialog id="second"><button id="second-control">Second</button></dialog>';
function setup() {
  const context = vm.createContext({});
  vm.runInContext(bundle, context, { timeout: 3000 });
  JSON.parse(
    vm.runInContext(
      `__pircDocument.init(${JSON.stringify({ html: markup, url: 'https://dialog-modal.example/test' })})`,
      context,
      { timeout: 3000 },
    ),
  );
  return context;
}
function read(context, expression) {
  return JSON.parse(vm.runInContext(`JSON.stringify(${expression})`, context, { timeout: 3000 }));
}
function run(context, source) {
  return vm.runInContext(source, context, { timeout: 3000 });
}
function snapshot(context) {
  return JSON.parse(run(context, '__pircDocument.snapshot({})'));
}
const backdropPointer = {
  pointerId: 1, pointerType: 'mouse', isPrimary: true,
  clientX: 20, clientY: 200, offsetX: -100, offsetY: -100,
  button: 0, buttons: 1, pressure: 0.5,
  geometry: { left: 120, top: 300, width: 150, height: 100 },
};
function backdropDown(context) {
  const id = snapshot(context).modalDialogIds.at(-1);
  return JSON.parse(run(context,
    `__pircDocument.dispatchModalBackdropPointerDown(${JSON.stringify({id, type: 'pointerdown', eventData: backdropPointer})})`,
  ));
}

test('showModal has browser-compatible state, focus and top-layer snapshot markers', () => {
  const c = setup();
  run(c, 'document.getElementById("outside").focus();document.getElementById("first").showModal()');
  assert.equal(read(c, 'document.activeElement.id'), 'first-control');
  assert.equal(read(c, 'document.getElementById("first").open'), true);
  assert.match(snapshot(c).html, /<dialog[^>]*data-pirc-dialog-modal/);
  run(c, 'document.getElementById("outside").focus()');
  assert.equal(read(c, 'document.activeElement.id'), 'first-control');
  run(c, 'document.getElementById("second").showModal()');
  assert.equal(read(c, 'document.activeElement.id'), 'second-control');
  run(c, 'document.getElementById("first-control").focus()');
  assert.equal(read(c, 'document.activeElement.id'), 'second-control');
  run(c, 'document.getElementById("second").close()');
  assert.equal(read(c, 'document.activeElement.id'), 'first-control');
  run(c, 'document.getElementById("first").close()');
  assert.equal(read(c, 'document.activeElement.id'), 'outside');
  assert.doesNotMatch(snapshot(c).html, /data-pirc-dialog-modal/);
});

test('showModal rejects detached and nonmodal dialogs, and repeat modal is a no-op', () => {
  const c = setup();
  assert.equal(read(c, 'typeof HTMLDialogElement.prototype.showModal'), 'function');
  assert.throws(
    () => run(c, 'HTMLDialogElement.prototype.showModal.call(document.body)'),
    /Illegal invocation/,
  );
  assert.throws(() => run(c, 'document.createElement("dialog").showModal()'), /not in a Document/);
  run(c, 'document.getElementById("first").show()');
  assert.throws(
    () => run(c, 'document.getElementById("first").showModal()'),
    /already open as a non-modal dialog/,
  );
  run(c, 'document.getElementById("first").close()');
  run(c, 'document.getElementById("first").showModal()');
  assert.equal(run(c, 'document.getElementById("first").showModal()'), undefined);
  assert.throws(
    () => run(c, 'document.getElementById("first").show()'),
    /already open as a modal dialog/,
  );
  run(c, 'document.getElementById("first").removeAttribute("open")');
  assert.doesNotMatch(snapshot(c).html, /data-pirc-dialog-modal/);
});

test('platform close request targets only the top modal and respects cancellation', () => {
  const c = setup();
  run(
    c,
    'document.getElementById("first").showModal();document.getElementById("second").showModal()',
  );
  assert.equal(snapshot(c).modalDialogIds.length, 2);
  run(
    c,
    'document.getElementById("second").addEventListener("cancel",event=>event.preventDefault(),{once:true})',
  );
  assert.equal(
    JSON.parse(run(c, '__pircDocument.requestTopModalClose()')).modalCloseRequested,
    true,
  );
  assert.equal(read(c, 'document.getElementById("second").open'), true);
  assert.equal(
    JSON.parse(run(c, '__pircDocument.requestTopModalClose()')).modalCloseRequested,
    true,
  );
  assert.equal(read(c, 'document.getElementById("second").open'), false);
  assert.equal(snapshot(c).modalDialogIds.length, 1);
  assert.equal(
    JSON.parse(run(c, '__pircDocument.requestTopModalClose()')).modalCloseRequested,
    true,
  );
  assert.equal(read(c, 'document.getElementById("first").open'), false);
  assert.equal(
    JSON.parse(run(c, '__pircDocument.requestTopModalClose()')).modalCloseRequested,
    false,
  );
});

test('closedby=none blocks the platform request without a cancel event', () => {
  const c = setup();
  run(
    c,
    'window.cancelCount=0;const d=document.getElementById("first");d.setAttribute("closedby","none");d.addEventListener("cancel",()=>cancelCount++);d.showModal()',
  );
  assert.equal(
    JSON.parse(run(c, '__pircDocument.requestTopModalClose()')).modalCloseRequested,
    true,
  );
  assert.equal(read(c, 'document.getElementById("first").open'), true);
  assert.equal(read(c, 'cancelCount'), 0);
  run(c, 'document.getElementById("first").requestClose()');
  assert.equal(read(c, 'document.getElementById("first").open'), false);
  assert.equal(read(c, 'cancelCount'), 1);
});

test('closedby=any light-dismisses after dialog pointerdown and respects cancel', () => {
  const c = setup();
  run(c, `window.modalEvents=[];
    const d=document.getElementById('first'); d.setAttribute('closedby','any');
    for(const type of ['pointerdown','cancel','beforetoggle'])
      d.addEventListener(type, e=>modalEvents.push(type + (e.newState ? ':' + e.newState : '')));
    d.addEventListener('pointerdown', e=>e.preventDefault()); d.showModal();`);
  assert.equal(backdropDown(c).error, undefined);
  assert.equal(read(c, 'document.getElementById("first").open'), false);
  assert.deepEqual(read(c, 'modalEvents'), [
    'beforetoggle:open', 'pointerdown', 'cancel', 'beforetoggle:closed',
  ]);

  run(c, `modalEvents=[];document.getElementById('first').addEventListener(
    'cancel', e=>e.preventDefault(), {once:true});
    document.getElementById('first').showModal();`);
  backdropDown(c);
  assert.equal(read(c, 'document.getElementById("first").open'), true);
  assert.deepEqual(read(c, 'modalEvents'), ['beforetoggle:open', 'pointerdown', 'cancel']);
});

test('backdrop pointer targets the top modal and only closedby=any dismisses', () => {
  const c = setup();
  run(c, `window.events=[];const first=document.getElementById('first');
    const second=document.getElementById('second');
    first.addEventListener('pointerdown',()=>events.push('first'));
    second.addEventListener('pointerdown',()=>events.push('second'));
    first.showModal();second.showModal();`);
  backdropDown(c);
  assert.deepEqual(read(c, 'events'), ['second']);
  assert.equal(read(c, 'document.getElementById("second").open'), true);
  run(c, `document.getElementById('second').setAttribute('closedby','none')`);
  backdropDown(c);
  assert.equal(read(c, 'document.getElementById("second").open'), true);
  run(c, `document.getElementById('second').setAttribute('closedby','any')`);
  backdropDown(c);
  assert.equal(read(c, 'document.getElementById("second").open'), false);
  assert.equal(read(c, 'document.getElementById("first").open'), true);
  assert.deepEqual(read(c, 'events'), ['second', 'second', 'second']);
});

test('modal backdrop event order matches the fixed Chromium 153 mouse/touch oracle', () => {
  assert.match(backdropOracle.browserVersion, /^153\./);
  for (const browserCase of backdropOracle.cases) {
    const c = setup();
    const declaration = browserCase.closedby == null ? '' :
      `d.setAttribute('closedby',${JSON.stringify(browserCase.closedby)});`;
    run(c, `{const d=document.getElementById('first');${declaration}
      window.backdropLog=[];
      for(const type of ['pointerdown','cancel','beforetoggle','pointerup','click'])
        d.addEventListener(type,event=>{
          backdropLog.push(type);
          if(type==='cancel' && ${browserCase.cancel}) event.preventDefault();
          if(type==='pointerdown' && ${browserCase.preventPointerDown}) event.preventDefault();
        });
      d.showModal();}`);
    run(c, 'backdropLog=[]');
    const id = read(c, 'document.getElementById("first").getAttribute("data-pirc-script-id")');
    const eventData = {
      ...backdropPointer,
      pointerType: browserCase.gesture,
      pointerId: browserCase.gesture === 'touch' ? 3 : 1,
    };
    JSON.parse(run(c, `__pircDocument.dispatchModalBackdropPointerDown(${JSON.stringify({
      id, type: 'pointerdown', eventData,
    })})`));
    JSON.parse(run(c, `__pircDocument.dispatch(${JSON.stringify({
      id, type: 'pointerup', eventData: {...eventData, buttons: 0, pressure: 0},
    })})`));
    if (browserCase.gesture === 'mouse' || read(c, 'document.getElementById("first").open')) {
      JSON.parse(run(c, `__pircDocument.dispatch(${JSON.stringify({
        id, type: 'click', eventData: {...eventData, buttons: 0, pressure: 0},
      })})`));
    }
    assert.equal(read(c, 'document.getElementById("first").open'), browserCase.open,
      browserCase.name);
    assert.deepEqual(read(c, 'backdropLog'), browserCase.events
      .map(event => event.type)
      .filter(type => ['pointerdown','cancel','beforetoggle','pointerup','click'].includes(type)),
    browserCase.name);
  }
});

test('author markup cannot forge a native modal top-layer marker', () => {
  const c = setup();
  run(c, 'document.getElementById("first").setAttribute("data-pirc-dialog-modal","99")');
  assert.doesNotMatch(snapshot(c).html, /data-pirc-dialog-modal/);
  run(c, 'document.getElementById("first").showModal()');
  assert.match(snapshot(c).html, /data-pirc-dialog-modal="1"/);
  run(c, 'document.getElementById("first").close()');
  assert.doesNotMatch(snapshot(c).html, /data-pirc-dialog-modal/);
});

test('removal during beforetoggle does not leave a modal focus lock', () => {
  const c = setup();
  run(
    c,
    'document.getElementById("outside").focus();const d=document.getElementById("first");d.addEventListener("beforetoggle",()=>d.remove());d.showModal()',
  );
  assert.equal(read(c, 'document.activeElement.id'), 'outside');
  assert.equal(snapshot(c).modalDialogIds.length, 0);
  assert.doesNotMatch(snapshot(c).html, /data-pirc-dialog-modal/);
  run(c, 'document.getElementById("second").showModal()');
  assert.equal(read(c, 'document.activeElement.id'), 'second-control');
});
