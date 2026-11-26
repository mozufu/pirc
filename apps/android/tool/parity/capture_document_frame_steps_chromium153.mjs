import {createRequire} from 'node:module';
import {writeFile} from 'node:fs/promises';
import {requireTestBrowserExecutable} from './test_browser.mjs';
const require=createRequire(import.meta.url);
const {chromium}=require('playwright-core');
const executablePath=requireTestBrowserExecutable();
const html=`<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;padding:0}#target{display:block;width:100px;height:40px;margin:20px;background:#3b82f6}
</style></head><body><div id="target"></div><button id="start">Start frame test</button><pre id="probe">WAIT</pre>
<script>
var target=document.getElementById('target');
document.getElementById('start').onclick=function(){
 var events=[],times={},geometry={},cancelled;
 requestAnimationFrame(function(t){
  events.push('first');times.first=t;
  Promise.resolve().then(function(){events.push('promise-first');target.style.width='160px';cancelAnimationFrame(cancelled)});
  requestAnimationFrame(function(t){
   events.push('nested');times.nested=t;geometry.nested=target.clientWidth;
   var r=target.getBoundingClientRect();
   document.getElementById('probe').textContent=JSON.stringify({events:events,geometry:geometry,
    sameFrame:times.first===times.second&&times.second===times.third,nextFrame:times.nested>times.first,
    rect:{x:r.x,y:r.y,width:r.width,height:r.height}});
  });
 });
 requestAnimationFrame(function(t){
  events.push('second');times.second=t;geometry.second=target.clientWidth;
  Promise.resolve().then(function(){events.push('promise-second');target.style.width='180px'});
 });
 cancelled=requestAnimationFrame(function(){events.push('cancelled')});
 requestAnimationFrame(function(t){events.push('third');times.third=t;geometry.third=target.clientWidth});
};
</script></body></html>`;
const browser=await chromium.launch({executablePath,headless:true});
try {
 const browserVersion=browser.version();
 if(!browserVersion.startsWith('153.'))throw new Error('Expected dedicated Chromium 153, got '+browserVersion);
 const cases=[];
 for(const viewport of [{width:390,height:844},{width:768,height:1024}])for(const dpr of [1,3])for(const theme of ['light','dark']){
  const context=await browser.newContext({viewport,deviceScaleFactor:dpr,colorScheme:theme});
  const requests=[],pageErrors=[];
  try{
   await context.route('**/*',route=>{requests.push(route.request().url());return route.abort()});
   const page=await context.newPage();page.on('pageerror',e=>pageErrors.push(String(e)));
   await page.setContent(html);await page.locator('#start').click();
   await page.waitForFunction(()=>document.getElementById('probe').textContent.startsWith('{'));
   const result=JSON.parse(await page.locator('#probe').textContent());
   if(requests.length||pageErrors.length)throw new Error(JSON.stringify({requests,pageErrors}));
   cases.push({viewport,dpr,theme,result,networkRequests:requests,pageErrors});
  }finally{await context.close()}
 }
 await writeFile(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-frame-steps-chromium153.json',import.meta.url),JSON.stringify({browserVersion,html,cases})+'\n');
 console.log(JSON.stringify({browserVersion,cases:cases.length,requests:0,pageErrors:0}));
}finally{await browser.close()}
