import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import nativeVm from 'node:vm';
import {createDocumentScriptHostVm} from './document_script_host_test_helper.mjs';
const vm=createDocumentScriptHostVm(nativeVm);
const bundle=readFileSync(new URL('../../assets/document-script-runtime.js',import.meta.url),'utf8');
const oracle=JSON.parse(readFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-media-chromium153.json',import.meta.url),'utf8'));
const rows=oracle.viewportMatrix.cases;
const queries=rows[0].queryObservations;
function runtime(html,environment) {const c=vm.createContext({});vm.runInContext(bundle,c,{timeout:5000});return {c,result:call(c,'init',{html,environment,url:'https://example.test/media'})};}
function call(c,name,arg={}) {return JSON.parse(vm.runInContext('__pircDocument.'+name+'('+JSON.stringify(arg)+')',c,{timeout:5000}));}
function read(c,expression) {return JSON.parse(vm.runInContext('JSON.stringify('+expression+')',c,{timeout:5000}));}
function env(row) {const config=row.configured;return {width:config.width,height:config.height,devicePixelRatio:config.deviceScaleFactor,dark:config.colorScheme==='dark',reducedMotion:config.reducedMotion==='reduce',pointer:config.hasTouch?'coarse':'fine',hover:config.hasTouch?'none':'hover',screenWidth:config.width,screenHeight:config.height};}

for(const row of rows) test('bundled matchMedia agrees with Chromium153 '+row.id,()=>{
 const input=queries.map(item=>item.query);
 const {c,result}=runtime('<html><head><style>html {font-size:'+(row.configured.rootFontScale*16)+'px}</style></head><body><script>window.observed='+JSON.stringify(input)+'.map(q=>{const m=matchMedia(q);return {media:m.media,matches:m.matches}});</script></body></html>',env(row));
 assert.deepEqual(result.diagnostics.filter(item=>item.severity==='error'),[]);
 assert.deepEqual(read(c,'[innerWidth,window.innerWidth,innerHeight,devicePixelRatio,screen.width,screen.height]'),[row.innerWidth,row.innerWidth,row.innerHeight,row.devicePixelRatio,row.screen.width,row.screen.height]);
 const actual=read(c,'observed');
 for(let i=0;i<input.length;i++) assert.deepEqual(actual[i],{media:row.queryObservations[i].media,matches:row.queryObservations[i].matches},row.id+' '+queries[i].id+' '+queries[i].query);
});

for(const row of oracle.resolutionContexts) test('native DPR context agrees with Chromium153 '+row.id,()=>{
 const {c}=runtime('<p>DPR</p>',env(row));
 for(const query of row.queryObservations) assert.equal(read(c,'matchMedia('+JSON.stringify(query.query)+').matches'),query.matches,query.id);
 assert.equal(read(c,'devicePixelRatio'),row.devicePixelRatio);
});

test('environment resize updates all MQL values atomically and dispatches native event properties',()=>{
 const html=`<p id="result"></p><script>
 window.queries=['(min-width:600px)','(orientation:landscape)','(prefers-color-scheme:dark)','(prefers-reduced-motion:reduce)','(resolution:2dppx)'];
 window.lists=queries.map(q=>matchMedia(q));window.events=[];window.resizeEvents=[];
 lists.forEach((m,index)=>m.addEventListener('change',e=>events.push({index,matches:e.matches,media:e.media,trusted:e.isTrusted,bubbles:e.bubbles,cancelable:e.cancelable,target:e.target===m,all:lists.map(q=>q.matches)})));
 window.onresize=function(e){resizeEvents.push({width:innerWidth,height:innerHeight,target:e.target===window,trusted:e.isTrusted,self:this===window});document.querySelector('#result').textContent=innerWidth+'x'+innerHeight};
 </script>`;
 const {c}=runtime(html,{width:390,height:844,pointer:'coarse',hover:'none'});
 const result=call(c,'updateEnvironment',{environment:{width:768,height:390,devicePixelRatio:2,dark:true,reducedMotion:true}});
 const events=read(c,'events');assert.equal(events.length,5);
 for(const event of events) {assert.deepEqual(event.all,[true,true,true,true,true]);assert.equal(event.trusted,true);assert.equal(event.bubbles,false);assert.equal(event.cancelable,false);assert.equal(event.target,true);}
 assert.deepEqual(read(c,'resizeEvents'),[{width:768,height:390,target:true,trusted:true,self:true}]);
 assert.match(result.html,/768x390/);
 call(c,'updateEnvironment',{environment:{width:768,height:390,devicePixelRatio:2,dark:true,reducedMotion:true}});
 assert.equal(read(c,'events.length'),5);assert.equal(read(c,'resizeEvents.length'),1);
 call(c,'updateEnvironment',{environment:{dark:false}});
 assert.equal(read(c,'resizeEvents.length'),1);assert.equal(read(c,'events.length'),6);
});

test('legacy listeners, onchange, public constructors and reentry stay usable',()=>{
 const {c}=runtime(`<script>
 window.m=matchMedia('(min-width:600px)');window.seen=[];window.legacy=e=>seen.push(['legacy',e.matches]);m.addListener(legacy);m.onchange=e=>seen.push(['property',e.matches]);
 window.publicEvent=new MediaQueryListEvent('change',{matches:true,media:'screen'});
 </script>`,{width:390,height:844});
 assert.deepEqual(read(c,'[publicEvent.matches,publicEvent.media,publicEvent.isTrusted]'),[true,'screen',false]);
 call(c,'updateEnvironment',{environment:{width:768}});
 assert.deepEqual(read(c,'seen'),[['legacy',true],['property',true]]);
 vm.runInContext('m.removeListener(legacy);m.onchange=null',c);
 call(c,'updateEnvironment',{environment:{width:390}});assert.equal(read(c,'seen.length'),2);
 assert.equal(read(c,"matchMedia('(min-width:600px)')!==matchMedia('(min-width:600px)')"),true);
});
