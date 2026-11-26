import {createRequire} from 'node:module';
import {createServer} from 'node:http';
import {writeFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {requireTestBrowserExecutable} from './test_browser.mjs';
const require=createRequire(new URL('../../../gateway/package.json',import.meta.url));
const {chromium}=require('playwright-core');
const cases=[
 {name:'scope-and-shadowing',source:`import {value} from './dep.js';window.result=[];try{for(let value of [value]){}}catch(e){result.push(e.name)};try{const C=class value extends value{}}catch(e){result.push(e.name)};try{const obj={arguments};result.push(obj.arguments)}catch(e){result.push(e.name)};try{this.missing}catch(e){result.push(e.name)};result.push(this?.missing,typeof arguments);`,modules:{'dep.js':'export const value=3;'}},
 {name:'default-class-initialization',source:`import D from './class.js';window.result=[D.name,D.observed];`,modules:{'class.js':`export default class {static observed=this.name;}`}},
 {name:'default-expression-tdz',source:`import value from './a.js';window.result=[value];`,modules:{'a.js':`import {read} from './b.js';export default read();`,'b.js':`import value from './a.js';export function read(){try{return typeof value}catch(e){return e.name}}`}},
 {name:'live-bindings-and-functions',source:`import {count,inc} from './state.js';import * as ns from './state.js';window.result=[count];inc();result.push(count,ns.count,ns.inc===inc,Object.isExtensible(ns),Object.getPrototypeOf(ns));`,modules:{'state.js':`export let count=1;export function inc(){count++}`}},
 {name:'function-cycle',source:`import {a} from './a.js';window.result=[a()];`,modules:{'a.js':`import {b} from './b.js';export function a(){return 'a'+b()};`,'b.js':`import {a} from './a.js';export function b(){return typeof a};`}},
 {name:'dynamic-import-cache',source:`const [a,b]=await Promise.all([import('./dep.js'),import('./dep.js')]);window.result=[a.value,a===b,window.depRuns];`,modules:{'dep.js':`window.depRuns=(window.depRuns||0)+1;export const value=7;`}},
 {name:'inline-base-meta',source:`window.result=[this,typeof arguments,document.currentScript,import.meta.url,import.meta.resolve('./asset.svg')];`,base:'/folder/',modules:{}},
];
const requests=[];
const server=createServer((req,res)=>{
 const url=new URL(req.url,'http://test');const parts=url.pathname.split('/').filter(Boolean);
 const index=Number(parts[0]),current=cases[index];if(!current){res.statusCode=404;res.end();return}
 const name=parts.slice(1).join('/');requests.push({index,path:name});
 if(name==='page') {res.setHeader('Content-Type','text/html');res.end((current.base?'<base href="'+current.base+'">':'')+'<script type="module">'+current.source+'</script>');}
 else if(Object.hasOwn(current.modules,name)) {res.setHeader('Content-Type','text/javascript');res.end(current.modules[name]);}
 else{res.statusCode=404;res.end();}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const origin='http://127.0.0.1:'+server.address().port;
let browser;
try{
 browser=await chromium.launch({executablePath:requireTestBrowserExecutable(),headless:true});
 const results=[];
 for(let index=0;index<cases.length;index++){
  const page=await browser.newPage();const errors=[];page.on('pageerror',error=>errors.push(error.message));
  await page.goto(origin+'/'+index+'/page');await page.waitForFunction(()=>Array.isArray(window.result));
  const value=await page.evaluate(()=>window.result);await page.close();
  if(errors.length)throw new Error(cases[index].name+': '+errors.join(';'));
  results.push({...cases[index],url:'$ORIGIN/'+index+'/page',expected:JSON.parse(JSON.stringify(value).replaceAll(origin,'$ORIGIN'))});
 }
 const fixture={browserVersion:browser.version(),browserExecutable:requireTestBrowserExecutable(),cases:results};
 const target=new URL('../../../../packages/pirc_render/test/fixtures/parity/document-modules-chromium153.json',import.meta.url);
 writeFileSync(target,JSON.stringify(fixture,null,2)+'\n');console.log('Captured '+results.length+' module cases: '+fileURLToPath(target));
}finally{await browser?.close();await new Promise(resolve=>server.close(resolve));}
