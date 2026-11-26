import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import vm from 'node:vm';

const sourcePath = fileURLToPath(
  new URL('./document_canvas_source.js', import.meta.url),
);
const source = readFileSync(sourcePath, 'utf8');

class FakeCanvas {
  constructor(ownerDocument, connected, initialAttributes = {}) {
    this.ownerDocument = ownerDocument;
    this.isConnected = Boolean(connected);
    this.attributes = new Map(
      Object.entries(initialAttributes).map(([name, value]) => [name.toLowerCase(), String(value)]),
    );
  }

  getAttribute(name) {
    const key = String(name).toLowerCase();
    return this.attributes.has(key) ? this.attributes.get(key) : null;
  }

  hasAttribute(name) {
    return this.attributes.has(String(name).toLowerCase());
  }

  setAttribute(name, value) {
    this.attributes.set(String(name).toLowerCase(), String(value));
  }

  removeAttribute(name) {
    this.attributes.delete(String(name).toLowerCase());
  }

  toggleAttribute(name, force) {
    const key = String(name).toLowerCase();
    const next = arguments.length < 2 ? !this.attributes.has(key) : Boolean(force);
    if (next) this.attributes.set(key, '');
    else this.attributes.delete(key);
    return next;
  }
}

class FakeDocument {
  constructor() {
    this.canvases = [];
  }

  createElement(name) {
    if (String(name).toLowerCase() !== 'canvas')
      throw new TypeError('This fixture only creates canvas elements.');
    const canvas = new FakeCanvas(this, false);
    this.canvases.push(canvas);
    return canvas;
  }

  addCanvas(attributes = {}) {
    const canvas = new FakeCanvas(this, true, attributes);
    this.canvases.push(canvas);
    return canvas;
  }

  querySelectorAll(selector) {
    return selector === 'canvas'
      ? this.canvases.filter((canvas) => canvas.isConnected)
      : [];
  }
}

function createRecorder() {
  const vmContext = vm.createContext({});
  new vm.Script(source + '\nthis.__createDocumentCanvas = createDocumentCanvas;')
    .runInContext(vmContext);
  const document = new FakeDocument();
  const diagnostics = [];
  const ids = new WeakMap();
  let nextId = 1;
  const recorder = vmContext.__createDocumentCanvas({
    document,
    ensureElementId(canvas) {
      let id = ids.get(canvas);
      if (!id) {
        id = 'canvas-' + nextId++;
        ids.set(canvas, id);
        canvas.setAttribute('data-pirc-script-id', id);
      }
      return id;
    },
    diagnostic(...args) {
      diagnostics.push(args);
    },
  });
  recorder.install();
  return { document, recorder, diagnostics };
}

function snapshots(recorder) {
  return JSON.parse(JSON.stringify(recorder.snapshots()));
}

test('connected blank canvases get stable IDs and a persistent default 2D context', () => {
  const { document, recorder, diagnostics } = createRecorder();
  const canvas = document.addCanvas();

  assert.deepEqual(snapshots(recorder), [{
    id: 'canvas-1',
    width: 300,
    height: 150,
    revision: 0,
    commands: [],
  }]);

  const context = canvas.getContext('2d');
  assert.strictEqual(context.canvas, canvas);
  assert.strictEqual(canvas.getContext('2d'), context);
  assert.equal(context.fillStyle, '#000000');
  assert.equal(context.strokeStyle, '#000000');
  assert.equal(context.globalAlpha, 1);
  assert.equal(context.globalCompositeOperation, 'source-over');
  assert.equal(context.lineWidth, 1);
  assert.deepEqual(Array.from(context.getLineDash()), []);
  assert.equal(canvas.getContext('webgl'), null);
  assert.equal(snapshots(recorder)[0].id, 'canvas-1');
  assert.ok(diagnostics.some(([code]) => code === 'canvas.unsupported_context'));
});

test('draw commands preserve order, path construction transforms, state, and clipping', () => {
  const { document, recorder } = createRecorder();
  const canvas = document.addCanvas({ width: 120, height: 80 });
  const context = canvas.getContext('2d');

  context.translate(10, 5);
  context.beginPath();
  context.moveTo(1, 2);
  context.lineTo(3, 4);
  context.save();
  context.scale(2, 3);
  context.quadraticCurveTo(5, 6, 7, 8);
  context.restore();
  context.bezierCurveTo(9, 10, 11, 12, 13, 14);
  context.closePath();
  context.fillStyle = 'tomato';
  context.globalAlpha = 0.6;
  context.globalCompositeOperation = 'multiply';
  context.setLineDash([2, 3, 4]);
  context.lineDashOffset = 1.5;
  context.fill('evenodd');

  context.save();
  context.resetTransform();
  context.beginPath();
  context.rect(5, 6, 20, 10);
  context.clip('evenodd');
  context.fillRect(0, 0, 120, 80);
  context.clearRect(0, 0, 120, 80);
  context.restore();

  const result = snapshots(recorder)[0];
  assert.deepEqual(result.commands.map(({ op }) => op), [
    'fill', 'fillRect', 'clearRect',
  ]);
  const fill = result.commands[0];
  assert.deepEqual(fill.args, ['evenodd']);
  assert.deepEqual(fill.state.transform, [1, 0, 0, 1, 10, 5]);
  assert.equal(fill.state.fillStyle, 'tomato');
  assert.equal(fill.state.globalAlpha, 0.6);
  assert.equal(fill.state.globalCompositeOperation, 'multiply');
  assert.deepEqual(fill.state.lineDash, [2, 3, 4, 2, 3, 4]);
  assert.equal(fill.state.lineDashOffset, 1.5);
  assert.deepEqual(fill.state.path.map(({ op }) => op), [
    'moveTo', 'lineTo', 'quadraticCurveTo', 'bezierCurveTo', 'closePath',
  ]);
  assert.deepEqual(fill.state.path[0].transform, [1, 0, 0, 1, 10, 5]);
  assert.deepEqual(fill.state.path[2].transform, [2, 0, 0, 3, 10, 5]);
  assert.deepEqual(fill.state.path[3].transform, [1, 0, 0, 1, 10, 5]);
  assert.equal(result.commands[1].state.clips.length, 1);
  assert.deepEqual(result.commands[1].state.clips[0].path[0], {
    op: 'rect',
    args: [5, 6, 20, 10],
    transform: [1, 0, 0, 1, 0, 0],
  });
  assert.equal(result.commands[2].state.clips.length, 1);
});

test('gradients preserve creation transforms and dash state is copied into draws', () => {
  const { document, recorder } = createRecorder();
  const canvas = document.addCanvas();
  const context = canvas.getContext('2d');

  context.translate(4, 6);
  const linear = context.createLinearGradient(0, 0, 20, 0);
  linear.addColorStop(0, '#123456');
  linear.addColorStop(1, 'white');
  const radial = context.createRadialGradient(2, 3, 0, 4, 5, 8);
  radial.addColorStop(0.5, 'blue');
  context.fillStyle = linear;
  context.strokeStyle = radial;
  context.setLineDash([3, 2, 1]);
  context.resetTransform();
  context.fillRect(1, 2, 30, 40);
  context.strokeRect(5, 6, 7, 8);

  const commands = snapshots(recorder)[0].commands;
  assert.equal(commands[0].state.fillStyle.type, 'linear');
  assert.deepEqual(commands[0].state.fillStyle.args, [0, 0, 20, 0]);
  assert.deepEqual(commands[0].state.fillStyle.transform, [1, 0, 0, 1, 4, 6]);
  assert.deepEqual(commands[0].state.fillStyle.stops, [
    { offset: 0, color: '#123456' },
    { offset: 1, color: 'white' },
  ]);
  assert.deepEqual(commands[0].state.transform, [1, 0, 0, 1, 0, 0]);
  assert.deepEqual(commands[0].state.lineDash, [3, 2, 1, 3, 2, 1]);
  assert.equal(commands[1].state.strokeStyle.type, 'radial');
  assert.deepEqual(commands[1].state.strokeStyle.args, [2, 3, 0, 4, 5, 8]);
  assert.deepEqual(commands[1].state.strokeStyle.transform, [1, 0, 0, 1, 4, 6]);
  assert.deepEqual(Array.from(context.getLineDash()), [3, 2, 1, 3, 2, 1]);
});

test('full clear prunes prior display-list commands only without a transform or clip', () => {
  const { document, recorder } = createRecorder();
  const canvas = document.addCanvas({ width: 50, height: 40 });
  const context = canvas.getContext('2d');

  context.fillRect(1, 1, 5, 5);
  context.save();
  context.beginPath();
  context.rect(0, 0, 10, 10);
  context.clip();
  context.clearRect(0, 0, 50, 40);
  assert.deepEqual(snapshots(recorder)[0].commands.map(({ op }) => op), [
    'fillRect', 'clearRect',
  ]);
  context.restore();
  context.resetTransform();
  context.clearRect(0, 0, 50, 40);
  const result = snapshots(recorder)[0];
  assert.deepEqual(result.commands.map(({ op }) => op), ['clearRect']);
});

test('canvas resize resets pixels and drawing state even for the same dimension', () => {
  const { document, recorder } = createRecorder();
  const canvas = document.addCanvas({ width: 64, height: 32 });
  const context = canvas.getContext('2d');

  context.fillStyle = 'red';
  context.lineWidth = 9;
  context.translate(12, 13);
  context.fillRect(0, 0, 10, 10);
  const before = snapshots(recorder)[0];
  canvas.width = 64;
  const afterWidth = snapshots(recorder)[0];

  assert.strictEqual(canvas.getContext('2d'), context);
  assert.equal(afterWidth.width, 64);
  assert.equal(afterWidth.revision, before.revision + 1);
  assert.deepEqual(afterWidth.commands, []);
  assert.equal(context.fillStyle, '#000000');
  assert.equal(context.lineWidth, 1);
  assert.deepEqual(Array.from(context.getLineDash()), []);
  context.fillRect(0, 0, 1, 1);
  canvas.setAttribute('height', '32');
  const afterAttribute = snapshots(recorder)[0];
  assert.equal(afterAttribute.height, 32);
  assert.deepEqual(afterAttribute.commands, []);
  assert.equal(afterAttribute.revision, afterWidth.revision + 2);
});

test('text commands keep requested font and alignment; metrics and image APIs fail explicitly', () => {
  const { document, recorder, diagnostics } = createRecorder();
  const canvas = document.addCanvas();
  const context = canvas.getContext('2d');

  context.font = 'bold 16px sans-serif';
  context.textAlign = 'center';
  context.textBaseline = 'middle';
  context.direction = 'rtl';
  context.fillText('Label', 20, 30);
  context.strokeText('Outline', 40, 50, 70);

  const commands = snapshots(recorder)[0].commands;
  assert.deepEqual(commands.map(({ op }) => op), ['fillText', 'strokeText']);
  assert.deepEqual(commands[0].args, ['Label', 20, 30]);
  assert.deepEqual(commands[1].args, ['Outline', 40, 50, 70]);
  assert.equal(commands[1].state.font, 'bold 16px sans-serif');
  assert.equal(commands[1].state.textAlign, 'center');
  assert.equal(commands[1].state.textBaseline, 'middle');
  assert.equal(commands[1].state.direction, 'rtl');
  assert.throws(() => context.measureText('text'), { name: 'NotSupportedError' });
  assert.throws(() => context.drawImage({}, 0, 0), { name: 'NotSupportedError' });
  assert.throws(() => { context.shadowBlur = 3; }, { name: 'NotSupportedError' });
  assert.ok(diagnostics.some(([code]) => code === 'canvas.unsupported_api'));
  assert.equal(snapshots(recorder)[0].commands.length, 2);
});

test('invalid radii and negative dashes fail without appending a draw', () => {
  const { document, recorder } = createRecorder();
  const canvas = document.addCanvas();
  const context = canvas.getContext('2d');

  context.beginPath();
  assert.throws(() => context.arc(0, 0, -1, 0, 1), { name: 'IndexSizeError' });
  assert.throws(() => context.ellipse(0, 0, 1, -1, 0, 0, 1), { name: 'IndexSizeError' });
  assert.throws(() => context.setLineDash([1, -1]), { name: 'IndexSizeError' });
  assert.deepEqual(snapshots(recorder)[0].commands, []);
});

test('invalid colors and fonts are ignored while supported CSS values are retained', () => {
  const { document, recorder } = createRecorder();
  const canvas = document.addCanvas();
  const context = canvas.getContext('2d');

  context.fillStyle = 'tomato';
  context.strokeStyle = 'rgba(10, 20, 30, 0.5)';
  context.font = 'italic 16px "Arial", sans-serif';
  context.fillStyle = 'not-a-color';
  context.strokeStyle = 'rgb(1, 2, nope)';
  context.font = 'bold mystery';
  context.fillRect(0, 0, 10, 10);

  const state = snapshots(recorder)[0].commands[0].state;
  assert.equal(state.fillStyle, 'tomato');
  assert.equal(state.strokeStyle, 'rgba(10, 20, 30, 0.5)');
  assert.equal(state.font, 'italic 16px "Arial", sans-serif');

  const gradient = context.createLinearGradient(0, 0, 10, 0);
  assert.throws(() => gradient.addColorStop(0.5, 'not-a-color'), { name: 'SyntaxError' });
});

test('getTransform returns an independent mutable matrix and setTransform accepts aliases', () => {
  const { document, recorder } = createRecorder();
  const canvas = document.addCanvas();
  const context = canvas.getContext('2d');

  const initial = context.getTransform();
  assert.deepEqual(
    [initial.a, initial.b, initial.c, initial.d, initial.e, initial.f],
    [1, 0, 0, 1, 0, 0],
  );
  assert.deepEqual(
    [initial.m11, initial.m12, initial.m21, initial.m22, initial.m41, initial.m42],
    [1, 0, 0, 1, 0, 0],
  );
  assert.equal(initial.is2D, true);
  assert.equal(Object.isFrozen(initial), false);
  initial.a = 9;
  initial.e = 4;
  assert.equal(initial.m11, 9);
  assert.equal(initial.m41, 4);
  assert.equal(context.getTransform().a, 1);
  assert.equal(context.getTransform().e, 0);
  initial.m41 = 5;
  assert.equal(initial.e, 5);
  context.setTransform(initial);
  assert.equal(context.getTransform().a, 9);
  assert.equal(context.getTransform().e, 5);

  context.setTransform({ m11: 2, m12: 3, m21: 4, d: 5, m41: 6, f: 7 });
  assert.deepEqual(
    [context.getTransform().a, context.getTransform().b, context.getTransform().c,
      context.getTransform().d, context.getTransform().e, context.getTransform().f],
    [2, 3, 4, 5, 6, 7],
  );
  context.setTransform({ m11: 8, m42: 9 });
  assert.deepEqual(
    [context.getTransform().a, context.getTransform().b, context.getTransform().c,
      context.getTransform().d, context.getTransform().e, context.getTransform().f],
    [8, 0, 0, 1, 0, 9],
  );
  assert.throws(() => context.setTransform({ a: 1, m11: 2 }), { name: 'TypeError' });
  assert.throws(() => context.setTransform({ is2D: false }), { name: 'TypeError' });
  assert.deepEqual(snapshots(recorder)[0].commands, []);
});

test('canvas count and dimension caps produce diagnostics without invalid snapshots', () => {
  const { document, recorder, diagnostics } = createRecorder();
  const oversized = document.addCanvas({ width: 8193, height: 2 });
  const oversizedContext = oversized.getContext('2d');
  assert.throws(() => oversizedContext.fillRect(0, 0, 1, 1), { name: 'NotSupportedError' });
  assert.equal(snapshots(recorder).length, 0);
  assert.ok(diagnostics.some(([code]) => code === 'canvas.dimension_limit'));

  for (let index = 0; index < 65; index += 1)
    document.addCanvas();
  assert.equal(snapshots(recorder).length, 63);
  assert.ok(diagnostics.some(([code]) => code === 'canvas.count_limit'));
});

test('canvas output cap is diagnosed and later draws are rejected', () => {
  const { document, recorder, diagnostics } = createRecorder();
  const canvas = document.addCanvas();
  const context = canvas.getContext('2d');

  let accepted = 0;
  while (accepted < 5000) {
    try {
      context.fillRect(0, 0, 1, 1);
      accepted += 1;
    } catch (error) {
      assert.equal(error.name, 'NotSupportedError');
      break;
    }
  }
  assert.ok(accepted > 0 && accepted < 5000);
  assert.throws(() => context.fillRect(0, 0, 1, 1), { name: 'NotSupportedError' });
  assert.equal(snapshots(recorder)[0].commands.length, accepted);
  assert.ok(diagnostics.some(([code]) => code === 'canvas.command_limit'));
});

test('coordinate and accumulated transform limits fail without corrupting the matrix', () => {
  const { document, recorder, diagnostics } = createRecorder();
  const canvas = document.addCanvas();
  const context = canvas.getContext('2d');

  context.scale(1e9, 1);
  assert.throws(() => context.scale(2, 1), { name: 'NotSupportedError' });
  assert.deepEqual(
    [context.getTransform().a, context.getTransform().b, context.getTransform().c,
      context.getTransform().d, context.getTransform().e, context.getTransform().f],
    [1e9, 0, 0, 1, 0, 0],
  );
  assert.throws(() => context.fillRect(1e10, 0, 1, 1), { name: 'NotSupportedError' });
  assert.deepEqual(snapshots(recorder)[0].commands, []);
  assert.ok(diagnostics.some(([code]) => code === 'canvas.coordinate_limit'));
});


for (const [method, values] of Object.entries({
  moveTo: [2, 2],
  lineTo: [2, 2],
  rect: [2, 2, 3, 3],
  quadraticCurveTo: [2, 2, 4, 4],
  bezierCurveTo: [2, 2, 3, 3, 4, 4],
  arc: [4, 4, 2, 0, 1],
  ellipse: [4, 4, 2, 3, 0, 0, 1],
})) {
  test('nonfinite ' + method + ' leaves path, drawing state and budgets unchanged', () => {
    const { document, recorder, diagnostics } = createRecorder();
    const ctx = document.addCanvas().getContext('2d');
    ctx.rect(1, 1, 4, 4);
    for (let i = 0; i < values.length; i++)
      for (const invalid of [NaN, Infinity, -Infinity]) {
        const args = values.slice();
        args[i] = invalid;
        assert.doesNotThrow(() => ctx[method](...args));
      }
    ctx.fill();
    const snapshot = snapshots(recorder)[0];
    assert.deepEqual(
      snapshot.commands[0].state.path.map((s) => ({ op: s.op, args: s.args })),
      [{ op: 'rect', args: [1, 1, 4, 4] }],
    );
    assert.deepEqual(diagnostics, []);
  });
  test(method + ' checks WebIDL arity and conversion before no-op rules', () => {
    const { document, recorder } = createRecorder();
    const ctx = document.addCanvas().getContext('2d');
    assert.throws(() => ctx[method](...values.slice(1)), { name: 'TypeError' });
    for (const invalid of [Symbol('x'), 1n]) {
      const args = values.slice();
      args[0] = NaN;
      args[args.length - 1] = invalid;
      assert.throws(() => ctx[method](...args), { name: 'TypeError' });
    }
    const trace = [];
    const args = values.map((v, i) => ({
      valueOf() {
        trace.push(i);
        return i === 0 ? NaN : v;
      },
    }));
    ctx[method](...args);
    assert.deepEqual(
      trace,
      values.map((_, i) => i),
    );
    assert.deepEqual(snapshots(recorder)[0].commands, []);
  });
}
test('nonfinite arc and ellipse arguments take precedence over negative radii', () => {
  const { document, recorder } = createRecorder();
  const ctx = document.addCanvas().getContext('2d');
  assert.doesNotThrow(() => ctx.arc(NaN, 0, -1, 0, 1));
  assert.doesNotThrow(() => ctx.arc(0, 0, -1, 0, Infinity));
  assert.doesNotThrow(() => ctx.ellipse(0, 0, -1, -1, NaN, 0, 1));
  assert.throws(() => ctx.arc(0, 0, -1, 0, 1), { name: 'IndexSizeError' });
  assert.throws(() => ctx.ellipse(0, 0, -1, 1, 0, 0, 1), { name: 'IndexSizeError' });
  assert.deepEqual(snapshots(recorder)[0].commands, []);
});

test('path no-ops and conversion errors match frozen Chromium observations', () => {
  const fixture = JSON.parse(
    readFileSync(
      new URL('../../../../packages/pirc_render/test/fixtures/parity/document-chart-types-chromium153.json', import.meta.url),
      'utf8',
    ),
  );
  assert.equal(fixture.browserVersion, '153.0.8010.12');
  assert.ok(fixture.pathCases.length > 100);
  const { document, recorder } = createRecorder();
  const canvas = document.addCanvas(),
    ctx = canvas.getContext('2d');
  for (const row of fixture.pathCases) {
    canvas.width = canvas.width;
    ctx.fillStyle = '#ff0000';
    ctx.rect(1, 1, 4, 4);
    ctx.fill();
    let args = row.args.slice();
    const trace = [];
    if (row.kind === 'nonfinite') args[row.index] = Number(row.special);
    if (row.kind === 'arity') args = args.slice(0, row.count);
    if (row.kind === 'conversion-error') {
      args[0] = NaN;
      args[args.length - 1] = row.special === 'symbol' ? Symbol('invalid') : 1n;
    }
    if (row.kind === 'trace')
      args = args.map((v, i) => ({
        valueOf() {
          trace.push(i);
          return i === 0 ? NaN : v;
        },
      }));
    let error = null;
    try {
      ctx[row.method](...args);
    } catch (e) {
      error = e.name;
    }
    ctx.fill();
    const commands = snapshots(recorder)[0].commands;
    const description = row.method + ' ' + row.kind + ' ' + row.index + ' ' + row.special;
    assert.equal(error, row.expected.error, description);
    assert.deepEqual(trace, row.expected.trace, description);
    assert.equal(ctx.fillStyle, row.expected.fillStyle, description);
    assert.equal(row.expected.unchangedBitmap, true, description);
    assert.deepEqual(commands[0].state.path, commands[1].state.path, description);
  }
});
test('finite path coordinates retain the explicit native resource limit', () => {
  const { document, diagnostics } = createRecorder();
  const ctx = document.addCanvas().getContext('2d');
  assert.throws(() => ctx.arc(0, 0, 1000000001, 0, 1), { name: 'NotSupportedError' });
  assert.ok(diagnostics.some(([code]) => code === 'canvas.coordinate_limit'));
});
