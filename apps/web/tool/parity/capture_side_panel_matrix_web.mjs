import { requireTestBrowserExecutable } from '../../../../scripts/e2e/test_browser.mjs';
import assert from 'node:assert/strict';
import { createServer } from '../../node_modules/vite/dist/node/index.js';
import { createRequire } from 'node:module';
import { readFile, mkdir, writeFile, realpath } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { resolve } from 'node:path';

const root = resolve(import.meta.dirname, '../../../..');
const fixtureDir = resolve(root, 'fixtures/mobile-parity');
const matrix = JSON.parse(await readFile(resolve(fixtureDir, 'side-panel-matrix.json'), 'utf8'));
const out = resolve(root, 'apps/web/build/parity/side-panel-matrix-web');
const smoke = process.argv.includes('--smoke');
const port = Number(process.env.PIRC_PARITY_PORT ?? 18924);
const require = createRequire(resolve(root, 'apps/gateway/package.json'));
const { chromium } = require('playwright-core');

execFileSync(
  'git',
  ['diff', '--exit-code', matrix.webRevision, '--', 'apps/web', ':!apps/web/tool'],
  { cwd: root },
);

const sourceNames = Object.values(matrix.contentFixtures);
const sourceFixtures = {};
for (const name of sourceNames) {
  const fixture = JSON.parse(await readFile(resolve(fixtureDir, name), 'utf8'));
  assert.equal(fixture.webRevision, matrix.webRevision, `${name} revision mismatch`);
  sourceFixtures[name] = fixture;
}
const embed = JSON.stringify({ matrix, sourceFixtures }).replaceAll('<', '\\u003c');
await mkdir(out, { recursive: true });

const server = await createServer({
  cacheDir: resolve(out, 'vite-cache'),
  root: resolve(root, 'apps/web'),
  configFile: resolve(root, 'apps/web/vite.config.ts'),
  server: {
    host: '127.0.0.1',
    port,
    strictPort: true,
    fs: { allow: [root, await realpath(resolve(root, 'node_modules'))] },
  },
  plugins: [
    {
      name: 'side-panel-matrix-fixture',
      configureServer(vite) {
        vite.middlewares.use('/parity-side-panel.html', async (_, res, next) => {
          const html = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="icon" href="data:,"><style>
:root{font-family:Arial,sans-serif!important;--font-mono:Menlo,monospace!important}
html,body,#app{height:100%;margin:0}body{overflow:hidden;-webkit-font-smoothing:antialiased}
#fixture{position:absolute;top:56px;right:0;bottom:0;width:var(--desktop-panel-width);display:flex}
.xterm-cursor-layer{animation:none!important}
</style></head><body><div id="fixture"></div><script type="module">
import '/src/app.css'; import '/src/markdown.css';
import { mount, tick } from 'svelte';
import SidePanel from '/src/lib/components/panel/SidePanel.svelte';
import { app } from '/src/lib/app.svelte.ts';
const payload=${embed}; const {matrix,sourceFixtures}=payload;
const view=new URLSearchParams(location.search).get('view');
const width=Number(new URLSearchParams(location.search).get('width'));
const scale=Number(new URLSearchParams(location.search).get('scale'));
const theme=new URLSearchParams(location.search).get('theme');
const chrome=sourceFixtures[matrix.contentFixtures.chrome];
const files=sourceFixtures[matrix.contentFixtures.files];
const git=sourceFixtures[matrix.contentFixtures.git];
const memory=sourceFixtures[matrix.contentFixtures.memory];
const tasks=structuredClone(sourceFixtures[matrix.contentFixtures.tasks]);
const terminal=sourceFixtures[matrix.contentFixtures.terminal];
const browser=sourceFixtures[matrix.contentFixtures.browser];
const captureNow=Date.now();
const taskTimeDelta=captureNow-tasks.now;
for(const task of tasks.panel.backgroundTasks??[]){
  if(typeof task.startedAt==='number')task.startedAt+=taskTimeDelta;
  if(typeof task.endedAt==='number')task.endedAt+=taskTimeDelta;
}
tasks.now=captureNow;
Date.now=()=>captureNow;
app.workspaces=[{id:'w',kind:'directory',displayName:'Workspace',path:'/workspace/native-parity'}];
app.activeSessionId='s'; app.clientId='parity-client'; app.connection='connected';
app.sessionState={session:{id:'s',name:'Side panel parity',workspaceId:'w'},run:{status:'idle'},control:{heldByCurrentClient:true,generation:3},messages:[],interactions:[],widgets:{}};
app.panel.reset('s');
window.fixtureRequests=[];window.fixtureSocketEvents=[];window.fixtureErrors=[];
function response(data,status=200){return new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json; charset=utf-8'}})}
window.fetch=(input,init={})=>{
  const url=new URL(typeof input==='string'?input:input.url,location.href);
  const method=(init.method??'GET').toUpperCase();
  window.fixtureRequests.push({method,path:url.pathname+url.search,body:typeof init.body==='string'?init.body:null});
  const path=url.pathname, query=url.searchParams;
  if(path.endsWith('/panel/context'))return Promise.resolve(response(chrome.context));
  if(path.endsWith('/panel/state'))return Promise.resolve(response(view==='memory'?memory.panel:tasks.panel));
  if(path.endsWith('/files/content')){
    const raw=query.get('path')??'';
    const entry=Object.values(files.files).find(item=>item.path===raw);
    return Promise.resolve(entry?response(entry):response({error:'fixture file missing'},404));
  }
  if(path.endsWith('/files'))return Promise.resolve(response(files.directory));
  if(path.endsWith('/git/status'))return Promise.resolve(response(git.status));
  if(path.endsWith('/git/log'))return Promise.resolve(response(git.log));
  if(path.endsWith('/git/diff'))return Promise.resolve(response(git.diff));
  if(path.includes('/git/commits/'))return Promise.resolve(response(git.commit));
  if(path.includes('/panel/background/'))return Promise.resolve(response(tasks.output));
  if(path.endsWith('/terminals'))return Promise.resolve(response({terminals:terminal.terminals}));
  window.fixtureErrors.push('unexpected fetch '+method+' '+path+url.search);
  return Promise.reject(new Error('Unexpected parity fetch '+method+' '+path+url.search));
};
window.WebSocket=class FixtureSocket extends EventTarget{
  static OPEN=1;readyState=1;url;
  constructor(url){super();this.url=String(url);queueMicrotask(()=>{
    if(this.url.includes('/browser/stream')){
      this.dispatchEvent(new Event('open'));
      for(const frame of [
        {type:'state',state:browser.state},
        {type:'log',entries:browser.log},
        {type:'frame',data:browser.image,width:640,height:400},
      ])this.frame(frame);
    }else if(this.url.includes('/terminals/')){
      for(const frame of [{type:'ready',replay:terminal.replay}])this.frame(frame);
    }
  });}
  frame(value){window.fixtureSocketEvents.push({url:this.url,type:value.type});this.dispatchEvent(new MessageEvent('message',{data:JSON.stringify(value)}));}
  send(raw){window.fixtureSocketEvents.push({url:this.url,sent:JSON.parse(raw)});}
  close(){this.readyState=3;}
};
const phone=width<=650;
const overlay=width<=860;
const maxWidth=Math.max(280,width-264-380);
const panelWidth=overlay?Math.min(420,width-16):Math.min(360,maxWidth);
document.querySelector('#fixture').style.setProperty('--desktop-panel-width',panelWidth+'px');
const mounted=mount(SidePanel,{target:document.querySelector('#fixture'),props:{open:true,tab:view,width:panelWidth,minWidth:280,maxWidth}});
const readySelector={files:'.file-row',git:'.branch-line, .panel-empty, .panel-error',memory:'.memory-status, .panel-empty, .panel-error',context:'.usage-bar, [role=status], [role=alert]',tasks:'.group-title, .panel-empty, .panel-error',terminal:'.terminal-tab, .panel-empty, .panel-error',browser:'.browser-tab, .panel-empty, .panel-error'}[view];
for(let n=0;n<300&&!document.querySelector(readySelector);n++){await new Promise(r=>setTimeout(r,10));await tick();}
for(let n=0;n<50;n++){await tick();await new Promise(r=>setTimeout(r,10));}
await Promise.all([...document.images].map(i=>i.decode().catch(()=>{})));
await document.fonts.ready;
function scaleText(root,scale){
  const elements=[...root.querySelectorAll('*')];
  // This page is fresh for each state. Snapshot every computed size before
  // applying any overrides so descendants cannot inherit an already scaled
  // ancestor and receive a second multiplication.
  const base=elements.map(el=>[el,parseFloat(getComputedStyle(el).fontSize)]);
  for(const [el,size] of base)if(Number.isFinite(size))el.style.setProperty('font-size',(size*scale)+'px','important');
}
if(scale!==1)scaleText(document.querySelector('.side-panel'),scale);
await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
await tick();
function rect(el){const r=el.getBoundingClientRect();return{x:r.x,y:r.y,width:r.width,height:r.height,top:r.top,right:r.right,bottom:r.bottom,left:r.left}}
function style(el){const s=getComputedStyle(el);return{fontFamily:s.fontFamily,fontSize:s.fontSize,fontWeight:s.fontWeight,lineHeight:s.lineHeight,textTransform:s.textTransform,color:s.color,backgroundColor:s.backgroundColor,margin:s.margin,padding:s.padding,border:s.border,display:s.display,opacity:s.opacity}}
function clipChain(el){
  const chain=[{x:0,y:0,width:innerWidth,height:innerHeight,clipX:true,clipY:true,source:'viewport'}];
  for(let node=el;node;node=node.parentElement){
    const s=getComputedStyle(node),r=node.getBoundingClientRect();
    const clipX=/^(hidden|clip|auto|scroll)$/.test(s.overflowX);
    const clipY=/^(hidden|clip|auto|scroll)$/.test(s.overflowY);
    if(clipX||clipY)chain.push({x:r.x,y:r.y,width:r.width,height:r.height,clipX,clipY,source:node.tagName.toLowerCase()+(node.id?'#'+node.id:'')});
    if(node===activePanel)break;
  }
  return chain;
}
function intersectClip(value,chain){
  let out={x:value.x,y:value.y,width:value.width,height:value.height};
  for(const c of chain){
    if(c.clipX){const right=Math.min(out.x+out.width,c.x+c.width);out.x=Math.max(out.x,c.x);out.width=right-out.x;}
    if(c.clipY){const bottom=Math.min(out.y+out.height,c.y+c.height);out.y=Math.max(out.y,c.y);out.height=bottom-out.y;}
    if(out.width<=0||out.height<=0)return null;
  }
  return out;
}
const panel=document.querySelector('.side-panel');
const tablist=panel.querySelector('[role=tablist]');
const activePanel=panel.querySelector('[role=tabpanel]:not(.hidden)');
const textNodes=[];
const hiddenByClosedDetails=(element)=>{
  for(let ancestor=element;ancestor&&ancestor!==activePanel;ancestor=ancestor.parentElement){
    if(ancestor instanceof HTMLDetailsElement&&!ancestor.open){
      const summary=ancestor.querySelector(':scope > summary');
      return !summary?.contains(element);
    }
  }
  return false;
};
const walker=document.createTreeWalker(activePanel,NodeFilter.SHOW_TEXT);
let textNode;
while(textNode=walker.nextNode()){
  const text=textNode.textContent??'';
  if(!text.trim())continue;
  const owner=textNode.parentElement;if(!owner)continue;
  if(hiddenByClosedDetails(textNode))continue;
  const range=document.createRange(),chain=clipChain(owner),ranges=[];
  range.selectNodeContents(textNode);
  for(const r of range.getClientRects())ranges.push({x:r.x,y:r.y,width:r.width,height:r.height});
  const visibleTokens=[];
  for(const match of text.matchAll(/\\s+|[^\\s]+/gu)){
    range.setStart(textNode,match.index);range.setEnd(textNode,match.index+match[0].length);
    const raw=[...range.getClientRects()].map(r=>({x:r.x,y:r.y,width:r.width,height:r.height}));
    const visible=raw.map(r=>intersectClip(r,chain)).filter(Boolean);
    if(visible.length)visibleTokens.push({text:match[0],textRects:raw,visibleTextRects:visible});
  }
  textNodes.push({text,tag:owner.tagName.toLowerCase(),className:typeof owner.className==='string'?owner.className:'',rect:rect(owner),textRects:ranges,visibleTokens,clipChain:chain,style:style(owner)});
}
const allControls=[...activePanel.querySelectorAll('button,a,input,textarea,select,summary,[role=button],[role=tab],[role=progressbar]')].filter(el=>!hiddenByClosedDetails(el)).map(el=>({
  tag:el.tagName.toLowerCase(),role:el.getAttribute('role'),text:(el.innerText??el.textContent??'').trim(),
  ariaLabel:el.getAttribute('aria-label'),title:el.getAttribute('title'),type:el.getAttribute('type'),
  value:'value'in el?el.value:null,placeholder:el.getAttribute('placeholder'),
  disabled:'disabled'in el?el.disabled:false,effectiveDisabled:el.matches(':disabled'),
  ariaValueNow:el.getAttribute('aria-valuenow'),ariaValueMin:el.getAttribute('aria-valuemin'),ariaValueMax:el.getAttribute('aria-valuemax'),
  selected:el.getAttribute('aria-selected'),pressed:el.getAttribute('aria-pressed'),expanded:el.getAttribute('aria-expanded'),
  rect:rect(el),visibleRect:intersectClip(rect(el),clipChain(el)),clipChain:clipChain(el),style:style(el),
}));
const indicators=allControls.filter(el=>el.role==='progressbar');
const controls=allControls.filter(el=>el.role!=='progressbar');
const visibleTextRuns=textNodes.flatMap(node=>node.visibleTokens.map(token=>({text:token.text,tag:node.tag,className:node.className,textTransform:node.style.textTransform,textRects:token.textRects,visibleTextRects:token.visibleTextRects})));
const activeSlotText=activePanel.innerText;
window.captureResult={
  config:{width,height:innerHeight,theme,scale,view,pointer:{hover:matchMedia('(hover: hover)').matches,anyHover:matchMedia('(any-hover: hover)').matches,pointer:matchMedia('(pointer: fine)').matches?'fine':'coarse',maxTouchPoints:navigator.maxTouchPoints}},
  source:{component:'SidePanel.svelte + actual tab child; source app CSS and panel.css',mount:'component in production-equivalent 56px header/desktop panel slot; App.svelte control/panel-width formulas',notWholeAppShell:true},
  browser:{userAgent:navigator.userAgent,language:navigator.language,timeZone:Intl.DateTimeFormat().resolvedOptions().timeZone},
  runtimeFonts:{rootOverride:'Arial + Menlo, matching existing parity capture convention; comparison only, not the shipped macOS/Android system-font stacks'},
  panel:{rect:rect(panel),style:style(panel),scrollTop:panel.scrollTop,scrollHeight:panel.scrollHeight,clientHeight:panel.clientHeight},
  tablist:{rect:rect(tablist),style:style(tablist),text:tablist.innerText,scrollWidth:tablist.scrollWidth,clientWidth:tablist.clientWidth},
  tabs:[...tablist.querySelectorAll('[role=tab]')].map(el=>({label:el.innerText.trim(),role:el.getAttribute('role'),title:el.title,selected:el.getAttribute('aria-selected'),tabindex:el.tabIndex,rect:rect(el),style:style(el)})),
  activePanel:{id:activePanel.id,rect:rect(activePanel),style:style(activePanel),text:activeSlotText,scrollTop:activePanel.scrollTop,scrollHeight:activePanel.scrollHeight,clientHeight:activePanel.clientHeight},
  textNodes,visibleTextRuns,visibleText:visibleTextRuns.map(run=>run.text).join(''),controls,indicators,apiRequests:window.fixtureRequests,socketEvents:window.fixtureSocketEvents,fixtureErrors:window.fixtureErrors,
  canvasContent:view==='terminal'?{kind:'xterm replay fixture',text:terminal.replay}:view==='browser'?{kind:'browser frame fixture',state:browser.state,log:browser.log,imageBytes:atob(browser.image).length,width:640,height:400}:null,
};
window.captureReady=true;
</script></body></html>`;
          try {
            res.setHeader('Content-Type', 'text/html; charset=utf-8');
            res.end(await vite.transformIndexHtml('/parity-side-panel.html', html));
          } catch (error) {
            next(error);
          }
        });
      },
    },
  ],
});

let browser;
try {
  await server.listen();
  browser = await chromium.launch({
    executablePath: requireTestBrowserExecutable(),
    headless: true,
  });
  const cases = [];
  for (const width of smoke ? [matrix.widths[0]] : matrix.widths) {
    for (const view of matrix.views) {
      for (const theme of smoke ? [matrix.themes[0]] : matrix.themes) {
        for (const scale of smoke ? [1] : matrix.textScales) {
          const context = await browser.newContext({
            viewport: { width, height: matrix.height },
            deviceScaleFactor: 1,
            isMobile: true,
            hasTouch: true,
            locale: 'en-US',
            colorScheme: theme,
          });
          const page = await context.newPage();
          const errors = [];
          page.on('pageerror', (error) => errors.push(error.stack ?? error.message));
          page.on('console', (message) => {
            if (message.type() === 'error') errors.push(message.text());
          });
          page.on('response', (response) => {
            if (response.status() >= 400) errors.push(`${response.status()} ${response.url()}`);
          });
          await page.goto(
            `http://127.0.0.1:${port}/parity-side-panel.html?width=${width}&view=${view}&theme=${theme}&scale=${scale}`,
          );
          await page.waitForFunction(() => window.captureReady === true, null, { timeout: 20000 });
          const result = await page.evaluate(() => window.captureResult);
          assert.equal(result.config.width, width);
          assert.equal(result.config.view, view);
          assert.equal(result.config.theme, theme);
          assert.equal(result.config.scale, scale);
          assert.equal(result.fixtureErrors.length, 0, `${view} unexpected fixture requests`);
          assert.ok(result.activePanel.text.trim().length > 0, `${view} has no actual tab content`);
          assert.ok(
            result.apiRequests.length > 0 || ['browser'].includes(view),
            `${view} has no endpoint receipts`,
          );
          assert.deepEqual(errors, [], `${width}/${view}/${theme}/${scale} browser errors`);
          const id = `${width}-${view}-${theme}-scale${scale}`;
          const screenshot = resolve(out, `${id}.png`);
          await page.screenshot({ path: screenshot });
          cases.push({ id, ...result, screenshot: screenshot.replace(root + '/', '') });
          await context.close();
        }
      }
    }
  }
  const output = {
    schemaVersion: 1,
    fixtureId: matrix.id,
    webRevision: matrix.webRevision,
    browser: { version: browser.version(), executable: requireTestBrowserExecutable() },
    sourceFixtures: Object.fromEntries(
      Object.entries(sourceFixtures).map(([name, fixture]) => [name, fixture.id]),
    ),
    captureEnvironment: matrix.captureEnvironment,
    caseCount: cases.length,
    cases,
  };
  const expectedCount =
    (smoke ? 1 : matrix.widths.length) *
    matrix.views.length *
    (smoke ? 1 : matrix.themes.length) *
    (smoke ? 1 : matrix.textScales.length);
  assert.equal(cases.length, expectedCount);
  await writeFile(
    smoke
      ? resolve(out, 'side-panel-matrix-smoke.json')
      : resolve(fixtureDir, 'side-panel-matrix-expected.json'),
    JSON.stringify(output, null, 2) + '\n',
  );
} finally {
  await browser?.close();
  await server.close();
}
