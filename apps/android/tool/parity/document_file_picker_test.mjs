import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import nativeVm from 'node:vm';
import {createDocumentScriptHostVm} from './document_script_host_test_helper.mjs';
const vm=createDocumentScriptHostVm(nativeVm);
const bundle=readFileSync(process.env.PIRC_DOCUMENT_SCRIPT_RUNTIME_BUNDLE || new URL('../../assets/document-script-runtime.js',import.meta.url),'utf8');
const source=readFileSync(new URL('../../integration_test/document_file_picker_fixture.dart',import.meta.url),'utf8');
const fixture=source.match(/r'''([\s\S]*?)''';/)[1];
const oracle=JSON.parse(readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-file-picker-chrome155.json',import.meta.url)));
function invoke(ctx,name,args={}) {return JSON.parse(vm.runInContext('__pircDocument.'+name+'('+JSON.stringify(args)+')',ctx,{timeout:3000}));}
function read(ctx,expression) {return JSON.parse(vm.runInContext('JSON.stringify('+expression+')',ctx,{timeout:3000}));}
function click(ctx,selector) {
 const id=vm.runInContext('document.querySelector('+JSON.stringify(selector)+').getAttribute("data-pirc-script-id")',ctx);
 return invoke(ctx,'dispatch',{id,type:'click',now:0});
}
async function settle(ctx) {for(let i=0;i<12;i++)await Promise.resolve();return invoke(ctx,'snapshot');}
test('file chooser fixture matches the independent Chrome source hash',()=>assert.equal(createHash('sha256').update(source).digest('hex'),oracle.fixtureSha256));
for(const expected of oracle.cases) test('native file-picker activation follows Chrome: '+expected.caseId,async()=>{
 const ctx=vm.createContext({});vm.runInContext(bundle,ctx,{timeout:3000});
 const results=[invoke(ctx,'init',{html:fixture,url:'http://127.0.0.1:43178/fixture?case='+expected.caseId})];
 const id=expected.caseId;
 if(!id.startsWith('startup-')) results.push(click(ctx,id==='physical-file'?'#file-input':id.startsWith('physical-label-')?'#file-label-text':'[data-case="'+id+'"]'));
 results.push(await settle(ctx));
 if(id==='timer-click') results.push(invoke(ctx,'pump',{now:1}));
 results.push(await settle(ctx));
 const actions=results.flatMap(r=>r.filePickerActions||[]);
 assert.equal(actions.length,expected.filechoosers.length,id+' picker action count');
 if(actions.length) {
  assert.equal(actions.length,1);
  const action=actions[0];
  assert.equal(action.kind,'file');assert.equal(action.multiple,expected.filechoosers[0].isMultiple);
  assert.equal(action.accept,expected.filechoosers[0].input.accept);
  const files=expected.fixtureResult.files.map(f=>({name:f.name,type:f.type,size:f.size,lastModified:12345,bytesBase64:Buffer.from(f.bytes).toString('base64')}));
  invoke(ctx,'filePickerResult',{id:action.id,files,cancelled:false});
  await settle(ctx);
 }
 const actual=read(ctx,'window.documentFilePickerResult');
 assert.deepEqual(actual,expected.fixtureResult);
 const diagnostics=invoke(ctx,'snapshot').diagnostics.filter(d=>d.severity!=='info');
 assert.deepEqual(diagnostics,[]);
});

test('cancel and reselect preserve the previous File and never grant another chooser',async()=>{
 const ctx=vm.createContext({});vm.runInContext(bundle,ctx,{timeout:3000});
 invoke(ctx,'init',{html:`<input id="file" type="file"><button id="go">Pick</button><script>
 window.events=[];const input=document.getElementById('file');
 for(const type of ['input','change','cancel']) input.addEventListener(type,e=>events.push({type:e.type,trusted:e.isTrusted,composed:e.composed,name:input.files[0]?.name||''}));
 input.onchange=()=>{window.original=input.files[0];input.click()};
 document.getElementById('go').onclick=()=>input.click();</script>`,url:'https://example.test/'});
 const files=[{name:'selected.txt',type:'text/plain',size:3,lastModified:123,bytesBase64:'AP+A'}];
 let action=click(ctx,'#go').filePickerActions[0];
 let result=invoke(ctx,'filePickerResult',{id:action.id,files,cancelled:false});await settle(ctx);
 assert.deepEqual(result.filePickerActions,[],'change listeners do not gain another selection permission');
 action=click(ctx,'#go').filePickerActions[0];invoke(ctx,'filePickerResult',{id:action.id,cancelled:true});
 action=click(ctx,'#go').filePickerActions[0];invoke(ctx,'filePickerResult',{id:action.id,files,cancelled:false});
 assert.deepEqual(read(ctx,'events'),[
  {type:'input',trusted:true,composed:true,name:'selected.txt'},
  {type:'change',trusted:true,composed:false,name:'selected.txt'},
  {type:'cancel',trusted:true,composed:false,name:'selected.txt'},
  {type:'cancel',trusted:true,composed:false,name:'selected.txt'},
 ]);
 assert.equal(read(ctx,'original === document.getElementById("file").files[0]'),true);
});

test('the file activation window expires without consuming unrelated popup rules',()=>{
 const ctx=vm.createContext({});vm.runInContext(bundle,ctx,{timeout:3000});
 invoke(ctx,'init',{html:'<input id="file" type="file"><button id="go">Gesture</button>',url:'https://example.test/'});
 click(ctx,'#go');invoke(ctx,'pump',{now:5000});
 const denied=vm.runInContext('(()=>{try{document.getElementById("file").showPicker();return "no error"}catch(e){return e.name}})()',ctx);
 assert.equal(denied,'NotAllowedError');assert.deepEqual(invoke(ctx,'snapshot').filePickerActions,[]);
});
