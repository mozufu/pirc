import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import nativeVm from 'node:vm';
import {createDocumentScriptHostVm} from './document_script_host_test_helper.mjs';
const vm=createDocumentScriptHostVm(nativeVm);

const bundle=readFileSync(process.env.PIRC_DOCUMENT_SCRIPT_RUNTIME_BUNDLE || new URL('../../assets/document-script-runtime.js',import.meta.url),'utf8');
const fixtureSource=readFileSync(new URL('../../integration_test/document_anchor_activation_fixture.dart',import.meta.url),'utf8');
const fixture=fixtureSource.match(/r'''([\s\S]*?)''';/)[1];
const oracle=JSON.parse(readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-anchor-activation-chrome155.json',import.meta.url)));
const origin='http://127.0.0.1:43177';
function invoke(ctx,name,args={}) {return JSON.parse(vm.runInContext('__pircDocument.'+name+'('+JSON.stringify(args)+')',ctx,{timeout:3000}));}
function read(ctx,expression) {return JSON.parse(vm.runInContext('JSON.stringify('+expression+')',ctx,{timeout:3000}));}
function evaluate(ctx,source) {return vm.runInContext(source,ctx,{timeout:3000});}
function page(html=fixture,url=origin+'/fixture') {
 const ctx=vm.createContext({});vm.runInContext(bundle,ctx,{timeout:3000});
 const initial=invoke(ctx,'init',{html,url,objectUrlNonce:'47'.repeat(24)});return {ctx,initial};
}
function click(ctx,id) {
 const marker=evaluate(ctx,'document.getElementById('+JSON.stringify(id)+').getAttribute("data-pirc-script-id")');
 return invoke(ctx,'dispatch',{id:marker,type:'click'});
}
function normalize(value,sourceOrigin) {
 if(typeof value==='string') {
  let text=value.split(sourceOrigin).join('<origin>');
  if(text.startsWith('blob:<origin>/')) text='blob:<origin>/<blob>'+ (text.includes('#')?text.slice(text.indexOf('#')):'');
  return text;
 }
 if(Array.isArray(value)) return value.map(item=>normalize(item,sourceOrigin));
 if(value && typeof value==='object') return Object.fromEntries(Object.entries(value).map(([k,v])=>[k,normalize(v,sourceOrigin)]));
 return value;
}

test('shared anchor fixture is pinned to independently observed Chrome source',()=>{
 assert.equal(createHash('sha256').update(fixtureSource).digest('hex'),oracle.fixtureSha256);
 assert.match(oracle.browserVersion,/^155\./);
});

for(const expected of oracle.cases) {
 test('shared anchor activation agrees with Chrome: '+expected.caseId,()=>{
  const id=expected.caseId;
  const {ctx,initial}=page(fixture,origin+'/fixture?case='+id);
  let result;
  if(id==='startup-popup') result=initial;
  else if(id==='timer-popup') result=invoke(ctx,'pump',{now:1});
  else result=click(ctx,'run-'+id);
  const actions=result.navigationActions;
  const destination=expected.popups[0]?.url || (expected.currentPage.url.includes('/destination/')?expected.currentPage.url:null);
  const shouldActivate=!!expected.download || !!destination;
  // This assertion fails against APK46's runtime for detached a.click().
  assert.equal(actions.length,shouldActivate?1:0,id);
  assert.deepEqual(normalize(read(ctx,'window.documentAnchorActivationResult'),origin),normalize(expected.eventResult,oracle.origin));
  const unexpected=result.diagnostics.filter(d=>d.severity!=='info' && !(['startup-popup','timer-popup'].includes(id) && d.code==='navigation.popup_blocked'));
  assert.deepEqual(unexpected,[]);
  if(!shouldActivate) return;
  const action=actions[0];assert.equal(action.kind,'anchor');assert.equal(action.replace,false);
  assert.equal(action.target,expected.popups.length?'_blank':'_self');
  if(destination) assert.equal(normalize(action.url,origin),normalize(destination,oracle.origin));
  if(expected.download) assert.equal(action.download,expected.download.suggestedFilename);
  else assert.equal(action.download,null);
  if(action.url.startsWith('blob:')) {
   assert.equal(action.capturedBlob.ok,true);assert.equal(action.capturedBlob.url,action.url);
   const bytes=Buffer.from(action.capturedBlob.bytesBase64,'base64');
   assert.equal(bytes.length,expected.download.byteLength);assert.equal(bytes.toString('utf8'),expected.download.utf8Text);
   assert.equal(createHash('sha256').update(bytes).digest('hex'),expected.download.sha256);
   if(id==='blob-download-revoke') assert.equal(invoke(ctx,'readObjectURL',action.url).ok,false);
  }
  if(id==='rel-noreferrer' || id==='referrerpolicy') assert.equal(action.referrerPolicy,'no-referrer');
  if(id==='rel-noreferrer') assert.equal(action.noreferrer,true);
 });
}

test('physical anchor default remains owned by Flutter with no duplicate script action',()=>{
 const {ctx}=page('<a id="a" href="/next" download="file.txt">Save</a>');
 const result=click(ctx,'a');assert.deepEqual(result.navigationActions,[]);assert.equal(result.defaultHandled,false);
});

test('download survives later location and form actions, with independent ordering',()=>{
 const {ctx}=page('<form id="f" action="/post"><input name="q" value="kept"></form><button id="go">Export</button><script>document.getElementById("go").onclick=()=>{const a=document.createElement("a");a.href="data:text/plain,first";a.download="first.txt";a.click();location.assign("/old");document.getElementById("f").submit();location.assign("/final")};</script>');
 const result=click(ctx,'go');assert.equal(result.navigationActions.length,2);
 assert.equal(result.navigationActions[0].download,'first.txt');assert.equal(result.navigationActions[1].url,origin+'/final');
 assert.ok(result.navigationActions[0].actionOrder<result.navigationActions[1].actionOrder);
});

test('href/download IDL preserves literal percent names and replaces base URL dynamically',()=>{
 const {ctx}=page('<base href="/one/"><p>links</p>');
 evaluate(ctx,`window.a=document.createElement('a');a.href='relative%20path';a.download='報表%20.csv';window.first=a.href;document.querySelector('base').setAttribute('href','/two/');window.second=a.href;`);
 assert.deepEqual(read(ctx,'[first,second,a.getAttribute("download"),a.download]'),[origin+'/one/relative%20path',origin+'/two/relative%20path','報表%20.csv','報表%20.csv']);
});

test('captured Blob export preserves the full 2 MiB budget after immediate revoke',()=>{
 const {ctx}=page('<button id="go">Large export</button><script>document.getElementById("go").onclick=()=>{const bytes=new Uint8Array(2*1024*1024);for(let i=0;i<bytes.length;i++)bytes[i]=i%251;const a=document.createElement("a");a.href=URL.createObjectURL(new Blob([bytes],{type:"application/octet-stream"}));a.download="large.bin";a.click();URL.revokeObjectURL(a.href)};</script>');
 const result=click(ctx,'go');assert.equal(result.navigationActions.length,1);
 const action=result.navigationActions[0];const bytes=Buffer.from(action.capturedBlob.bytesBase64,'base64');assert.equal(bytes.length,2*1024*1024);
 for(let i=0;i<bytes.length;i++) assert.equal(bytes[i],i%251);
 assert.equal(invoke(ctx,'readObjectURL',action.url).ok,false);
});

test('async Blob export is not mistaken for a new-window request',async()=>{
 const {ctx}=page('<button id="go">Async export</button><script>document.getElementById("go").onclick=()=>{Promise.resolve().then(()=>{const a=document.createElement("a");a.href=URL.createObjectURL(new Blob(["async"]));a.download="async.txt";a.target="_blank";a.click();URL.revokeObjectURL(a.href)})};</script>');
 click(ctx,'go');await Promise.resolve();
 const result=invoke(ctx,'snapshot');assert.equal(result.navigationActions.length,1);assert.equal(result.navigationActions[0].target,'_self');
 assert.equal(Buffer.from(result.navigationActions[0].capturedBlob.bytesBase64,'base64').toString(),'async');
});

test('cross-origin download hint becomes navigation and still honors popup authority',()=>{
 const {ctx}=page('<p>cross origin</p>');
 evaluate(ctx,`const a=document.createElement('a');a.href='https://outside.test/file';a.download='x';a.target='_blank';a.click();`);
 let result=invoke(ctx,'snapshot');assert.equal(result.navigationActions.length,0);assert.equal(result.diagnostics.at(-1).code,'navigation.popup_blocked');
 evaluate(ctx,`a.target='_self';a.click();`);result=invoke(ctx,'snapshot');assert.equal(result.navigationActions[0].download,null);
});

test('noopener named targets select a new context while explicit empty target ignores base target',()=>{
 const {ctx}=page('<base target="_blank"><button id="go">Go</button><script>document.getElementById("go").onclick=()=>{const a=document.createElement("a");a.href="/self";a.target="";a.click();const b=document.createElement("a");b.href="/new";b.target="named";b.rel="noopener";b.click()};</script>');
 const result=click(ctx,'go');assert.deepEqual(result.navigationActions.map(a=>[a.url,a.target]),[[origin+'/self','_self'],[origin+'/new','_blank']]);
});
