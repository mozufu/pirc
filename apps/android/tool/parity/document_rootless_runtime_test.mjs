import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import nativeVm from 'node:vm';
import test from 'node:test';
import {createDocumentScriptHostVm} from './document_script_host_test_helper.mjs';

const vm=createDocumentScriptHostVm(nativeVm);
const bundle=readFileSync(new URL('../../assets/document-script-runtime.js',import.meta.url),'utf8');
const fixture=JSON.parse(readFileSync(
  new URL('../../../../packages/pirc_render/test/fixtures/parity/document-rootless-chromium153.json',import.meta.url),'utf8'));

test('host-layout rootless document tree and parser script location match Chromium 153',()=>{
  assert.equal(fixture.browserVersion,'153.0.8010.12');
  for(const row of fixture.cases) {
    const context=vm.createContext({});
    vm.runInContext(bundle,context,{timeout:3000});
    const initial=JSON.parse(vm.runInContext(
      `__pircDocument.init(${JSON.stringify({
        html:row.html,url:'https://rootless.example/test',hostLayout:true,
      })})`,context,{timeout:3000}));
    assert.deepEqual(initial.diagnostics.filter(d=>d.severity==='error'),[],row.name);
    const actual=JSON.parse(vm.runInContext(`JSON.stringify({
      root:document.documentElement?.localName||null,
      head:document.head?.localName||null,
      body:document.body?.localName||null,
      headElements:[...document.head.children].map(e=>e.localName),
      bodyElements:[...document.body.children].map(e=>e.localName),
      xInBody:document.body.contains(document.getElementById('x')),
      doctype:document.doctype?.name||null,
      marker:window.marker||null,
    })`,context,{timeout:3000}));
    assert.deepEqual(actual,row.result,row.name);
    assert.match(initial.html,/<html[^>]*><head[^>]*>/,row.name);
  }
});
