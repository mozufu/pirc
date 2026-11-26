import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import test from 'node:test';
import nativeVm from 'node:vm';
import { createDocumentScriptHostVm } from './document_script_host_test_helper.mjs';

const vm = createDocumentScriptHostVm(nativeVm);
const asset = name => new URL('../../assets/' + name, import.meta.url);
const fixture = JSON.parse(readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-canvas-text-chromium153.json', import.meta.url)));
const inkFixture = JSON.parse(readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-canvas-ink-chromium153.json', import.meta.url)));
const font = readFileSync(new URL('./vendor/canvas-text-fixture-font/Roboto-Regular.ttf', import.meta.url));
const wasm = readFileSync(asset('document-canvas-text.wasm'));
const arrayBuffer = buffer => buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength);
const evaluate = (context, expression) => new vm.Script(expression).runInContext(context, { timeout: 3000 });
const json = (context, expression) => JSON.parse(evaluate(context, 'JSON.stringify(' + expression + ')'));

async function runtime() {
  const consumed = [];
  const context = vm.createContext({
    android: { consumeNamedDataAsArrayBuffer: async name => {
      consumed.push(name);
      if (name === 'wasm') return arrayBuffer(wasm);
      if (name === 'font') return arrayBuffer(font);
      throw new Error('Unexpected named font resource');
    } },
  });
  evaluate(context, readFileSync(asset('document-canvas-text.js'), 'utf8'));
  const prepared = await context.__pircInitializeCanvasText({
    wasmName: 'wasm',
    resources: [{ id: 'roboto', dataName: 'font', ttcIndex: 0, axes: [] }],
    matches: [{ family: fixture.font.family, weight: 400, italic: false, resourceIds: ['roboto'] }],
  });
  assert.equal(JSON.parse(prepared).ok, true);
  assert.deepEqual(consumed, ['wasm', 'font']);
  evaluate(context, readFileSync(asset('document-script-runtime.js'), 'utf8'));
  const result = JSON.parse(evaluate(context, '__pircDocument.init(' + JSON.stringify({
    html: '<!doctype html><canvas id="chart"></canvas>',
    url: 'https://example.test/canvas-text',
  }) + ')'));
  assert.deepEqual(result.diagnostics.filter(item => item.severity === 'error'), []);
  evaluate(context, 'globalThis.ctx=document.getElementById("chart").getContext("2d");ctx.font=' + JSON.stringify('16px ' + fixture.font.family));
  return context;
}

test('pinned real Skia widths match Chromium at both viewports, including spaces and shaping', async () => {
  assert.equal(createHash('sha256').update(font).digest('hex'), fixture.font.sha256);
  const context = await runtime();
  for (const viewport of fixture.viewports) {
    for (const row of viewport.cases) {
      evaluate(context, 'ctx.direction=' + JSON.stringify(row.direction));
      const expression = 'ctx.measureText(' + JSON.stringify(row.text) + ').width';
      if (!row.fontCoverage.allNonWhitespaceCodepointsPresent) {
        assert.throws(() => evaluate(context, expression), { name: 'NotSupportedError' }, row.id);
      } else {
        assert.ok(Math.abs(evaluate(context, expression) - row.width) <= .005, row.id);
      }
    }
  }
  assert.equal(evaluate(context, 'typeof __pircInitializeCanvasText'), 'undefined');
  assert.equal(evaluate(context, 'typeof __pircNativeCanvasText'), 'undefined');
});

test('measureText follows browser DOMString conversions and readonly width semantics', async () => {
  const context = await runtime();
  for (const row of fixture.viewports[0].conversions) {
    const inputs = {
      omitted: '', undefined: 'undefined', number: '42', null: 'null', boolean: 'false',
      array: '["AV","To"]', bigint: '123n', 'string-object': 'new String("AV")',
      'string-valueof-object': '({toString(){events.push("toString");return "AV"},valueOf(){events.push("valueOf");return 123}})',
      'symbol-to-primitive-object': '({[Symbol.toPrimitive](hint){events.push(hint);return "To"}})',
      symbol: 'Symbol("not-a-DOMString")',
    };
    const actual = json(context, '(()=>{globalThis.events=[];try{return {width:ctx.measureText(' + inputs[row.inputKind] + ').width,events}}catch(e){return {error:e.name,events}}})()');
    assert.deepEqual(actual.events, row.conversionEvents, row.id);
    if (row.error) assert.equal(actual.error, row.error.name, row.id);
    else assert.ok(Math.abs(actual.width - row.width) <= .005, row.id);
  }
  const readonly = json(context, `(()=>{
    const metric=ctx.measureText('AV'),before=metric.width;
    const descriptor=Object.getOwnPropertyDescriptor(TextMetrics.prototype,'width');
    const reflectSetResult=Reflect.set(metric,'width',1234);
    let strictAssignmentError=null;
    try{(function(){'use strict';metric.width=4321})()}catch(e){strictAssignmentError=e.name}
    return {widthBefore:before,widthAfter:metric.width,reflectSetResult,strictAssignmentError,
      ownWidthAfterAssignment:Object.hasOwn(metric,'width'),extensible:Object.isExtensible(metric),
      prototypeWidthDescriptor:{configurable:descriptor.configurable,enumerable:descriptor.enumerable,
        getter:typeof descriptor.get==='function',setter:typeof descriptor.set==='function'}};
  })()`);
  assert.deepEqual(readonly, fixture.viewports[0].readonly);
  assert.equal(evaluate(context, 'ctx.measureText("AV") instanceof TextMetrics'), true);
  assert.throws(() => evaluate(context, 'new TextMetrics()'), { name: 'TypeError' });
});

test('measureText leaves draw state intact while supporting real ink and rejecting unprepared fonts', async () => {
  const context = await runtime();
  const state = 'JSON.stringify([ctx.font,ctx.direction,ctx.textAlign,ctx.textBaseline])';
  const before = evaluate(context, state);
  evaluate(context, 'ctx.measureText("A V")');
  assert.equal(evaluate(context, state), before);
  assert.ok(Math.abs(evaluate(context, 'ctx.measureText("AV").actualBoundingBoxAscent')-11.375)<1/4096);
  assert.throws(() => evaluate(context, 'ctx.measureText("x".repeat(16385))'), { name: 'RangeError' });
  evaluate(context, 'ctx.font="16px UnpreparedFamily"');
  assert.throws(() => evaluate(context, 'ctx.measureText("AV")'), { name: 'NotSupportedError' });
  evaluate(context, 'ctx.font=' + JSON.stringify('16px ' + fixture.font.family));
  assert.equal(evaluate(context, 'ctx.measureText("AV").width'), fixture.viewports[0].readonly.widthBefore);
});

test('text drawing optional widths match Chromium, including explicitly undefined library arguments', async () => {
  const context = await runtime();
  for (const row of fixture.viewports[0].drawOptionalWidths) {
    const input = {omitted:'',undefined:',undefined','positive-infinity':',Infinity',nan:',NaN',
      'negative-infinity':',-Infinity',zero:',0',negative:',-1',null:',null'}[row.inputKind];
    evaluate(context, 'ctx.clearRect(0,0,300,150)');
    evaluate(context, 'ctx.' + row.operation + '("AV",10,30' + input + ')');
    const snapshot = JSON.parse(evaluate(context, '__pircDocument.snapshot({})'));
    const latest = snapshot.canvases[0].commands.at(-1);
    assert.equal(latest.op === row.operation, row.hasInk, row.operation + '/' + row.inputKind);
    if (row.hasInk) assert.deepEqual(latest.args, ['AV',10,30]);
  }
});

test('Canvas text assets reproduce offline with verified dependency checksums and licenses', () => {
  const directory = mkdtempSync(path.join(tmpdir(), 'pirc-canvas-text-build-'));
  try {
    execFileSync(process.env.PYTHON || 'python3', ['-c',
      'import sys;from pathlib import Path;sys.path.insert(0,sys.argv[1]);from build_document_canvas_text import generate;generate(Path(sys.argv[2]))',
      new URL('.', import.meta.url).pathname, directory]);
    for (const name of ['document-canvas-text.js','document-canvas-text.LICENSE.txt','document-canvas-text.provenance.json']) {
      assert.deepEqual(readFileSync(path.join(directory, name)), readFileSync(asset(name)), name);
    }
  } finally { rmSync(directory, {recursive:true,force:true}); }
});


test('real Skia outline ink and font baselines match all Chromium 153 same-font cases', async () => {
  assert.equal(createHash('sha256').update(font).digest('hex'),inkFixture.font.sha256);
  const context=await runtime();
  for(const viewport of inkFixture.viewports) {
    assert.deepEqual(viewport.externalRequests,[]);
    for(const row of viewport.cases) {
      assert.equal(row.sameFontOracle,true,row.id);
      const actual=json(context,`(()=>{
        ctx.font=${JSON.stringify(row.font)};ctx.direction=${JSON.stringify(row.direction)};
        ctx.textAlign=${JSON.stringify(row.textAlign)};ctx.textBaseline=${JSON.stringify(row.textBaseline)};
        const before=JSON.stringify([ctx.font,ctx.direction,ctx.textAlign,ctx.textBaseline]);
        const m=ctx.measureText(${JSON.stringify(row.text)});
        return {values:Object.fromEntries(${JSON.stringify(inkFixture.metricProperties)}.map(k=>[k,m[k]===undefined?null:m[k]])),unchanged:before===JSON.stringify([ctx.font,ctx.direction,ctx.textAlign,ctx.textBaseline])};
      })()`);
      assert.equal(actual.unchanged,true,row.id);
      for(const [key,expected] of Object.entries(row.metrics)) {
        if(expected===null)assert.equal(actual.values[key],null,row.id+'/'+key);
        else assert.ok(Math.abs(actual.values[key]-expected)<=1/4096,`${row.id}/${key}: ${actual.values[key]} vs ${expected}`);
      }
    }
  }
});

test('ink getters retain their measurement state and match native readonly descriptors', async () => {
  const context=await runtime();
  const descriptors=json(context,`(${JSON.stringify(inkFixture.metricProperties)}).map(name=>{const d=Object.getOwnPropertyDescriptor(TextMetrics.prototype,name);return {name,present:!!d,configurable:d?d.configurable:null,enumerable:d?d.enumerable:null,getter:typeof d?.get==='function',setter:typeof d?.set==='function'}})`);
  assert.deepEqual(descriptors,inkFixture.viewports[0].readonly.prototypeDescriptors);
  const actual=json(context,`(()=>{
    ctx.textAlign='left';ctx.textBaseline='alphabetic';const m=ctx.measureText('AV');
    ctx.textAlign='right';ctx.textBaseline='bottom';ctx.font='16px UnpreparedFamily';
    let brand=null,strict=null;try{Object.getOwnPropertyDescriptor(TextMetrics.prototype,'actualBoundingBoxLeft').get.call({})}catch(e){brand=e.name}
    try{(function(){'use strict';m.actualBoundingBoxLeft=987})()}catch(e){strict=e.name}
    return {left:m.actualBoundingBoxLeft,ascent:m.actualBoundingBoxAscent,brand,strict,assigned:Reflect.set(m,'actualBoundingBoxLeft',987)};
  })()`);
  assert.equal(actual.left,-.21875);
  assert.ok(Math.abs(actual.ascent-11.375)<1/4096);
  assert.deepEqual([actual.brand,actual.strict,actual.assigned],['TypeError','TypeError',false]);
});

test('recorded text baseline metadata comes from the same real font metrics as TextMetrics', async () => {
  const context=await runtime();
  for(const row of inkFixture.viewports[0].cases.filter(row=>row.id.startsWith('align-left-baseline-'))) {
    evaluate(context,`ctx.font=${JSON.stringify(row.font)};ctx.textBaseline=${JSON.stringify(row.textBaseline)};ctx.clearRect(0,0,300,150);ctx.fillText('AV',20,40);ctx.strokeText('AV',20,80)`);
    const snapshot=JSON.parse(evaluate(context,'__pircDocument.snapshot({})'));
    for(const command of snapshot.canvases[0].commands.filter(command=>command.op.endsWith('Text'))) {
      assert.ok(Math.abs(command.state.textBaselineOffset+row.metrics.alphabeticBaseline)<1/4096,row.id);
    }
  }
});
