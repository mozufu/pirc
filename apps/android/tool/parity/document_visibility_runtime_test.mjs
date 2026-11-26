import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
const bundle = readFileSync(
  new URL('../../assets/document-script-runtime.js', import.meta.url),
  'utf8',
);
function create(hidden = false) {
  const context = vm.createContext({}, { microtaskMode: 'afterEvaluate' });
  const evaluate = (source) => vm.runInContext(source, context);
  evaluate(bundle);
  const call = (method, value = {}) =>
    JSON.parse(evaluate('__pircDocument.' + method + '(' + JSON.stringify(value) + ')'));
  call('init', { html: '<p id="result"></p>', url: 'https://example.test/visibility', hidden });
  const read = (source) => JSON.parse(evaluate('JSON.stringify(' + source + ')'));
  return { evaluate, call, read };
}
test('visibility is initialized before scripts and stays read-only', () => {
  for (const hidden of [false, true]) {
    const r = create(hidden);
    assert.deepEqual(
      r.read('[document.hidden,document.visibilityState,document.onvisibilitychange]'),
      [hidden, hidden ? 'hidden' : 'visible', null],
    );
    assert.throws(() => r.evaluate('"use strict";document.hidden=false'), /TypeError/);
    assert.throws(() => r.evaluate('"use strict";document.visibilityState="visible"'), /TypeError/);
  }
});
test('host visibility edges are trusted, bubble through Window and retain both fast transitions', () => {
  const r = create();
  r.evaluate(`window.events=[];
  function record(name,e){events.push({name,hidden:document.hidden,state:document.visibilityState,target:e.target===document,current:e.currentTarget===document?'document':'window',phase:e.eventPhase,bubbles:e.bubbles,cancelable:e.cancelable,composed:e.composed,trusted:e.isTrusted});e.preventDefault();}
  window.addEventListener('visibilitychange',e=>record('capture',e),true);
  document.addEventListener('visibilitychange',e=>record('document',e));
  document.onvisibilitychange=function(e){record('property',e);events.push({thisDocument:this===document});};
  window.addEventListener('visibilitychange',e=>record('bubble',e));`);
  r.call('updateVisibility', { hidden: true, now: 20 });
  r.call('updateVisibility', { hidden: true, now: 21 });
  r.call('updateVisibility', { hidden: false, now: 22 });
  const events = r.read('events');
  assert.equal(events.length, 10);
  for (const [offset, hidden] of [
    [0, true],
    [5, false],
  ]) {
    assert.deepEqual(
      events.slice(offset, offset + 5).map((e) => e.name ?? 'this'),
      ['capture', 'document', 'property', 'this', 'bubble'],
    );
    for (const i of [0, 1, 2, 4]) {
      const e = events[offset + i];
      assert.equal(e.hidden, hidden);
      assert.equal(e.state, hidden ? 'hidden' : 'visible');
      assert.equal(e.target, true);
      assert.equal(e.bubbles, true);
      assert.equal(e.cancelable, false);
      assert.equal(e.composed, false);
      assert.equal(e.trusted, true);
    }
    assert.equal(events[offset + 3].thisDocument, true);
  }
});
test('visibility callbacks preserve once, abort, exceptions, handler replacement and Promise work', () => {
  const r = create();
  r.evaluate(`window.events=[];var stop=new AbortController();
 document.addEventListener('visibilitychange',()=>events.push('aborted'),{signal:stop.signal});stop.abort();
 document.addEventListener('visibilitychange',()=>{events.push('once');throw new Error('visibility failure')},{once:true});
 document.onvisibilitychange=()=>events.push('replaced');
 document.onvisibilitychange=()=>{events.push(document.visibilityState);Promise.resolve().then(()=>document.getElementById('result').textContent=document.visibilityState)};`);
  let out = r.call('updateVisibility', { hidden: true });
  assert.deepEqual(r.read('events'), ['once', 'hidden']);
  assert.equal(r.read('document.getElementById("result").textContent'), 'hidden');
  assert.equal(
    out.diagnostics.filter((d) => d.code === 'script.visibility_listener_error').length,
    1,
  );
  r.call('updateVisibility', { hidden: false });
  assert.deepEqual(r.read('events'), ['once', 'hidden', 'visible']);
  r.evaluate('document.onvisibilitychange=null');
  r.call('updateVisibility', { hidden: true });
  assert.deepEqual(r.read('events'), ['once', 'hidden', 'visible']);
});
test('publishing visibility neither runs timers nor advances a selected native frame', () => {
  const r = create();
  r.evaluate(
    `window.events=[];setTimeout(()=>events.push('timer'),0);requestAnimationFrame(()=>events.push('first'));requestAnimationFrame(()=>events.push('second'));document.onvisibilitychange=()=>events.push(document.visibilityState);`,
  );
  let out = r.call('pump', { now: 10, animationFrame: true, nativeFrameSteps: true });
  const id = out.frameContinuation.id;
  out = r.call('updateVisibility', { hidden: true, now: 20 });
  assert.equal(out.frameContinuation.id, id);
  assert.deepEqual(r.read('events'), ['first', 'hidden']);
  r.call('updateVisibility', { hidden: false, now: 30 });
  assert.deepEqual(r.read('events'), ['first', 'hidden', 'visible']);
  r.call('continueAnimationFrame', { id });
  r.call('continueAnimationFrame', { id });
  r.call('pump', { now: 40, animationFrame: false });
  assert.deepEqual(r.read('events'), ['first', 'hidden', 'visible', 'second', 'timer']);
});
test('visibility properties and synthetic event propagation match pinned Chromium', () => {
  const fixture = JSON.parse(
    readFileSync(
      new URL('../../../../packages/pirc_render/test/fixtures/parity/document-visibility-chromium153.json', import.meta.url),
      'utf8',
    ),
  );
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  const r = create();
  assert.deepEqual(r.read(fixture.probe), fixture.result);
});
