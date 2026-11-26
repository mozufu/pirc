import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';
const bundle = readFileSync(
  process.env.PIRC_DOCUMENT_SCRIPT_RUNTIME_BUNDLE ||
    new URL('../../assets/document-script-runtime.js', import.meta.url),
  'utf8',
);
const fixture = JSON.parse(
  readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-resize-chromium153.json', import.meta.url), 'utf8'),
);
function create(html = fixture.html) {
  const context = vm.createContext({}, { microtaskMode: 'afterEvaluate' });
  new vm.Script(bundle).runInContext(context);
  const evaluate = (code) => new vm.Script(code).runInContext(context);
  const invoke = (method, value) =>
    JSON.parse(evaluate('__pircDocument.' + method + '(' + JSON.stringify(value) + ')'));
  const initial = invoke('init', { url: 'https://example.test/resize', hostLayout: true, html });
  return { context, evaluate, invoke, initial };
}
function packet(runtime, response, generation, boxes = []) {
  const byId = new Map(
    boxes.map((box) => [
      runtime.evaluate(
        'document.getElementById(' +
          JSON.stringify(box.id) +
          ').getAttribute("data-pirc-script-id")',
      ),
      box,
    ]),
  );
  return {
    revision: response.layout.revision,
    generation,
    viewport: { width: 390, height: 844, scrollX: 0, scrollY: 0 },
    boxes: response.layout.ids.map((id) => ({
      id,
      kind: 'none',
      ...(byId.has(id) ? { ...byId.get(id), id } : { resize: { kind: 'none' } }),
    })),
  };
}
function plain(value) {
  return JSON.parse(JSON.stringify(value));
}
for (const capture of fixture.records) {
  test(`native frame delivery matches Chromium ${capture.viewport.width}px lifecycle and box semantics`, () => {
    const r = create();
    r.evaluate(fixture.setup);
    let response = r.initial,
      gen = 0;
    for (let i = 0; i < fixture.steps.length; i++) {
      const step = fixture.steps[i],
        stage = capture.stages[i];
      r.evaluate('window.phase=' + JSON.stringify(step.name) + ';' + step.code);
      response = r.invoke('snapshot', {});
      response = r.invoke('updateLayout', packet(r, response, ++gen, stage.boxes));
      response = r.invoke('pump', { now: i * 20, animationFrame: true });
      assert.deepEqual(plain(r.evaluate('window.events.splice(0)')), stage.events, step.name);
      assert.equal(
        response.scheduler.animationFrame,
        false,
        'no busy frame polling after delivery',
      );
      assert.equal(
        response.diagnostics.filter((d) => d.code.startsWith('resize_observer.')).length,
        0,
      );
    }
  });
}
const box = (width = 100) => ({
  id: 'target',
  kind: 'box',
  x: 0,
  y: 0,
  width,
  height: 40,
  resize: {
    kind: 'box',
    contentRect: { x: 0, y: 0, width, height: 40 },
    borderBoxSize: { inlineSize: width, blockSize: 40 },
  },
});
function ready() {
  const r = create();
  r.invoke('updateLayout', packet(r, r.initial, 1, [box()]));
  return r;
}
test('registration is asynchronous, requires a native frame, and leaves authored geometry unchanged', () => {
  const r = create();
  r.evaluate(fixture.setup);
  assert.equal(r.evaluate('window.events.length'), 0);
  let out = r.invoke('pump', { animationFrame: true, now: 0 });
  assert.equal(r.evaluate('window.events.length'), 0);
  out = r.invoke('updateLayout', packet(r, out, 1, [box()]));
  assert.equal(r.evaluate('window.events.length'), 0);
  assert.equal(out.scheduler.animationFrame, true);
  r.invoke('pump', { animationFrame: true, now: 16 });
  assert.equal(r.evaluate('window.events.length'), 4);
  assert.equal(r.evaluate('document.getElementById("target").getAttribute("style")'), null);
});
test('callback mutations use a later measured frame; entries for other observers retain the original snapshot', () => {
  const r = ready();
  r.evaluate(`window.widths=[];window.once=false;
 new ResizeObserver(es=>{window.widths.push(['a',es[0].contentRect.width]);if(!window.once){window.once=true;document.getElementById('target').style.width='120px'}}).observe(document.getElementById('target'));
 new ResizeObserver(es=>window.widths.push(['b',es[0].contentRect.width])).observe(document.getElementById('target'));`);
  let out = r.invoke('pump', { animationFrame: true, now: 0 });
  assert.deepEqual(plain(r.evaluate('window.widths')), [
    ['a', 100],
    ['b', 100],
  ]);
  assert.equal(out.layout.required, true);
  out = r.invoke('updateLayout', packet(r, out, 2, [box(120)]));
  r.invoke('pump', { animationFrame: true, now: 16 });
  assert.deepEqual(plain(r.evaluate('window.widths')), [
    ['a', 100],
    ['b', 100],
    ['a', 120],
    ['b', 120],
  ]);
});
test('callback errors stay diagnostic without suppressing other active observers', () => {
  const r = ready();
  r.evaluate(`window.calls=[];var first=new ResizeObserver(()=>{window.calls.push('first');throw new Error('observer boom')});
 var second=new ResizeObserver(()=>window.calls.push('second'));first.observe(document.getElementById('target'));
 second.observe(document.getElementById('target'));`);
  const out = r.invoke('pump', { animationFrame: true });
  assert.deepEqual(plain(r.evaluate('window.calls')), ['first', 'second']);
  assert.match(
    out.diagnostics.find((d) => d.code === 'resize_observer.callback_error').message,
    /observer boom/,
  );
});
test('missing native content edges report once, withhold entries, and recover when data arrives', () => {
  const r = ready();
  r.evaluate(
    `window.calls=0;new ResizeObserver(()=>window.calls++).observe(document.getElementById('target'))`,
  );
  let out = r.invoke(
    'updateLayout',
    packet(r, r.invoke('snapshot', {}), 2, [{ ...box(), resize: undefined }]),
  );
  out = r.invoke('pump', { animationFrame: true });
  assert.equal(r.evaluate('window.calls'), 0);
  assert.equal(out.diagnostics.filter((d) => d.code === 'resize_observer.unavailable').length, 1);
  out = r.invoke('updateLayout', packet(r, out, 3, [box()]));
  r.invoke('pump', { animationFrame: true });
  assert.equal(r.evaluate('window.calls'), 1);
});
test('removed targets report zero after layout acceptance and reinserted targets report their measured size', () => {
  const r = ready();
  r.evaluate(
    `window.values=[];window.target=document.getElementById('target');new ResizeObserver(es=>window.values.push(es[0].contentRect.width)).observe(window.target)`,
  );
  let out = r.invoke('pump', { animationFrame: true });
  r.evaluate('window.target.remove()');
  out = r.invoke('snapshot', {});
  out = r.invoke('updateLayout', packet(r, out, 2, []));
  r.invoke('pump', { animationFrame: true });
  r.evaluate('document.body.appendChild(window.target)');
  out = r.invoke('snapshot', {});
  r.invoke('updateLayout', packet(r, out, 3, [box()]));
  r.invoke('pump', { animationFrame: true });
  assert.deepEqual(plain(r.evaluate('window.values')), [100, 0, 100]);
});
test('malformed resize data rejects the whole packet without replacing the accepted frame', () => {
  const r = ready();
  let out = r.invoke('snapshot', {});
  const invalid = box(120);
  invalid.resize.contentRect.width = -1;
  assert.throws(() => r.invoke('updateLayout', packet(r, out, 2, [invalid])), /nonnegative/);
  assert.equal(r.evaluate('document.getElementById("target").getBoundingClientRect().width'), 100);
  r.invoke('updateLayout', packet(r, out, 2, [box(120)]));
  assert.equal(r.evaluate('document.getElementById("target").getBoundingClientRect().width'), 120);
});
test('argument checks, receiver brands, readonly entries, and explicit unsupported device pixel observations', () => {
  const r = ready();
  r.evaluate(
    'window.values=[];window.observer=new ResizeObserver(es=>window.values.push(es[0]));window.observer.observe(document.getElementById("target"))',
  );
  for (const code of [
    'new ResizeObserver()',
    'ResizeObserver(()=>{})',
    'new ResizeObserverEntry()',
    'new ResizeObserverSize()',
    'observer.observe(null)',
    'observer.observe(document)',
    'observer.observe(document.body,{box:"bad"})',
    'ResizeObserver.prototype.disconnect.call({})',
  ])
    assert.throws(() => r.evaluate(code), /TypeError|constructor/);
  assert.throws(
    () => r.evaluate('observer.observe(document.body,{box:"device-pixel-content-box"})'),
    /device-pixel/,
  );
  r.invoke('pump', { animationFrame: true });
  assert.throws(() => r.evaluate('window.values[0].devicePixelContentBoxSize'), /device-pixel/);
  assert.throws(() => r.evaluate('"use strict";window.values[0].target=null'), /TypeError/);
  assert.throws(
    () => r.evaluate('"use strict";window.values[0].contentBoxSize[0].inlineSize=0'),
    /TypeError/,
  );
  assert.equal(r.evaluate('window.ResizeObserver===ResizeObserver'), true);
});

test('options are read once and observer limits release capacity on disconnect', () => {
  const r = ready();
  r.evaluate(
    `window.reads=0;window.observer=new ResizeObserver(()=>{});observer.observe(document.getElementById('target'),{get box(){window.reads++;return 'content-box'}})`,
  );
  assert.equal(r.evaluate('window.reads'), 1);
  r.evaluate(
    `window.observers=[];for(let i=1;i<256;i++){const o=new ResizeObserver(()=>{});o.observe(document.getElementById('target'));window.observers.push(o)}`,
  );
  assert.throws(
    () => r.evaluate(`new ResizeObserver(()=>{}).observe(document.getElementById('target'))`),
    /limit/,
  );
  r.evaluate(
    `observer.disconnect();new ResizeObserver(()=>{}).observe(document.getElementById('target'))`,
  );
});
test('global target limit cannot be bypassed by changing boxes and capacity is restored by unobserve', () => {
  const r = ready();
  r.evaluate(
    `window.observer=new ResizeObserver(()=>{});window.targets=[];for(let i=0;i<5000;i++){const e=document.createElement('div');window.targets.push(e);observer.observe(e)}`,
  );
  assert.throws(() => r.evaluate(`observer.observe(document.body)`), /limit/);
  r.evaluate(
    `observer.observe(window.targets[0],{box:'border-box'});observer.unobserve(window.targets[1]);observer.observe(document.body)`,
  );
  assert.throws(() => r.evaluate(`observer.observe(document.documentElement)`), /limit/);
  r.evaluate('observer.disconnect();observer.observe(document.documentElement)');
});

for (const op of ['disconnect', 'unobserve', 'reobserve']) {
  test(`callback ${op} matches Chromium without duplicate or cancelled entries`, () => {
    const r = ready();
    r.evaluate(
      `window.calls=[];var target=document.getElementById('target');var first=new ResizeObserver(()=>{window.calls.push('first');if('${op}'==='disconnect')second.disconnect();if('${op}'==='unobserve')second.unobserve(target);if('${op}'==='reobserve')second.observe(target,{box:'border-box'})});var second=new ResizeObserver(()=>window.calls.push('second'));first.observe(target);second.observe(target)`,
    );
    r.invoke('pump', { animationFrame: true });
    r.invoke('pump', { animationFrame: true });
    assert.deepEqual(plain(r.evaluate('window.calls')), fixture.callbackInteractions[op]);
  });
}
