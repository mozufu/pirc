import {createRequire} from 'node:module';
import {createServer} from 'node:http';
import {writeFileSync} from 'node:fs';
import {requireTestBrowserExecutable} from './test_browser.mjs';
const require=createRequire(new URL('../../../gateway/package.json',import.meta.url));
const {chromium}=require('playwright-core');
const script=(source,attributes='')=>'<script '+attributes+'>'+source+'</script>';
const cases=[
 {name:'async-inline-module-does-not-interrupt-parser-classics',html:
  script(`window.trace=[];document.addEventListener('DOMContentLoaded',()=>trace.push('dcl'));window.addEventListener('load',()=>{window.result=trace})`)+
  script(`trace.push('module',typeof parserValue,document.currentScript===null)`,'type="module" async')+
  script(`let parserValue=2;trace.push('classic')`),resources:{}},
 {name:'lexical-class-mutation-and-window-properties',html:
  script(`let sharedCount=9;const sharedObject={n:4};class SharedThing{value(){return sharedCount}};var globalNumber=6;function globalReader(){return sharedObject.n}`)+
  script(`sharedCount++;sharedObject.n=5;window.result=[sharedCount,sharedObject.n,new SharedThing().value(),SharedThing.name,window.globalNumber,window.globalReader(),typeof window.sharedCount,typeof window.sharedObject,typeof window.SharedThing]`),resources:{}},
 {name:'strict-var-and-function-retain-global-scope',html:
  script(`"use strict";var strictNumber=17;function strictReader(){return strictNumber};`)+
  script(`window.result=[strictNumber,strictReader(),window.strictNumber,window.strictReader()]`),resources:{}},
 {name:'redeclaration-error-does-not-stop-later-scripts',html:
  script(`let stableValue=11;window.trace=['first']`)+script(`let stableValue=12;trace.push('unreachable')`)+
  script(`trace.push(stableValue);window.result=trace`),resources:{}},
 {name:'partial-runtime-failure-retains-initialized-and-tdz-bindings',html:
  script(`window.trace=[];let beforeFailure=3;let uninitialized=uninitialized;trace.push('unreachable')`)+
  script(`trace.push(beforeFailure);try{trace.push(uninitialized)}catch(e){trace.push(e.name)};window.result=trace`),resources:{}},
 {name:'syntax-failure-has-no-partial-execution',html:
  script(`window.trace=[]`)+script(`trace.push('unreachable');let duplicate;let duplicate;`)+
  script(`trace.push(typeof duplicate);window.result=trace`),resources:{}},
 {name:'external-and-deferred-shared-bindings-and-events',html:
  script(`window.trace=[];document.addEventListener('DOMContentLoaded',()=>{trace.push('dcl');window.result=trace})`)+
  `<script id="external" src="/classic.js" onload="trace.push('external-load')"></script>`+
  script(`trace.push(externalValue);externalValue++`)+
  `<script defer src="/deferred.js" onload="trace.push('defer-load')"></script>`,
  resources:{'/classic.js':`let externalValue=20;trace.push(document.currentScript.id)`,'/deferred.js':`trace.push(externalValue);externalValue++`}},
 {name:'classic-globals-visible-in-module-and-handler',html:
  '<button id="run" onclick="sharedValue++;window.handlerValue=sharedValue">Run</button>'+
  script(`let sharedValue=30;const fixedValue=2;class SharedClass{};`)+
  script(`document.querySelector('#run').click()`)+
  script(`window.result=[sharedValue,fixedValue,SharedClass.name,window.handlerValue,document.currentScript===null]`,'type="module"'),resources:{}},
 {name:'successful-script-microtasks-run-before-next-script',html:
  script(`let microtaskValue=1;window.trace=[document.currentScript.id];Promise.resolve().then(()=>{microtaskValue=2;trace.push(document.currentScript===null)})`,'id="first"')+
  script(`trace.push(microtaskValue);window.result=trace`),resources:{}},
 {name:'error-script-microtask-current-script',html:
  script(`window.trace=[];Promise.resolve().then(()=>trace.push(document.currentScript===null));throw new Error('ordinary synthetic failure')`)+
  script(`trace.push('continued');window.result=trace`),resources:{}},
 {name:'nested-inline-synchronous-effects-and-current-script',html:
  script(`window.trace=[document.currentScript.id];var nested=document.createElement('script');nested.id='nested';nested.textContent="var nestedNumber=4;trace.push(document.currentScript.id)";document.head.appendChild(nested);trace.push(nestedNumber,document.currentScript.id)`,'id="outer"')+
  script(`window.result=trace`),resources:{}},
 {name:'nested-inline-global-lexical-scope',knownDifference:'Synchronous DOM-inserted inline scripts use eval because AndroidX has no reentrant native Script evaluation callback.',html:
  script(`var nested=document.createElement('script');nested.textContent='let nestedLexical=5';document.head.appendChild(nested)`)+
  script(`window.result=[typeof nestedLexical]`),resources:{}},
 {name:'promise-valued-script-completion-does-not-block-parser',html:
  script(`window.trace=['first'];new Promise(()=>{})`)+script(`trace.push('second');window.result=trace`),resources:{}},
];
let current;const requests=[];
const server=createServer((req,res)=>{
 const path=new URL(req.url,'http://local').pathname;requests.push(path);
 if(path==='/page'){res.setHeader('Content-Type','text/html');res.end('<!doctype html><html><body>'+current.html+'</body></html>');return;}
 const source=current.resources[path];res.statusCode=source===undefined?404:200;res.setHeader('Content-Type','text/javascript');res.end(source||'');
});
await new Promise(done=>server.listen(0,'127.0.0.1',done));
const origin='http://127.0.0.1:'+server.address().port;let browser;
try{
 browser=await chromium.launch({executablePath:requireTestBrowserExecutable(),headless:true});const results=[];
 for(const item of cases){
  current=item;requests.length=0;const page=await browser.newPage();const errors=[];
  await page.route('**/*',route=>new URL(route.request().url()).origin===origin?route.continue():route.abort());
  page.on('pageerror',error=>errors.push(error.message));await page.goto(origin+'/page');
  await page.waitForFunction(()=>Array.isArray(window.result),{},{timeout:3000});
  const expected=await page.evaluate(()=>window.result);await page.close();
  results.push({...item,expected,requests:[...requests],errors});console.log(JSON.stringify({name:item.name,expected,errors}));
 }
 writeFileSync(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-classic-globals-chromium153.json',import.meta.url),JSON.stringify({browserVersion:browser.version(),browserExecutable:requireTestBrowserExecutable(),cases:results},null,2)+'\n');
}finally{await browser?.close();server.closeAllConnections();await new Promise(done=>server.close(done));}
