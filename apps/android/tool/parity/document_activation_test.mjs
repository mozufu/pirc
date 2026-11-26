import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import test from 'node:test';
import nativeVm from 'node:vm';
import {createDocumentScriptHostVm} from './document_script_host_test_helper.mjs';
const vm=createDocumentScriptHostVm(nativeVm);

const bundle = readFileSync(process.env.PIRC_DOCUMENT_SCRIPT_RUNTIME_BUNDLE || new URL('../../assets/document-script-runtime.js', import.meta.url), 'utf8');
const fixtureSource = readFileSync(new URL('../../integration_test/document_activation_fixture.dart', import.meta.url), 'utf8');
const fixtureHtml = fixtureSource.match(/r'''([\s\S]*?)''';/)[1];
const chrome = JSON.parse(readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-activation-chrome155.json', import.meta.url)));
function page(html) {
  const context = vm.createContext({});
  vm.runInContext(bundle, context, {timeout: 3000});
  vm.runInContext('__pircDocument.init(' + JSON.stringify({html, url:'https://example.test/page'}) + ')', context, {timeout:3000});
  return context;
}
function read(context, expression) { return JSON.parse(vm.runInContext('JSON.stringify('+expression+')',context,{timeout:3000})); }
function click(context, id) {
  const marker = vm.runInContext('document.getElementById('+JSON.stringify(id)+').getAttribute("data-pirc-script-id")', context);
  return JSON.parse(vm.runInContext('__pircDocument.dispatch('+JSON.stringify({id:marker,type:'click'})+')',context,{timeout:3000}));
}
function evalScript(context, script) { return vm.runInContext(script,context,{timeout:3000}); }

test('programmatic checkbox click activates before listeners and commits input/change', () => {
  const context = page(`<input id="check" type="checkbox"><script>
    const check=document.getElementById('check');window.seen=[];
    for(const type of ['click','input','change'])check.addEventListener(type,e=>seen.push([type,check.checked]));
    check.click();window.checked=check.checked;
  </script>`);
  assert.equal(read(context,'window.checked'), true);
  assert.deepEqual(read(context,'window.seen'), [['click',true],['input',true],['change',true]]);
});

test('shared programmatic activation corpus equals independent Chrome155 observations', () => {
  assert.equal(createHash('sha256').update(fixtureSource).digest('hex'),chrome.fixtureSha256);
  const context=page(fixtureHtml);const result=click(context,'run-activation-checks');
  assert.deepEqual(result.diagnostics.filter(d=>d.severity!=='info'),[]);
  assert.deepEqual(read(context,'window.documentActivationResult'),chrome.programmatic);
});

test('host reset runs once and host labels defer to the native activation and focus path', () => {
  const context=page(`<form id="f"><input id="value" value="original"><button id="reset" type="reset">Reset</button></form><label id="label" for="check">Check</label><input id="check" type="checkbox"><script>
    window.resets=0;window.clicks=0;window.cancel=false;
    document.getElementById('f').addEventListener('reset',e=>{resets++;if(cancel)e.preventDefault()});
    document.getElementById('check').addEventListener('click',()=>clicks++);
  </script>`);
  evalScript(context,"document.getElementById('value').value='edited'");
  const reset=click(context,'reset');assert.equal(reset.defaultHandled,true);
  assert.deepEqual(read(context,"[resets,document.getElementById('value').value]"),[1,'original']);
  evalScript(context,"cancel=true;document.getElementById('value').value='keep'");click(context,'reset');
  assert.deepEqual(read(context,"[resets,document.getElementById('value').value]"),[2,'keep']);
  const label=click(context,'label');assert.equal(label.defaultHandled,false);
  assert.deepEqual(read(context,"[clicks,document.getElementById('check').checked]"),[0,false]);
});

test('programmatic submit queues one existing form action and honors validation and cancellation', () => {
  const context=page(`<form id="f" action="/send" method="post"><input id="q" name="q" required><button id="send" name="go" value="yes">Send</button></form><script>
    window.submits=0;window.cancel=false;document.getElementById('f').addEventListener('submit',e=>{submits++;if(cancel)e.preventDefault()});
  </script>`);
  evalScript(context,"document.getElementById('send').click()");
  assert.equal(read(context,'submits'),0);
  evalScript(context,"document.getElementById('q').value='中文';document.getElementById('send').click()");
  let result=JSON.parse(evalScript(context,'__pircDocument.snapshot()'));
  const submits=result.formActions.filter(a=>a.kind==='submit');assert.equal(submits.length,1);
  assert.equal(submits[0].method,'post');assert.equal(submits[0].action,'/send');
  assert.equal(read(context,'submits'),1);
  evalScript(context,"cancel=true;document.getElementById('send').click()");
  result=JSON.parse(evalScript(context,'__pircDocument.snapshot()'));
  assert.equal(result.formActions.filter(a=>a.kind==='submit').length,0);
  assert.equal(read(context,'submits'),2);
});

test('detached checkable cancellation restores its own state and same-root radio grouping', () => {
  const context=page('<p>Detached controls</p>');
  evalScript(context,`window.detached=[];const box=document.createElement('input');box.type='checkbox';box.indeterminate=true;
    box.addEventListener('click',e=>e.preventDefault());box.click();detached.push(box.checked,box.indeterminate);
    const radio=document.createElement('input');radio.type='radio';radio.name='outside';radio.addEventListener('click',e=>e.preventDefault());radio.click();detached.push(radio.checked);`);
  assert.deepEqual(read(context,'detached'),[false,true,false]);
});

test('click recursion is guarded and duplicate event dispatch rejects before a second activation', () => {
  const context=page('<input id="c" type="checkbox">');
  evalScript(context,`window.calls=0;window.nested='';const c=document.getElementById('c');
    c.addEventListener('click',e=>{calls++;c.click();try{c.dispatchEvent(e)}catch(error){nested=error.name}});c.click();`);
  assert.deepEqual(read(context,"[calls,nested,document.getElementById('c').checked]"),[1,'InvalidStateError',true]);
});

test('programmatic activation grants no new popup authority and inherits a live host gesture', () => {
  const context=page(`<button id="outer" type="button">Outer</button><input id="inner" type="checkbox"><script>
    document.getElementById('inner').onclick=()=>window.open('/child','_blank');
    document.getElementById('outer').onclick=()=>document.getElementById('inner').click();
    document.getElementById('inner').click();
  </script>`);
  let result=JSON.parse(evalScript(context,'__pircDocument.snapshot()'));assert.equal(result.navigationActions.length,0);
  result=click(context,'outer');assert.equal(result.navigationActions.length,1);
  assert.equal(result.navigationActions[0].url,'https://example.test/child');
});


test('throwing click listeners do not skip later handlers or an uncanceled reset', () => {
  const context=page(`<form id="f"><input id="q" value="original"><button id="r" type="reset">Reset</button></form><script>
    window.afterThrow=0;document.getElementById('q').value='edited';
    document.getElementById('r').addEventListener('click',()=>{throw new Error('synthetic listener failure')});
    document.getElementById('r').addEventListener('click',()=>afterThrow++);
    document.getElementById('r').click();
  </script>`);
  assert.deepEqual(read(context,"[afterThrow,document.getElementById('q').value]"),[1,'original']);
  const result=JSON.parse(evalScript(context,'__pircDocument.snapshot()'));
  assert.equal(result.diagnostics.filter(d=>d.code==='script.click_listener_error').length,1);
});
