import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import nativeVm from 'node:vm';
import {createDocumentScriptHostVm} from './document_script_host_test_helper.mjs';
const vm=createDocumentScriptHostVm(nativeVm);
const bundle=readFileSync(new URL('../../assets/document-script-runtime.js',import.meta.url),'utf8');
function runtime(html,url='https://document.example/page') {
 const context=vm.createContext({});vm.runInContext(bundle,context,{timeout:3000});
 const invoke=(method,argument={})=>JSON.parse(vm.runInContext('__pircDocument.'+method+'('+JSON.stringify(argument)+')',context,{timeout:3000}));
 const initialized=invoke('init',{html,url});return {context,invoke,initialized};
}
const tick=()=>new Promise(resolve=>setImmediate(resolve));
const evaluate=(env,expression)=>vm.runInContext(expression,env.context,{timeout:3000});
const json=(env,expression)=>JSON.parse(evaluate(env,'JSON.stringify('+expression+')'));
async function drain(env,sources={}) {
 const requests=[...env.initialized.resourceRequests];env.initialized.resourceRequests=[];
 const observed=[];
 for(let step=0;step<20;step++) {
   await tick();requests.push(...(env.invoke('snapshot').resourceRequests||[]));
   if(!requests.length && evaluate(env,'document.readyState')==='complete')return observed;
   while(requests.length) {
    const request=requests.shift();observed.push(request);
    const entry=sources[request.url];
    const response=env.invoke('completeResource',{id:request.id,ok:entry!==undefined,...(typeof entry==='string'?{source:entry,url:request.url}:entry||{error:'Synthetic 404'})});
    requests.push(...response.resourceRequests);
   }
 }
 throw new Error('Module resource drain failed to settle');
}

test('inline module defers, has native module scope, mutates DOM and skips nomodule',async()=>{
 const env=runtime(`<base href="/folder/"><div id="out"></div><script>window.order=['classic'];</script><script nomodule>window.legacyRan=true;</script><script type="module">const local=7;window.order.push('module');document.querySelector('#out').textContent=String(local);window.scope=[this,typeof arguments,document.currentScript,import.meta.url];</script><script>window.order.push('parser');</script>`);
 await drain(env);
 assert.deepEqual(json(env,'order'),['classic','parser','module']);
 assert.deepEqual(json(env,'scope'),[null,'undefined',null,'https://document.example/folder/']);
 assert.equal(evaluate(env,'window.legacyRan'),undefined);assert.equal(evaluate(env,'window.local'),undefined);
 assert.equal(evaluate(env,"document.querySelector('#out').textContent"),'7');
});

test('external modules follow final response URLs, parent referrers, and shared live state',async()=>{
 const env=runtime(`<div id="out"></div><script type="module" src="/entry.js" crossorigin="use-credentials"></script>`);
 const requests=await drain(env,{
  'https://document.example/entry.js':{url:'https://cdn.example/folder/main.js',source:"import {value,increment} from './state.js';increment();document.querySelector('#out').textContent=value;window.meta=import.meta.url;"},
  'https://cdn.example/folder/state.js':"export let value=1;export function increment(){value++}",
 });
 assert.equal(evaluate(env,"document.querySelector('#out').textContent"),'2');
 assert.equal(evaluate(env,'meta'),'https://cdn.example/folder/main.js');
 assert.equal(requests.length,2);assert.equal(requests[0].type,'module');
 assert.equal(requests[0].moduleReferrerUrl,'https://document.example/page');
 assert.equal(requests[1].moduleReferrerUrl,'https://cdn.example/folder/main.js');
 assert.equal(requests[1].crossOrigin,'use-credentials');
});

test('ordered deferred modules start before DCL and load without waiting for top-level await',async()=>{
 const env=runtime(`<script>window.trace=[];document.addEventListener('DOMContentLoaded',()=>trace.push('DCL'));window.addEventListener('load',()=>trace.push('load'));</script><script type="module">trace.push('module-1');await new Promise(r=>setTimeout(r,30));trace.push('after-await');</script><script defer src="/classic.js"></script><script type="module">trace.push('module-2')</script>`);
 await drain(env,{'https://document.example/classic.js':"trace.push('classic-defer')"});
 assert.deepEqual(json(env,'trace'),['module-1','classic-defer','module-2','DCL','load']);
 env.invoke('pump',{now:30});await tick();
 assert.deepEqual(json(env,'trace'),['module-1','classic-defer','module-2','DCL','load','after-await']);
});

test('module dynamic import returns one namespace and keeps side effects once',async()=>{
 const env=runtime(`<div id="out"></div><script type="module">const [a,b]=await Promise.all([import('./dep.js'),import('./dep.js')]);document.querySelector('#out').textContent=a.value+':'+(a===b);</script>`);
 const requests=await drain(env,{'https://document.example/dep.js':"window.depRuns=(window.depRuns||0)+1;export const value=42;"});
 // TLA does not hold window load; give already queued dynamic graph work its host turn.
 await tick();let snapshot=env.invoke('snapshot');
 for(const request of snapshot.resourceRequests) {requests.push(request);env.invoke('completeResource',{id:request.id,ok:true,url:request.url,source:"window.depRuns=(window.depRuns||0)+1;export const value=42;"});}
 await tick();
 assert.equal(evaluate(env,"document.querySelector('#out').textContent"),'42:true');
 assert.equal(evaluate(env,'depRuns'),1);assert.equal(requests.length,1);
});

test('dynamically appended modules run but innerHTML module scripts stay inert',async()=>{
 const env=runtime(`<div id="target"></div><script>const node=document.createElement('script');node.type='module';node.textContent='window.dynamicRan=true';document.head.appendChild(node);document.querySelector('#target').innerHTML='<script type="module">window.inertRan=true;<'+ '/script>';</script>`);
 await drain(env);assert.equal(evaluate(env,'window.dynamicRan'),true);assert.equal(evaluate(env,'window.inertRan'),undefined);
});

test('bad module imports dispatch error and cannot execute importer bodies',async()=>{
 const env=runtime(`<script type="module" src="/bad.js" onerror="window.failed=true"></script><script type="module">window.good=true</script>`);
 await drain(env,{'https://document.example/bad.js':"import {missing} from './dep.js';window.leaked=true;",'https://document.example/dep.js':'export const value=1;'});
 assert.equal(evaluate(env,'window.failed'),true);assert.equal(evaluate(env,'window.good'),true);assert.equal(evaluate(env,'window.leaked'),undefined);
 const snapshot=env.invoke('snapshot');assert.ok(snapshot.diagnostics.some(item=>item.code==='script.module_load_error'));
});

const oracle=JSON.parse(readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-modules-chromium153.json',import.meta.url),'utf8'));
assert.match(oracle.browserVersion,/^153\./);
for (const item of oracle.cases) {
 test('Chromium153 module parity: '+item.name,async()=>{
  const origin='https://document.example';
  const url=item.url.replaceAll('$ORIGIN',origin);
  const html=(item.base?'<base href="'+item.base+'">':'')+'<script type="module">'+item.source+'</script>';
  const sources=Object.fromEntries(Object.entries(item.modules).map(([name,source])=>[new URL(name,url).href,source]));
  const env=runtime(html,url);await drain(env,sources);await tick();
  const value=json(env,'window.result');
  assert.deepEqual(JSON.parse(JSON.stringify(value).replaceAll(origin,'$ORIGIN')),item.expected);
  const snapshot=env.invoke('snapshot');
  assert.deepEqual(snapshot.diagnostics.filter(d=>d.severity==='error'),[]);
 });
}

test('SPA URL changes keep relative module resolution and the owning native document referrer separate',async()=>{
 const env=runtime(`<script>history.pushState({},'', '/after/page');</script><script type="module">import {value} from './dep.js';window.result=value;</script>`);
 const requests=await drain(env,{'https://document.example/after/dep.js':'export const value=9;'});
 assert.equal(evaluate(env,'window.result'),9);
 assert.equal(requests[0].url,'https://document.example/after/dep.js');
 assert.equal(requests[0].moduleReferrerUrl,'https://document.example/page');
});
