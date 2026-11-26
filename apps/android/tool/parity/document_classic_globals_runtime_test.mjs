import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import nativeVm from 'node:vm';
import {createDocumentScriptHostVm} from './document_script_host_test_helper.mjs';
const vm=createDocumentScriptHostVm(nativeVm);
const bundle=readFileSync(new URL('../../assets/document-script-runtime.js',import.meta.url),'utf8');
const fixture=JSON.parse(readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-classic-globals-chromium153.json',import.meta.url),'utf8'));
for(const item of fixture.cases) test('native Script protocol vs Chromium153: '+item.name,async()=>{
 // This focused fixture has no host-awaited realm promises, so explicit engine
 // checkpoints model the IPC timing; broader legacy fixtures use default vm.
 const context=vm.createContext({},{microtaskMode:'afterEvaluate'});
 vm.runInContext(bundle,context,{timeout:3000});
 const invoke=(method,args={})=>JSON.parse(vm.runInContext('__pircDocument.'+method+'('+JSON.stringify(args)+')',context,{timeout:3000}));
 const initial=invoke('init',{html:item.html,url:'https://document.example/page'});
 const pending=[...initial.resourceRequests];let snapshot=initial;
 for(let turn=0;turn<30;turn++){
  while(pending.length){
   const request=pending.shift();const source=item.resources[new URL(request.url).pathname];
   const result=invoke('completeResource',{id:request.id,ok:typeof source==='string',source,error:source===undefined?'synthetic 404':undefined});
   pending.push(...result.resourceRequests);
  }
  snapshot=invoke('snapshot');pending.push(...snapshot.resourceRequests);
  const actual=JSON.parse(vm.runInContext('JSON.stringify({value:window.result})',context));
  if(actual.value){
   if(item.knownDifference){
    assert.deepEqual(actual.value,['undefined']);assert.notDeepEqual(actual.value,item.expected);
    assert.ok(snapshot.diagnostics.some(d=>d.code==='script.dynamic_inline_global_scope_limit'));
   }else assert.deepEqual(actual.value,item.expected);
   const errors=snapshot.diagnostics.filter(d=>d.code==='script.runtime_error');
   assert.equal(errors.length,item.errors.length);return;
  }
  await new Promise(resolve=>setImmediate(resolve));
 }
 assert.fail(item.name+' did not finish: '+JSON.stringify(snapshot.diagnostics));
});

test('raw protocol keeps one-shot requests until finish and validates task identity',()=>{
 const context=nativeVm.createContext({});nativeVm.runInContext(bundle,context);
 const call=(method,args={})=>JSON.parse(nativeVm.runInContext('__pircDocument.'+method+'('+JSON.stringify(args)+')',context));
 const initialized=call('init',{url:'https://document.example/page',html:'<script>var loaded=fetch("/data");</script><script>window.after=true</script>'});
 assert.equal(initialized.classicScript.id,1);assert.equal(initialized.scheduler.timerDelayMs,0);
 assert.throws(()=>call('beginClassicScript',{id:9}),/Invalid or stale/);
 const first=call('beginClassicScript',{id:1});assert.deepEqual(call('beginClassicScript',{id:1}),first);
 nativeVm.runInContext(first.source+'\n;__pircDocument.endClassicScriptTurn(1);void 0;',context);
 assert.throws(()=>call('finishClassicScript',{id:2}),/Invalid or stale/);
 const completed=call('finishClassicScript',{id:1});assert.equal(completed.resourceRequests.length,1);
 assert.equal(completed.resourceRequests[0].kind,'fetch');assert.equal(completed.classicScript.id,2);
 assert.throws(()=>call('finishClassicScript',{id:1}),/Invalid or stale/);
});

test('host yields after 128 Scripts and resumes from the same pending task',()=>{
 const context=vm.createContext({});vm.runInContext(bundle,context);
 const html='<script>var count=0</script>'+Array.from({length:130},()=>'<script>count++</script>').join('');
 const first=JSON.parse(vm.runInContext('__pircDocument.init('+JSON.stringify({html,url:'https://document.example/page'})+')',context));
 assert.equal(first.classicScript.id,129);assert.equal(first.scheduler.timerDelayMs,0);
 assert.equal(vm.runInContext('count',context),127);
 const second=JSON.parse(vm.runInContext('__pircDocument.snapshot()',context));
 assert.equal(second.classicScript,null);assert.equal(vm.runInContext('count',context),130);
 assert.equal(vm.runInContext('document.readyState',context),'complete');
});
