import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import {
  intoViewModes,
  intoViewHTML,
  intoViewArgument,
  intoViewSetup,
  buildIntoViewDriver,
} from './document_into_view_fixture.mjs';
const fixture = JSON.parse(
  readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-into-view-chromium153.json', import.meta.url)),
);
const bundle = readFileSync(
  process.env.PIRC_DOCUMENT_SCRIPT_RUNTIME_BUNDLE ||
    fileURLToPath(new URL('../../assets/document-script-runtime.js', import.meta.url)),
  'utf8',
);
function runtime(row) {
  const context = vm.createContext({}, { microtaskMode: 'afterEvaluate' }),
    run = (s) => new vm.Script(s).runInContext(context),
    invoke = (m, a) => JSON.parse(run(`__pircDocument.${m}(${JSON.stringify(a)})`));
  run(bundle);
  const initial = invoke('init', {
      hostLayout: true,
      url: 'https://example.test/into-view',
      html: row.html,
    }),
    ids = Object.fromEntries(
      ['root', 'outer', 'inner', 'target'].map((name) => [
        name,
        run(
          `document.querySelector(${JSON.stringify(name === 'root' ? 'html' : '#' + name)})?.getAttribute('data-pirc-script-id')`,
        ),
      ]),
    );
  let generation = 0;
  function packet() {
    const m = structuredClone(row.measurements);
    return {
      revision: invoke('snapshot', {}).layout.revision,
      generation: ++generation,
      scrollActionThrough: 0,
      viewport: {
        ...row.viewport,
        scrollX: 0,
        scrollY: 0,
        contentWidth: m.root.scrollWidth,
        contentHeight: m.root.scrollHeight,
        scrollActive: false,
        scrollBehavior: m.root.style['scroll-behavior'],
        scrollRange: {
          minLeft: 0,
          maxLeft: 0,
          minTop: 0,
          maxTop: m.root.scrollHeight - row.viewport.height,
        },
      },
      boxes: initial.layout.ids.map((id) => {
        const name = Object.keys(ids).find((name) => ids[name] === id),
          v = m[name];
        if (!v || v.style.display === 'none') return { id, kind: 'none' };
        const ancestors =
          name === 'target' ? ['inner', 'outer'] : name === 'inner' ? ['outer'] : [];
        const box = {
          id,
          kind: 'box',
          x: v.rect[0],
          y: v.rect[1],
          width: v.rect[2],
          height: v.rect[3],
          computedStyle: v.style,
          scrollGeometry: {
            viewport: true,
            ancestors: ancestors.map((n) => ({ id: ids[n], axes: m[n].axes })),
          },
        };
        if (['outer', 'inner'].includes(name))
          box.scroll = {
            active: false,
            left: 0,
            top: 0,
            width: v.scrollWidth,
            height: v.scrollHeight,
            range: {
              minLeft: 0,
              maxLeft: v.scrollWidth - v.width,
              minTop: 0,
              maxTop: v.scrollHeight - v.height,
            },
          };
        if (name === 'target')
          box.scrollReveal = {
            viewport: true,
            ports: ['inner', 'outer'].map((n) => ({
              id: ids[n],
              axes: m[n].axes,
              origin: m[n].origin,
              rect: m[n].targetRect,
              width: m[n].width,
              height: m[n].height,
            })),
          };
        return box;
      }),
    };
  }
  invoke('updateLayout', packet());
  return { run, invoke, packet, ids };
}
function close(actual, expected, label) {
  if (typeof expected === 'number') {
    assert.ok(Math.abs(actual - expected) <= 1 / 32, `${label}: ${actual} != ${expected}`);
    return;
  }
  if (Array.isArray(expected)) {
    assert.equal(actual.length, expected.length, label);
    expected.forEach((v, i) => close(actual[i], v, `${label}[${i}]`));
    return;
  }
  if (expected && typeof expected === 'object') {
    assert.deepEqual(Object.keys(actual), Object.keys(expected), label);
    for (const [key, v] of Object.entries(expected)) close(actual[key], v, `${label}.${key}`);
    return;
  }
  assert.equal(actual, expected, label);
}
test('216 independent scrollIntoView profiles keep exact browser sources', () => {
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.equal(fixture.cases.length, 216);
  assert.equal(intoViewModes.length, 27);
  assert.equal(
    new Set(fixture.cases.map((r) => [r.mode, r.viewport.width, r.dpr, r.theme].join('/'))).size,
    216,
  );
  for (const row of fixture.cases) {
    assert.equal(row.html, intoViewHTML(row.mode));
    assert.equal(row.driverSource, buildIntoViewDriver(row.mode));
    assert.deepEqual(row.argument, intoViewArgument(row.mode));
    assert.deepEqual(row.setup, intoViewSetup(row.mode));
  }
});
for (const row of fixture.cases.filter((r) => !['append-await', 'contract'].includes(r.mode))) {
  test(`shipped scrollIntoView ${row.mode}/${row.viewport.width}/${row.dpr}/${row.theme}`, () => {
    const { run, invoke, ids, packet } = runtime(row),
      label = `${row.mode}/${row.viewport.width}`;
    run(
      `window.target=document.getElementById('target');window.outer=document.getElementById('outer');window.inner=document.getElementById('inner');window.read=()=>{const r=target.getBoundingClientRect();return {positions:{root:{left:scrollX,top:scrollY},outer:{left:outer.scrollLeft,top:outer.scrollTop},inner:{left:inner.scrollLeft,top:inner.scrollTop}},rect:[r.x,r.y,r.width,r.height].map(v=>+v.toFixed(4))}}`,
    );
    if (row.setup)
      run(
        `window.scrollTo({top:${row.setup.root},behavior:'instant'});outer.scrollTo({left:${row.setup.outer[0]},top:${row.setup.outer[1]},behavior:'instant'});inner.scrollTo({left:${row.setup.inner[0]},top:${row.setup.inner[1]},behavior:'instant'})`,
      );
    close(JSON.parse(run('JSON.stringify(read())')), row.result.before, `${label}.before`);
    const arg = row.argument,
      call =
        arg.kind === 'omitted'
          ? 'target.scrollIntoView()'
          : `target.scrollIntoView(${JSON.stringify(arg.value)})`;
    run(
      `window.promise=${row.mode === 'replacement' ? "target.scrollIntoView({behavior:'smooth',block:'start'});window.replacement=target.scrollIntoView({behavior:'instant',block:'end',inline:'end'})" : call};window.promise.then(value=>window.resolved=value,error=>window.rejected={name:error.name,message:error.message})`,
    );
    assert.equal(run('JSON.stringify(window.rejected)'), undefined, label);
    assert.equal(run('typeof promise.then'), 'function');
    if (!['smooth', 'css-smooth'].includes(row.mode))
      assert.deepEqual(JSON.parse(run('JSON.stringify(resolved)')), row.result.value);
    close(JSON.parse(run('JSON.stringify(read())')), row.result.immediate, `${label}.immediate`);
    const actions = invoke('snapshot', {}).scrollActions,
      settled = {
        root: { left: 0, top: 0 },
        outer: { left: 0, top: 0 },
        inner: { left: 0, top: 0 },
      };
    for (const action of actions) {
      const name = !action.elementId
        ? 'root'
        : Object.keys(ids).find((n) => ids[n] === action.elementId);
      assert.ok(name, JSON.stringify(action));
      if (action.x != null) settled[name].left = action.x;
      if (action.y != null) settled[name].top = action.y;
    }
    const expected = structuredClone(row.result.settled.positions);
    // Chromium may retain a root smooth animation when a following instant
    // request is already at zero. Native cancellation intentionally stays at the
    // requested instant endpoint; retain this timing difference explicitly.
    if (row.mode === 'replacement') expected.root = row.result.immediate.positions.root;
    assert.deepEqual(settled, expected, `${label}.planned destinations`);
    if (['smooth', 'css-smooth'].includes(row.mode)) {
      assert.equal(run('window.resolved'), undefined, 'wait for actual native completion');
      const p = packet();
      p.scrollActionThrough = actions.at(-1).actionId;
      p.viewport.scrollY = settled.root.top;
      for (const name of ['outer', 'inner'])
        Object.assign(p.boxes.find((b) => b.id === ids[name]).scroll, settled[name]);
      invoke('updateLayout', p);
      invoke('pump', { animationFrame: true, now: 300 });
      assert.deepEqual(JSON.parse(run('JSON.stringify(resolved)')), row.result.value);
    }
  });
}
test('Chromium Promise conversion, descriptors, receiver errors and getter ordering', () => {
  for (const row of fixture.cases.filter((r) => r.mode === 'contract')) {
    const { run } = runtime(row);
    run(row.driverSource);
    run(`document.getElementById('run').click()`);
    assert.deepEqual(JSON.parse(run(`document.getElementById('probe').textContent`)), row.result);
  }
});
test('scroll reveal metadata rejects malformed, missing and nonancestor proofs atomically', () => {
  const row = fixture.cases.find((r) => r.mode === 'center');
  for (const mutate of [
    (p) => p.ports.reverse(),
    (p) => p.ports.push(p.ports[0]),
    (p) => (p.ports[0].axes = [1, 0, 0, 0]),
    (p) => (p.ports[0].width = -1),
    (p) => (p.ports[0].rect[2] = -1),
    (p) => (p.ports[0].id = 'missing'),
    (p) => (p.viewport = false),
    (p) => (p.ports[0].axes = [2, 0, 0, 2]),
    (p) => (p.ports = []),
  ]) {
    const { invoke, packet, ids } = runtime(row),
      p = packet(),
      box = p.boxes.find((b) => b.id === ids.target);
    mutate(box.scrollReveal);
    assert.throws(() => invoke('updateLayout', p));
  }
  const { run, invoke, packet, ids } = runtime(row),
    p = packet();
  delete p.boxes.find((b) => b.id === ids.target).scrollReveal;
  invoke('updateLayout', p);
  run(`document.getElementById('target').scrollIntoView().catch(e=>window.error=e.name)`);
  assert.equal(run('window.error'), 'NotSupportedError');
  assert.deepEqual(invoke('snapshot', {}).scrollActions, []);
});

test('smooth reveals wait for native activity and report a real user interruption', () => {
  const row = fixture.cases.find((r) => r.mode === 'smooth'),
    { run, invoke, packet, ids } = runtime(row);
  run(
    `document.getElementById('target').scrollIntoView({behavior:'smooth'}).then(v=>window.completed=v)`,
  );
  const actions = invoke('snapshot', {}).scrollActions,
    through = actions.at(-1).actionId;
  const moving = packet();
  moving.scrollActionThrough = through;
  moving.viewport.scrollActive = true;
  for (const name of ['outer', 'inner'])
    moving.boxes.find((b) => b.id === ids[name]).scroll.active = true;
  invoke('updateLayout', moving);
  invoke('pump', { animationFrame: true, now: 100 });
  assert.equal(run('window.completed'), undefined);
  assert.equal(
    invoke('snapshot', {}).layout.required,
    true,
    'a stopped animation must refresh activity even when pixels did not change',
  );
  const stopped = packet();
  stopped.scrollActionThrough = through;
  stopped.viewport.scrollY = 10;
  invoke('updateLayout', stopped);
  invoke('pump', { animationFrame: true, now: 200 });
  assert.deepEqual(JSON.parse(run('JSON.stringify(completed)')), { interrupted: true });
});
test('a reveal batch refuses a full queue without partially scrolling ancestors', () => {
  const row = fixture.cases.find((r) => r.mode === 'center'),
    { run, invoke } = runtime(row);
  run(
    `for(let i=0;i<127;i++)window.scrollTo({top:0,behavior:'instant'});document.getElementById('target').scrollIntoView({behavior:'instant'}).catch(e=>window.error=e.name)`,
  );
  assert.equal(run('window.error'), 'RangeError');
  assert.equal(invoke('snapshot', {}).scrollActions.length, 127);
});
test('nearest includes a genuine zero-range scroll container and does not scroll parents', () => {
  const row = fixture.cases.find((r) => r.mode === 'nearest-container'),
    { run, invoke, packet, ids } = runtime(row),
    p = packet();
  const inner = p.boxes.find((b) => b.id === ids.inner);
  inner.scroll.range = { minLeft: 0, maxLeft: 0, minTop: 0, maxTop: 0 };
  invoke('updateLayout', p);
  run(`document.getElementById('target').scrollIntoView({container:'nearest',behavior:'instant'})`);
  const actions = invoke('snapshot', {}).scrollActions;
  assert.equal(actions.length, 1);
  assert.equal(actions[0].elementId, ids.inner);
  assert.equal(actions[0].x, 0);
  assert.equal(actions[0].y, 0);
});
