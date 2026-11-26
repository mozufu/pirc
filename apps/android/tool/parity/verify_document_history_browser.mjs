import { requireTestBrowserExecutable } from './test_browser.mjs';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
import {readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(scriptDirectory, '../../../..');
const require = createRequire(import.meta.url);
const {chromium} = require(require.resolve('playwright-core', {
  paths: [path.join(repositoryRoot, 'apps/gateway')],
}));
const chromePath = requireTestBrowserExecutable();
const policyNames = ['no-referrer', 'no-referrer-when-downgrade', 'origin', 'origin-when-cross-origin', 'same-origin', 'strict-origin', 'strict-origin-when-cross-origin', 'unsafe-url'];
assert.ok(await import('node:fs').then(fs => fs.existsSync(chromePath)));

const button = (id, label, operation, waitMode = 'settle', minEvents = 0) => ({
  action: 'tap-button', id, label, operation, waitMode, minEvents,
});
const link = (id, label, href, waitMode = 'document', minEvents = 0) => ({
  action: 'tap-link', id, label, href, waitMode, minEvents,
});

const cases = [
  {
    caseId: 'history-url-argument-matrix',
    steps: [
      button('push-empty', 'Push empty URL', "history.pushState({step:'push-empty'},'', ''); return history.state;"),
      button('replace-empty', 'Replace empty URL', "history.replaceState({step:'replace-empty'},'', ''); return history.state;"),
      button('push-undefined-url', 'Push undefined URL', "history.pushState({step:'push-undefined-url'},'', undefined); return history.state;"),
      button('push-null-url', 'Push null URL', "history.pushState({step:'push-null-url'},'', null); return history.state;"),
      button('push-relative', 'Push relative path', "history.pushState({step:'push-relative'},'', 'relative-child?case=history-url-argument-matrix&from=history#rel'); return history.state;"),
      button('push-root', 'Push root path', "history.pushState({step:'push-root'},'', '/root-child/path?case=history-url-argument-matrix'); return history.state;"),
      button('push-query', 'Push query URL', "history.pushState({step:'push-query'},'', '?case=history-url-argument-matrix&query=changed'); return history.state;"),
      button('push-hash', 'Push hash URL', "history.pushState({step:'push-hash'},'', '#changed-by-push'); return history.state;"),
    ],
  },
  {
    caseId: 'history-base-href-resolution',
    baseHref: '/base/directory/',
    steps: [
      button('push-relative-with-base', 'Push relative URL under base', "history.pushState({step:'relative-under-base'},'', 'relative-target?case=history-base-href-resolution&x=1#part'); return history.state;"),
      link('base-anchor', 'Navigate by base-resolved anchor', 'anchor-target?from=base&case=history-base-href-resolution'),
    ],
  },
  {
    caseId: 'history-replace-current-entry',
    steps: [
      button('replace-state', 'Replace current entry', "history.replaceState({replacement:{n:1}},'', '?case=history-replace-current-entry&replace=1'); return history.state;"),
      button('replace-same-url', 'Replace state at same URL', "history.replaceState({replacement:{n:2}},'', location.href); return history.state;"),
    ],
  },
  {
    caseId: 'history-state-clone-mutation-traversal',
    steps: [
      button('push-object-state', 'Push object state', "const original={nested:{value:1},label:'stored'}; window.__originalState=original; history.pushState(original,'','?case=history-state-clone-mutation-traversal&state=clone'); const first=history.state; const second=history.state; window.__stateIdentity={originalIsFirst:original===first,firstIsSecond:first===second}; return window.__stateIdentity;"),
      button('mutate-state-objects', 'Mutate original and state reads', "window.__originalState.nested.value=2; const first=history.state; first.nested.value=3; return {original:window.__originalState.nested.value,mutatedRead:first.nested.value,stored:history.state};"),
      button('back', 'Back to initial state', "history.back();", 'events', 1),
      button('forward', 'Forward to object state', "history.forward();", 'events', 1),
    ],
  },
  {
    caseId: 'history-state-supported-structured-values',
    steps: [
      button('push-structured-values', 'Push structured clone values', "const cycle={name:'cycle'}; cycle.self=cycle; const shared={value:7}; const state={undefinedField:undefined,nan:NaN,positiveInfinity:Infinity,negativeInfinity:-Infinity,date:new Date('2020-01-02T03:04:05.000Z'),map:new Map([['key',{nested:true}]]),cycle,bytes:new Uint16Array([1,65535]),array:[undefined,NaN],sharedA:shared,sharedB:shared}; history.pushState(state,'','?case=history-state-supported-structured-values&state=values'); const read1=history.state; const read2=history.state; return {read1,readAgainIdentity:read1===read2,sharedIdentity:read1.sharedA===read1.sharedB};"),
    ],
  },
  {
    caseId: 'history-state-clone-rejections-and-arity',
    steps: [
      button('push-function', 'Push function state', "history.pushState({callback:function sample(){}},'', '?bad=function');"),
      button('push-symbol', 'Push symbol state', "history.pushState({symbol:Symbol('synthetic')},'', '?bad=symbol');"),
      button('push-dom-node', 'Push DOM node state', "history.pushState({node:document.body},'', '?bad=node');"),
      button('push-missing-args', 'Call pushState with no arguments', "history.pushState();"),
      button('push-one-arg', 'Call pushState with one argument', "history.pushState({one:1});"),
      button('replace-missing-args', 'Call replaceState with no arguments', "history.replaceState();"),
      button('replace-one-arg', 'Call replaceState with one argument', "history.replaceState({one:1});"),
    ],
  },
  {
    caseId: 'history-url-security-errors',
    steps: [
      button('push-cross-origin', 'Push cross-origin URL', "history.pushState({bad:'cross-origin'},'', window.__otherOrigin+'/cross-origin');"),
      button('push-different-scheme', 'Push different-scheme URL', "history.pushState({bad:'scheme'},'', location.href.replace(/^http:/,'https:'));"),
      button('push-credentials-url', 'Push credentials URL', "const u=new URL(location.href); u.username='user'; u.password='synthetic'; history.pushState({bad:'credentials'},'',u.href);"),
      button('push-created-blob-url', 'Push created Blob URL', "const u=URL.createObjectURL(new Blob(['synthetic'],{type:'text/html'})); window.__testBlobUrl=u; history.pushState({bad:'blob-url'},'',u);"),
    ],
  },
  {
    caseId: 'history-blob-fragment-update',
    kind: 'blob',
    blobHtml: true,
    steps: [
      link('open-blob', 'Open Blob document', '#blob-document', 'blob'),
      button('push-blob-hash', 'Push Blob fragment URL', "history.pushState({blobHash:true},'',location.href+'#history-fragment'); return history.state;"),
      button('replace-blob-hash', 'Replace Blob fragment URL', "history.replaceState({blobHash:'replaced'},'',location.href.replace(/#history-fragment$/,'#replaced-fragment')); return history.state;"),
    ],
  },
  {
    caseId: 'history-out-of-bounds-traversals',
    steps: [
      button('go-negative-out-of-bounds', 'Go far back out of bounds', 'history.go(-999);', 'settle'),
      button('go-positive-out-of-bounds', 'Go far forward out of bounds', 'history.go(999);', 'settle'),
    ],
  },
  {
    caseId: 'history-queued-traversal-calls',
    steps: [
      button('push-entry-one', 'Push first entry', "history.pushState({n:1},'', '?case=history-queued-traversal-calls&entry=1');"),
      button('push-entry-two', 'Push second entry', "history.pushState({n:2},'', '?case=history-queued-traversal-calls&entry=2');"),
      button('queue-back-forward', 'Queue back then forward', "const trace=[];const mark=label=>{trace.push({label,href:location.href,length:history.length,state:history.state});window.name='pirc-history-sync-trace:'+JSON.stringify(trace);};mark('before-back-call');history.back();mark('after-back-call');mark('before-forward-call');history.forward();mark('after-forward-call');return trace;", 'settle'),
      button('forward-after-queue', 'Forward after queued traversals settle', 'history.forward();', 'events', 1),
    ],
  },
  {
    caseId: 'history-go-zero-reloads-entry-state',
    steps: [
      button('push-before-go-zero', 'Push state before go zero', "history.pushState({reloadState:{n:1}},'', '?case=history-go-zero-reloads-entry-state&go-zero=1');"),
      button('go-zero', 'Go to current entry', 'history.go(0);', 'document'),
    ],
  },
  {
    caseId: 'history-native-fragment-and-push-mixed',
    steps: [
      button('push-query-entry', 'Push query state', "history.pushState({route:'query'},'', '?case=history-native-fragment-and-push-mixed&route=query');"),
      button('set-location-hash', 'Set location.hash directly', "location.hash='#location-assignment-target';", 'events', 1),
      link('native-fragment', 'Navigate to native fragment', '#native-fragment-target', 'events', 2),
      button('push-hash-entry', 'Push hash state', "history.pushState({route:'push-hash'},'', '#push-hash-entry');"),
      button('back-once', 'Back one entry', 'history.back();', 'events', 1),
      button('back-twice', 'Back to query state', 'history.back();', 'events', 1),
      button('forward-once', 'Forward to fragment', 'history.forward();', 'events', 1),
    ],
  },
  {
    caseId: 'history-sync-back-then-push',
    steps: [
      button('sync-push-back-push', 'Push A, back, then push B in one task', "const trace=[];const mark=label=>{trace.push({label,href:location.href,length:history.length,state:history.state});window.name='pirc-history-sync-trace:'+JSON.stringify(trace);};history.pushState({entry:'A'},'', '?case=history-sync-back-then-push&entry=A');mark('after-push-A');mark('before-back-call');history.back();mark('after-back-call');history.pushState({entry:'B'},'', '?case=history-sync-back-then-push&entry=B');mark('after-push-B');return trace;", 'settle'),
      button('forward-once-after-sync', 'Forward once after traversal settles', 'history.forward();', 'events', 1),
      button('forward-twice-after-sync', 'Forward twice after traversal settles', 'history.forward();', 'events', 1),
    ],
  },
  {
    caseId: 'history-sync-push-back-back',
    steps: [
      button('sync-push-back-back', 'Push A then back twice in one task', "const trace=[];const mark=label=>{trace.push({label,href:location.href,length:history.length,state:history.state});window.name='pirc-history-sync-trace:'+JSON.stringify(trace);};history.pushState({entry:'A'},'', '?case=history-sync-push-back-back&entry=A');mark('after-push-A');mark('before-first-back-call');history.back();mark('after-first-back-call');mark('before-second-back-call');history.back();mark('after-second-back-call');return trace;", 'settle'),
    ],
  },
  {
    caseId: 'history-replace-state-native-fragment-replace',
    steps: [
      button('replace-state-and-fragment', 'Replace state then native fragment entry', "history.replaceState({entry:'replaced'},'',location.href); location.replace(location.href+'#native-replace');", 'events', 1),
    ],
  },
  {
    caseId: 'history-no-store-leave-return-state',
    steps: [
      button('push-state-before-leave', 'Push state before leaving', "history.pushState({preserved:{n:42}},'', '?case=history-no-store-leave-return-state&preserved=42');"),
      link('leave-document', 'Navigate to another document', '/away?case=history-no-store-leave-return-state', 'document'),
      button('back-to-saved-entry', 'Back to saved history entry', 'history.back();', 'document'),
    ],
  },
  {
    caseId: 'history-go-zero-out-of-bounds-after-back',
    steps: [
      button('push-entry-before-boundary-check', 'Push an entry before boundary checks', "history.pushState({boundary:'entry'},'', '?case=history-go-zero-out-of-bounds-after-back&entry=1');"),
      button('back-to-source-entry', 'Back to source entry', 'history.back();', 'events', 1),
      button('go-negative-out-of-bounds', 'Go back out of bounds', 'history.go(-999);', 'settle'),
      button('go-positive-out-of-bounds', 'Go forward out of bounds', 'history.go(999);', 'settle'),
    ],
  },
];

const caseById = new Map(cases.map(spec => [spec.caseId, spec]));
const selectedCases = process.env.PIRC_CASE_FILTER
  ? cases.filter(spec => process.env.PIRC_CASE_FILTER.split(',').includes(spec.caseId))
  : cases;
assert.equal(cases.length, 17, 'Keep the explicit History API matrix frozen.');
assert.ok(selectedCases.length > 0, 'PIRC_CASE_FILTER must select known cases.');

const requests = [];
const blockedProxyRequests = [];
const fixtureOrigins = {a: 'http://127.0.0.1:43280', b: 'http://localhost:43281'};
const origins = {a: '', b: ''};

function originFor(name) { return origins[name]; }
function fixtureOriginFor(name) { return fixtureOrigins[name]; }

function escapeHtml(value) {
  return String(value).replaceAll('&', '&amp;').replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;').replaceAll('>', '&gt;');
}

function commonProbeScript(spec) {
  const storageKey = '__codexHistoryOracle:' + spec.caseId;
  const operations = Object.fromEntries(spec.steps
    .filter(item => item.action === 'tap-button')
    .map(item => [item.id, item.operation]));
  const otherOrigin = originFor('b');
  return `<script>
    (()=>{
      const storageKey=${JSON.stringify(storageKey)};
      const operations=${JSON.stringify(operations)};
      const otherOrigin=${JSON.stringify(otherOrigin)};
      function describe(value, seen=new WeakMap(), path='root'){
        if(value===undefined)return {type:'undefined'};
        if(value===null)return null;
        if(typeof value==='number'){if(Number.isNaN(value))return {type:'number',value:'NaN'};if(value===Infinity)return {type:'number',value:'Infinity'};if(value===-Infinity)return {type:'number',value:'-Infinity'};return value;}
        if(typeof value==='bigint')return {type:'bigint',value:String(value)};
        if(typeof value==='symbol')return {type:'symbol',description:value.description??null};
        if(typeof value==='function')return {type:'function',name:value.name||''};
        if(typeof value!=='object')return value;
        if(value instanceof Node)return {type:'Node',nodeName:value.nodeName,nodeType:value.nodeType};
        if(value instanceof Date)return {type:'Date',value:Number.isNaN(value.getTime())?'Invalid Date':value.toISOString()};
        if(seen.has(value))return {type:'CircularReference',ref:seen.get(value)};
        seen.set(value,path);
        if(value instanceof Map)return {type:'Map',entries:[...value.entries()].map(([k,v],i)=>[describe(k,seen,path+'.key'+i),describe(v,seen,path+'.value'+i)])};
        if(value instanceof Set)return {type:'Set',values:[...value.values()].map((v,i)=>describe(v,seen,path+'.set'+i))};
        if(ArrayBuffer.isView(value))return {type:value.constructor.name,values:Array.from(value)};
        if(value instanceof ArrayBuffer)return {type:'ArrayBuffer',bytes:Array.from(new Uint8Array(value))};
        if(Array.isArray(value))return {type:'Array',values:value.map((v,i)=>describe(v,seen,path+'['+i+']'))};
        const out={type:Object.getPrototypeOf(value)?.constructor?.name||'Object',properties:{}};
        for(const key of Object.keys(value).sort())out.properties[key]=describe(value[key],seen,path+'.'+key);
        return out;
      }
      function readStored(){try{return JSON.parse(sessionStorage.getItem(storageKey)||'null');}catch(e){return null;}}
      const prior=readStored();
      const oracle={events:prior?.events||[],actions:prior?.actions||[],storageErrors:prior?.storageErrors||[],documentStarts:prior?.documentStarts||[]};
      window.__historyOracle=oracle;
      window.__otherOrigin=otherOrigin;
      function persist(){const encoded=JSON.stringify(oracle);try{sessionStorage.setItem(storageKey,encoded);}catch(e){oracle.storageErrors.push({name:e.name,message:e.message});}window.name='pirc-history-oracle:'+encoded;}
      function snapshot(){
        const stateOne=history.state; const stateTwo=history.state;
        const anchor=document.querySelector('[data-history-link]');
        return {href:location.href,origin:location.origin,protocol:location.protocol,host:location.host,pathname:location.pathname,search:location.search,hash:location.hash,documentURL:document.URL,documentURI:document.documentURI,baseURI:document.baseURI,baseHref:document.querySelector('base')?.href??null,anchorResolvedHref:anchor?.href??null,historyLength:history.length,historyState:describe(stateOne),historyStateReadIdentity:stateOne===stateTwo,documentReferrer:document.referrer,timeOrigin:performance.timeOrigin};
      }
      function paint(){const node=document.querySelector('#history-observation');if(node)node.textContent=JSON.stringify(snapshot());const log=document.querySelector('#history-log');if(log)log.textContent=JSON.stringify({events:oracle.events,actions:oracle.actions,documentStarts:oracle.documentStarts,storageErrors:oracle.storageErrors});}
      function recordEvent(type,event){
        const eventState=type==='popstate'?describe(event.state):null;
        const historyState=history.state;
        oracle.events.push({type,isTrusted:Boolean(event.isTrusted),eventState,eventHistoryState:describe(historyState),eventStateIsHistoryState:type==='popstate'?event.state===historyState:null,oldURL:event.oldURL??null,newURL:event.newURL??null,snapshot:snapshot()});
        persist();paint();
      }
      for(const type of ['popstate','hashchange','pageshow','pagehide','load'])addEventListener(type,event=>recordEvent(type,event));
      oracle.documentStarts.push({href:location.href,historyLength:history.length,historyState:describe(history.state),timeOrigin:performance.timeOrigin});
      persist();
      const operationFunctions={};
      for(const [id,source] of Object.entries(operations))operationFunctions[id]=new Function(source);
      document.addEventListener('click',event=>{
        const control=event.target.closest('button[data-history-action]');if(!control)return;
        const id=control.dataset.historyAction;const before=snapshot();let outcome;
        try{const result=operationFunctions[id]?.call(window);outcome={ok:true,result:describe(result)};}
        catch(error){outcome={ok:false,error:{name:error?.name??'Error',message:error?.message??String(error)}};}
        const afterImmediate=snapshot();oracle.actions.push({id,label:control.textContent.trim(),before,afterImmediate,outcome});persist();paint();
      });
      window.__historySnapshot=snapshot;window.__historyDescribe=describe;paint();
    })();
  </script>`;
}

function pageHtml(spec, options = {}) {
  const isBlobDocument = Boolean(options.isBlobDocument);
  const controls = spec.steps.map(item => item.action === 'tap-button'
    ? '<button type="button" data-history-action="' + escapeHtml(item.id) + '">' + escapeHtml(item.label) + '</button>'
    : '<a data-history-link="' + escapeHtml(item.id) + '" href="' + escapeHtml(item.href) + '">' + escapeHtml(item.label) + '</a>')
    .join('\n');
  const base = spec.baseHref ? '<base href="' + escapeHtml(spec.baseHref) + '">' : '';
  const fragmentTarget = spec.caseId === 'history-native-fragment-and-push-mixed'
    ? '<div id="location-assignment-target">location hash target</div><div id="native-fragment-target">native fragment target</div>'
    : '';
  return '<!doctype html><html><head><meta charset="utf-8">' + base +
    '<title>' + escapeHtml((isBlobDocument ? 'Blob ' : '') + spec.caseId) + '</title>' +
    '</head><body data-case="' + escapeHtml(spec.caseId) + '" data-blob-document="' + String(isBlobDocument) + '">' +
    '<h1>' + escapeHtml(spec.caseId) + (isBlobDocument ? ' Blob document' : '') + '</h1>' +
    '<nav>' + controls + '</nav>' + fragmentTarget +
    '<pre id="history-observation"></pre><pre id="history-log"></pre>' +
    commonProbeScript(spec) + '</body></html>';
}

function sourceHtmlFor(spec) {
  if (spec.blobHtml) {
    const embeddedHtml = pageHtml(spec, {isBlobDocument: true});
    const json = JSON.stringify(embeddedHtml).replaceAll('</script', '<\\/script');
    const html = pageHtml(spec).replace(
      '<a data-history-link="open-blob" href="#blob-document">Open Blob document</a>',
      '<a id="open-blob-document" data-history-link="open-blob" href="#">Open Blob document</a>',
    )
      .replace('</body>', '<script type="application/json" id="blob-history-html">' + json + '</script>' +
        '<script>const blobHtml=JSON.parse(document.querySelector("#blob-history-html").textContent);const blobUrl=URL.createObjectURL(new Blob([blobHtml],{type:"text/html"}));document.querySelector("#open-blob-document").href=blobUrl;</script></body>');
    return {html, embeddedHtml};
  }
  return {html: pageHtml(spec), embeddedHtml: null};
}

function normalizeOrigins(text) {
  let normalized = String(text);
  for (const name of ['a', 'b']) {
    const live = new URL(originFor(name));
    const fixture = new URL(fixtureOriginFor(name));
    normalized = normalized.replaceAll(originFor(name), fixtureOriginFor(name));
    normalized = normalized.replaceAll('https://' + live.host, 'https://' + fixture.host);
    normalized = normalized.replaceAll(live.host, fixture.host);
  }
  normalized = normalized.replace(/blob:(http:\/\/127\.0\.0\.1:\d+\/)[0-9a-f-]{20,}/gi, 'blob:' + fixtureOriginFor('a') + '/<blob-id>');
  return normalized;
}

function normalizeFixtureValue(value) {
  if (typeof value === 'string') return normalizeOrigins(value);
  if (Array.isArray(value)) return value.map(normalizeFixtureValue);
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, normalizeFixtureValue(item)]));
  return value;
}

function caseIdFrom(requestUrl, referer) {
  const direct = requestUrl.searchParams.get('case');
  if (direct) return direct;
  if (referer) {
    try { return new URL(referer).searchParams.get('case') ?? null; } catch (_) {}
  }
  return null;
}

function makeServer(serverName) {
  return createServer(async (request, response) => {
    const baseOrigin = originFor(serverName);
    const requestUrl = new URL(request.url ?? '/', baseOrigin);
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const body = Buffer.concat(chunks).toString('utf8');
    const caseId = caseIdFrom(requestUrl, request.headers.referer ?? null);
    const event = {
      sequence: requests.length + 1,
      caseId,
      server: serverName,
      serverOrigin: baseOrigin,
      method: request.method ?? '',
      url: requestUrl.href,
      path: requestUrl.pathname + requestUrl.search,
      body: body || null,
      origin: request.headers.origin ?? null,
      referer: request.headers.referer ?? null,
      authorization: request.headers.authorization ?? null,
      authorizationPresent: Boolean(request.headers.authorization),
      responseStatus: null,
      responseLocation: null,
      responseBody: '',
    };
    requests.push(event);
    if (request.method === 'GET' && requestUrl.pathname === '/favicon.ico') {
      event.responseStatus = 204;
      response.writeHead(204, {'cache-control': 'no-store'});
      response.end();
      return;
    }
    const spec = caseById.get(caseId);
    if (request.method === 'GET' && spec) {
      const generated = sourceHtmlFor(spec);
      event.responseStatus = 200;
      event.responseBody = generated.html;
      response.writeHead(200, {'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store'});
      response.end(generated.html);
      return;
    }
    event.responseStatus = 404;
    event.responseBody = 'Unexpected loopback history oracle request';
    response.writeHead(404, {'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store'});
    response.end(event.responseBody);
  });
}

async function listen(server, host) {
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, host, () => { server.off('error', reject); resolve(); });
  });
  return 'http://' + host + ':' + server.address().port;
}

async function closeServer(server) {
  if (server.listening) await new Promise(resolve => server.close(resolve));
}

function chromeCommandLine() {
  const lines = execFileSync('ps', ['-axo', 'pid=,command='], {encoding: 'utf8'}).split('\n');
  const matches = lines.filter(line => line.includes(chromePath) && line.includes('--user-data-dir=') && !line.includes('--type='));
  return matches.at(-1)?.trim() ?? '';
}

async function snapshot(page, label, cdp = null) {
  const result = await page.evaluate(labelValue => {
    const liveOracle = window.__historyOracle;
    let persistedOracle = null;
    let syncTraceFromWindowName = null;
    if (!liveOracle && typeof window.name === 'string' && window.name.startsWith('pirc-history-oracle:')) {
      try { persistedOracle = JSON.parse(window.name.slice('pirc-history-oracle:'.length)); } catch (_) {}
    }
    if (typeof window.name === 'string' && window.name.startsWith('pirc-history-sync-trace:')) {
      try { syncTraceFromWindowName = JSON.parse(window.name.slice('pirc-history-sync-trace:'.length)); } catch (_) {}
    }
    const oracle = liveOracle ?? persistedOracle ?? {events: [], actions: [], documentStarts: [], storageErrors: []};
    const describe = window.__historyDescribe ?? (value => value === undefined ? {type:'undefined'} : value);
    let historyState = null;
    try { historyState = describe(history.state); } catch (_) {}
    let parsedObservation = null;
    try { parsedObservation = JSON.parse(document.querySelector('#history-observation')?.textContent ?? 'null'); } catch (_) {}
    return {
    label: labelValue,
    href: location.href,
    origin: location.origin,
    protocol: location.protocol,
    host: location.host,
    pathname: location.pathname,
    search: location.search,
    hash: location.hash,
    documentURL: document.URL,
    documentURI: document.documentURI,
    baseURI: document.baseURI,
    baseHref: document.querySelector('base')?.href ?? null,
    anchorResolvedHref: document.querySelector('[data-history-link]')?.href ?? null,
    historyLength: history.length,
    historyState,
    historyStateReadIdentity: history.state === history.state,
    documentReferrer: document.referrer,
    events: oracle.events,
    actions: oracle.actions,
    documentStarts: oracle.documentStarts,
    storageErrors: oracle.storageErrors,
    recoveredFromWindowName: !liveOracle && Boolean(persistedOracle),
    syncTraceFromWindowName,
    timeOrigin: performance.timeOrigin,
    probeElementText: document.querySelector('#history-observation')?.textContent ?? null,
    probeObservation: parsedObservation,
    };
  }, label);
  if (cdp) {
    result.devtoolsNavigationHistory = await cdp.send('Page.getNavigationHistory').catch(error => ({error: error.message}));
  }
  return result;
}

async function waitAfterStep(page, step, previousEventCount) {
  if (step.waitMode === 'document') {
    await page.waitForLoadState('domcontentloaded', {timeout: 10000}).catch(() => {});
    await page.waitForTimeout(100);
  } else if (step.waitMode === 'events' && step.minEvents > 0) {
    await page.waitForFunction(count => (window.__historyOracle?.events?.length ?? 0) >= count, previousEventCount + step.minEvents, {timeout: 5000}).catch(() => {});
    await page.waitForTimeout(50);
  } else {
    await page.waitForTimeout(150);
  }
}

async function executeCase(browser, spec) {
  const requestStart = requests.length;
  const context = await browser.newContext();
  const page = await context.newPage();
  const cdp = await context.newCDPSession(page);
  await cdp.send('Page.enable');
  const unexpectedPageRequests = [];
  const pageErrors = [];
  const consoleMessages = [];
  const navigationErrors = [];
  const navigationOutcomes = [];
  const pageRequests = [];
  const frameNavigations = [];
  page.on('framenavigated', frame => frameNavigations.push({url: frame.url(), isMainFrame: frame === page.mainFrame()}));
  context.on('request', request => {
    const item = {method: request.method(), url: request.url()};
    pageRequests.push(item);
    let parsed;
    try { parsed = new URL(request.url()); } catch (_) { unexpectedPageRequests.push(item); return; }
    const allowedProtocol = ['http:', 'blob:', 'about:'].includes(parsed.protocol);
    const allowedHost = ['127.0.0.1', 'localhost', '[::1]'].includes(parsed.hostname);
    if (!allowedProtocol || (parsed.protocol === 'http:' && !allowedHost)) unexpectedPageRequests.push(item);
  });
  page.on('pageerror', error => pageErrors.push(error.stack ?? error.message));
  page.on('console', message => consoleMessages.push({type: message.type(), text: message.text()}));
  const snapshots = [];
  try {
    const initialResponse = await page.goto(originFor('a') + '/source?case=' + encodeURIComponent(spec.caseId), {waitUntil: 'domcontentloaded', timeout: 10000});
    navigationOutcomes.push({step: 'open-source', status: initialResponse?.status() ?? null, url: initialResponse?.url() ?? null});
    const initial = await snapshot(page, 'initial-source', cdp);
    snapshots.push(initial);
    const initialHistoryLength = initial.historyLength;

    for (const [index, step] of spec.steps.entries()) {
      const previousEventCount = await page.evaluate(() => window.__historyOracle?.events?.length ?? 0).catch(() => 0);
      const beforeUrl = page.url();
      let navigationPromise = null;
      if (step.waitMode === 'document' || step.waitMode === 'blob') {
        navigationPromise = page.waitForNavigation({waitUntil: 'domcontentloaded', timeout: 10000}).then(response => ({response, error: null})).catch(error => ({response: null, error}));
      }
      try {
        if (step.action === 'tap-button') {
          await page.locator('button[data-history-action="' + step.id + '"]').click({timeout: 5000});
        } else if (step.action === 'tap-link') {
          if (step.id === 'open-blob') await page.locator('#open-blob-document').click({timeout: 5000});
          else await page.locator('a[data-history-link="' + step.id + '"]').click({timeout: 5000});
        }
      } catch (error) {
        navigationErrors.push({step: step.id, stage: 'click', error: error.stack ?? error.message});
      }
      if (navigationPromise) {
        const navResult = await navigationPromise;
        if (navResult.error && step.waitMode !== 'events') navigationErrors.push({step: step.id, stage: 'navigation', error: navResult.error.stack ?? navResult.error.message});
        navigationOutcomes.push({step: step.id, status: navResult.response?.status() ?? null, url: navResult.response?.url() ?? page.url()});
      }
      await waitAfterStep(page, step, previousEventCount);
      const after = await snapshot(page, 'step-' + String(index + 1).padStart(2, '0') + '-' + step.id, cdp).catch(error => {
        navigationErrors.push({step: step.id, stage: 'snapshot', error: error.stack ?? error.message});
        return null;
      });
      if (after) snapshots.push(after);
      if (beforeUrl !== page.url() && step.waitMode === 'settle') navigationOutcomes.push({step: step.id, status: null, url: page.url(), navigationDetectedByUrlChange: true});
    }

    const finalSnapshot = await snapshot(page, 'final', cdp).catch(error => {
      navigationErrors.push({step: 'final-snapshot', error: error.stack ?? error.message});
      return null;
    });
    const caseRequests = requests.slice(requestStart).filter(item => item.caseId === spec.caseId);
    const requestHops = caseRequests.filter(item => item.path.split('?')[0] !== '/favicon.ico');
    const interaction = {
      steps: spec.steps.map(({action, id, label, href, waitMode, minEvents}) => ({action, id, label, ...(href ? {href} : {}), waitMode, minEvents})),
      baseHref: spec.baseHref ?? null,
      noStore: true,
      initialHistoryLength,
    };
    return normalizeFixtureValue({
      caseId: spec.caseId,
      sourceUrl: originFor('a') + '/source?case=' + encodeURIComponent(spec.caseId),
      sourceHtml: sourceHtmlFor(spec).html,
      embeddedHtml: sourceHtmlFor(spec).embeddedHtml,
      interaction,
      initialHistoryLength,
      requestHops,
      pageRequests,
      navigationOutcomes,
      frameNavigations,
      snapshots,
      finalSnapshot,
      finalDocument: finalSnapshot ? {
        url: finalSnapshot.href,
        documentURL: finalSnapshot.documentURL,
        documentURI: finalSnapshot.documentURI,
        baseURI: finalSnapshot.baseURI,
        location: {
          origin: finalSnapshot.origin,
          protocol: finalSnapshot.protocol,
          host: finalSnapshot.host,
          pathname: finalSnapshot.pathname,
          search: finalSnapshot.search,
          hash: finalSnapshot.hash,
        },
        historyLength: finalSnapshot.historyLength,
        historyState: finalSnapshot.historyState,
        documentReferrer: finalSnapshot.documentReferrer,
        events: finalSnapshot.events,
        actions: finalSnapshot.actions,
        documentStarts: finalSnapshot.documentStarts,
      } : null,
      pageErrors,
      consoleMessages,
      navigationErrors,
      unexpectedPageRequests,
    });
  } finally {
    await context.close();
  }
}

const serverA = makeServer('a');
const serverB = makeServer('b');
const proxy = createServer((request, response) => {
  blockedProxyRequests.push({method: request.method ?? '', protocol: request.headers['x-forwarded-proto'] ?? ''});
  response.writeHead(403, {'content-type': 'text/plain', connection: 'close'});
  response.end('Loopback-only history oracle proxy; never forwards.');
});
proxy.on('connect', (request, socket) => {
  blockedProxyRequests.push({method: 'CONNECT', protocol: 'https:'});
  socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
});

let browser = null;
try {
  origins.a = await listen(serverA, '127.0.0.1');
  origins.b = await listen(serverB, 'localhost');
  const proxyOrigin = await listen(proxy, '127.0.0.1');
  browser = await chromium.launch({
    headless: true,
    executablePath: chromePath,
    proxy: {server: proxyOrigin, bypass: '127.0.0.1,localhost,[::1]'},
    args: ['--disable-background-networking', '--disable-component-update', '--disable-sync', '--no-first-run', '--no-default-browser-check'],
  });
  const results = [];
  for (const spec of selectedCases) results.push(await executeCase(browser, spec));
  for (const result of results) assert.deepEqual(result.unexpectedPageRequests, [], result.caseId + ' must remain on loopback/blob/about URLs.');
  const commandLine = chromeCommandLine();
  const normalizedRequests = normalizeFixtureValue(requests);
  const runnerBytes = await readFile(fileURLToPath(import.meta.url));
  const fixture = normalizeFixtureValue({
    browserVersion: browser.version(),
    browserExecutable: chromePath,
    runner: 'apps/android/tool/parity/verify_document_history_browser.mjs',
    runnerSha256: createHash('sha256').update(runnerBytes).digest('hex'),
    browserFlags: {
      disableBackForwardCacheFlagPresent: commandLine.includes('--disable-back-forward-cache'),
      commandLineCaptured: Boolean(commandLine),
    },
    origins: {
      a: fixtureOriginFor('a'),
      b: fixtureOriginFor('b'),
      relation: 'A is 127.0.0.1 and B is localhost; they are distinct origins and cross-site in Chrome.',
    },
    caseCount: results.length,
    cases: results,
    serverRequests: normalizedRequests,
    externalProxy: {
      origin: normalizeOrigins(proxyOrigin),
      forwardsRequests: false,
      blockedRequestCount: blockedProxyRequests.length,
      pageRequestsStayedOnLoopbackOrBlob: true,
    },
    scope: {
      initialHistoryLength: 'Every page is created as Playwright about:blank and navigated once with page.goto; initial history.length is recorded without deleting that first entry.',
      caching: 'All HTTP responses use Cache-Control: no-store. Playwright/Chromium automation default flags are recorded because BFCache may be disabled by automation.',
      tlsAndFrames: 'TLS, subframes, shadow DOM, and framework integration were not tested.',
      opaqueOrigins: 'The blob: history URL case is included; sandboxed/other opaque-origin frames were not tested.',
    },
  });
  const fixturePath = process.env.PIRC_FIXTURE_PATH ?? path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-history-chrome155.json');
  await writeFile(fixturePath, JSON.stringify(fixture, null, 2) + '\n');
  process.stdout.write(JSON.stringify({
    browserVersion: fixture.browserVersion,
    fixturePath,
    runnerSha256: fixture.runnerSha256,
    caseCount: fixture.caseCount,
    requestCount: fixture.serverRequests.length,
    navigationHopCount: fixture.cases.reduce((total, item) => total + item.requestHops.length, 0),
    blockedProxyRequestCount: fixture.externalProxy.blockedRequestCount,
    disableBackForwardCacheFlagPresent: fixture.browserFlags.disableBackForwardCacheFlagPresent,
    cases: fixture.cases.map(item => ({
      caseId: item.caseId,
      initialHistoryLength: item.initialHistoryLength,
      finalUrl: item.finalDocument?.url ?? null,
      finalHistoryLength: item.finalDocument?.historyLength ?? null,
      finalHistoryState: item.finalDocument?.historyState ?? null,
      requestHops: item.requestHops.map(hop => ({method: hop.method, path: hop.path, status: hop.responseStatus})),
      events: item.finalDocument?.events?.map(event => ({type: event.type, isTrusted: event.isTrusted, state: event.eventState, oldURL: event.oldURL, newURL: event.newURL})) ?? [],
      actionResults: item.finalDocument?.actions?.map(action => ({id: action.id, ok: action.outcome.ok, error: action.outcome.error ?? null})) ?? [],
      navigationErrors: item.navigationErrors,
    })),
  }, null, 2) + '\n');
} finally {
  if (browser) await browser.close();
  await Promise.all([closeServer(serverA), closeServer(serverB), closeServer(proxy)]);
}
