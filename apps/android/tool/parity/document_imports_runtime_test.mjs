import assert from 'node:assert/strict';import {readFileSync} from 'node:fs';import {createHash} from 'node:crypto';import test from 'node:test';import nativeVm from 'node:vm';
import {createDocumentScriptHostVm} from './document_script_host_test_helper.mjs';
const vm=createDocumentScriptHostVm(nativeVm);
const bundle=readFileSync(new URL('../../assets/document-script-runtime.js',import.meta.url),'utf8');
const fixture=JSON.parse(readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-imports-chromium153.json',import.meta.url),'utf8'));
const origin='https://document.example';
assert.match(fixture.browserVersion,/^153\./);
const tick=()=>new Promise(resolve=>setImmediate(resolve));
function runtime(item){
 const context=vm.createContext({});vm.runInContext(bundle,context,{timeout:3000});
 const invoke=(method,args={})=>JSON.parse(vm.runInContext('__pircDocument.'+method+'('+JSON.stringify(args)+')',context,{timeout:3000}));
 const initialized=invoke('init',{url:origin+'/page',html:item.html});return {context,invoke,initialized};
}
async function run(item){
 const env=runtime(item);const pending=[...env.initialized.resourceRequests];const requests=[];const logical=[];
 for(let turn=0;turn<40;turn++){
  while(pending.length){
   const request=pending.shift();logical.push(request);let url=request.url;let path=new URL(url).pathname;requests.push(path);let entry=item.resources[path];
   while(entry?.redirect){url=new URL(entry.redirect,url).href;path=new URL(url).pathname;requests.push(path);entry=item.resources[path];}
   let ok=typeof entry==='string';let error=ok?'':'Synthetic 404';
   if(ok&&request.integrity){const [algorithm,hash]=request.integrity.split('-');const actual=createHash(algorithm).update(entry).digest('base64');if(actual!==hash){ok=false;error='Integrity mismatch';}}
   const completion=env.invoke('completeResource',{id:request.id,url,ok,source:ok?entry:undefined,error});pending.push(...completion.resourceRequests);
  }
  await tick();const snapshot=env.invoke('snapshot');pending.push(...snapshot.resourceRequests);
  const serialized=vm.runInContext('JSON.stringify({ready:Array.isArray(window.result),value:window.result})',env.context);
  const result=JSON.parse(serialized);
  if(result.ready&&!pending.length)return {value:JSON.parse(JSON.stringify(result.value).replaceAll(origin,'$ORIGIN')),snapshot,logical,requests};
  if(turn===39)return {value:undefined,snapshot,logical,requests};
 }
}
for(const item of fixture.cases){
 test('Chromium153 import integration: '+item.name, async()=>{
  const actual=await run(item);assert.deepEqual(actual.value,item.expected);
  assert.deepEqual([...new Set(actual.requests)].sort(),[...new Set(item.requests.filter(path=>path!=='/page'))].sort());
  if(item.name==='classic-external-redirect-base'){
   const imported=actual.logical.find(request=>request.type==='module');
   assert.equal(imported.moduleReferrerUrl,origin+'/real/classic.js');
  }
  if(item.name==='import-map-integrity-dynamic')assert.ok(actual.logical.filter(request=>request.type==='module').every(request=>/^sha256-/.test(request.integrity)));
 });
}
