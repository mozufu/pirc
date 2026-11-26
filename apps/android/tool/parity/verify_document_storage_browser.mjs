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
assert.ok(await import('node:fs').then(fs => fs.existsSync(chromePath)));

const fixtureOrigins = {
  a: 'http://127.0.0.1:43100',
  b: 'http://localhost:43100',
};
let originA = '';
let originB = '';
const requests = [];
const pageRequests = [];
const blockedPageRequests = [];
const blockedProxyRequests = [];

function htmlDocument(title) {
  return '<!doctype html><html><head><meta charset="utf-8"><title>' +
    String(title).replaceAll('&', '&amp;').replaceAll('<', '&lt;') +
    '</title></head><body><h1>' + String(title).replaceAll('<', '&lt;') +
    '</h1><script>window.__storageOracleReady = true;</script></body></html>';
}

function makeLocalServer() {
  return createServer(async (request, response) => {
    const hostHeader = request.headers.host ?? '';
    const requestUrl = new URL(request.url ?? '/', 'http://' + hostHeader);
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const body = Buffer.concat(chunks);
    const caseId = requestUrl.searchParams.get('case');
    const event = {
      sequence: requests.length + 1,
      caseId,
      method: request.method ?? '',
      host: requestUrl.hostname,
      path: requestUrl.pathname + requestUrl.search,
      requestUrl: requestUrl.href,
      origin: request.headers.origin ?? null,
      referer: request.headers.referer ?? null,
      authorizationPresent: Boolean(request.headers.authorization),
      cookiePresent: Boolean(request.headers.cookie),
      secFetchSite: request.headers['sec-fetch-site'] ?? null,
      contentType: request.headers['content-type'] ?? null,
      bodyBytes: body.length,
      bodySha256: body.length ? createHash('sha256').update(body).digest('hex') : null,
      responseStatus: null,
    };
    requests.push(event);
    const headers = {
      'cache-control': 'no-store',
      'content-type': 'text/html; charset=utf-8',
      'x-content-type-options': 'nosniff',
    };

    if (request.method === 'GET' && requestUrl.pathname === '/page') {
      event.responseStatus = 200;
      response.writeHead(200, headers);
      response.end(htmlDocument('Chrome storage oracle: ' + (caseId ?? 'page')));
      return;
    }
    if (request.method === 'GET' && requestUrl.pathname === '/echo') {
      event.responseStatus = 200;
      response.writeHead(200, {
        ...headers,
        'content-type': 'application/json; charset=utf-8',
      });
      response.end(JSON.stringify({request: {
        sequence: event.sequence,
        caseId: event.caseId,
        method: event.method,
        host: event.host,
        path: event.path,
        origin: event.origin,
        referer: event.referer,
        authorizationPresent: event.authorizationPresent,
        cookiePresent: event.cookiePresent,
        secFetchSite: event.secFetchSite,
      }}));
      return;
    }
    if (request.method === 'GET' && requestUrl.pathname === '/favicon.ico') {
      event.responseStatus = 204;
      response.writeHead(204, {'cache-control': 'no-store'});
      response.end();
      return;
    }
    event.responseStatus = 404;
    response.writeHead(404, {'cache-control': 'no-store', 'content-type': 'text/plain'});
    response.end('Unexpected local storage-oracle request');
  });
}

async function listen(server, host, port = 0) {
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, () => {
      server.off('error', reject);
      resolve();
    });
  });
  const address = server.address();
  assert.ok(address && typeof address === 'object');
  return address.port;
}

async function closeServer(server) {
  if (server?.listening) await new Promise(resolve => server.close(resolve));
}

function launchedChromeCommandLine() {
  const lines = execFileSync('ps', ['-axo', 'pid=,command='], {encoding: 'utf8'}).split('\n');
  const matches = lines.filter(line =>
    line.includes(chromePath) && line.includes('--user-data-dir=') && !line.includes('--type='),
  );
  return matches.at(-1)?.trim() ?? '';
}

function normalizeText(value, actualPort, proxyPort) {
  return String(value)
    .replace(/(blob:https?:\/\/(?:127\.0\.0\.1|localhost):\d+)\/[0-9a-f-]{36}/gi, '$1/<object-url>')
    .replaceAll('http://127.0.0.1:' + actualPort, fixtureOrigins.a)
    .replaceAll('http://localhost:' + actualPort, fixtureOrigins.b)
    .replaceAll('http://127.0.0.1:' + proxyPort, 'http://127.0.0.1:43199');
}


function isSyntheticPageUrl(rawUrl) {
  const url = new URL(rawUrl);
  if (url.protocol === 'data:') return true;
  if (url.protocol === 'http:') return url.hostname === '127.0.0.1' || url.hostname === 'localhost';
  if (url.protocol === 'blob:' && url.origin !== 'null') {
    const embeddedOrigin = new URL(url.origin);
    return embeddedOrigin.protocol === 'http:' &&
      (embeddedOrigin.hostname === '127.0.0.1' || embeddedOrigin.hostname === 'localhost');
  }
  return false;
}

function normalize(value, actualPort, proxyPort) {
  if (typeof value === 'string') return normalizeText(value, actualPort, proxyPort);
  if (Array.isArray(value)) return value.map(item => normalize(item, actualPort, proxyPort));
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, normalize(item, actualPort, proxyPort)]));
  }
  return value;
}

function sha256Repeated(codePoint, repetitions) {
  const hash = createHash('sha256');
  const chunkCount = Math.min(repetitions, 32768);
  const chunk = codePoint.repeat(chunkCount);
  const chunkBytes = Buffer.from(chunk, 'utf8');
  let remaining = repetitions;
  while (remaining >= chunkCount) {
    hash.update(chunkBytes);
    remaining -= chunkCount;
  }
  if (remaining) hash.update(Buffer.from(codePoint.repeat(remaining), 'utf8'));
  return hash.digest('hex');
}

async function sleep(milliseconds) {
  await new Promise(resolve => setTimeout(resolve, milliseconds));
}

async function collectQuotaBoundary(page) {
  return page.evaluate(async () => {
    const quotaLimit = 5 * 1024 * 1024 + 64 * 1024;
    const key = '__storage_oracle_quota_probe__';
    const characters = [
      {id: 'ascii', value: 'a', codePoint: 'U+0061'},
      {id: 'bmp-non-ascii', value: '\u00e9', codePoint: 'U+00E9'},
      {id: 'supplementary', value: '\ud83d\ude00', codePoint: 'U+1F600'},
    ];
    const attempt = (character, codeUnits) => {
      const store = localStorage;
      store.clear();
      const repetitions = codeUnits / character.value.length;
      if (!Number.isInteger(repetitions)) {
        return {accepted: false, errorName: 'UnrepresentableCodeUnitCount'};
      }
      const value = character.value.repeat(repetitions);
      try {
        store.setItem(key, value);
        return {accepted: true, valueLength: value.length};
      } catch (error) {
        return {accepted: false, errorName: error?.name ?? 'Error', valueLength: value.length};
      }
    };

    const results = [];
    for (const character of characters) {
      let low = 0;
      let high = character.value.length === 1 ? quotaLimit : Math.ceil(quotaLimit / 2) * 2;
      const highResult = attempt(character, high);
      if (highResult.accepted) {
        results.push({
          id: character.id,
          codePoint: character.codePoint,
          quotaSearchBoundCodeUnits: high,
          acceptedAtBound: true,
          maxAcceptedValueUtf16CodeUnitsWithinBound: high,
          firstRejectedValueUtf16CodeUnits: null,
          acceptedErrorName: null,
          rejectedErrorName: null,
        });
        continue;
      }
      if (highResult.errorName !== 'QuotaExceededError') {
        throw new Error(character.id + ' upper-bound storage write failed: ' + highResult.errorName);
      }
      while (high - low > character.value.length) {
        let middle = Math.floor((low + high) / (2 * character.value.length)) * character.value.length;
        if (middle <= low) middle = low + character.value.length;
        const result = attempt(character, middle);
        if (result.accepted) low = middle;
        else {
          if (result.errorName !== 'QuotaExceededError') {
            throw new Error(character.id + ' quota search failed: ' + result.errorName);
          }
          high = middle;
        }
      }
      const accepted = attempt(character, low);
      const rejected = attempt(character, high);
      if (!accepted.accepted || rejected.accepted || rejected.errorName !== 'QuotaExceededError') {
        throw new Error(character.id + ' quota boundary did not converge to accepted/QuotaExceededError neighbors');
      }
      const utf8BytesPerCodePoint = new TextEncoder().encode(character.value).length;
      const repetitions = low / character.value.length;
      results.push({
        id: character.id,
        codePoint: character.codePoint,
        quotaSearchBoundCodeUnits: quotaLimit,
        acceptedAtBound: false,
        maxAcceptedValueUtf16CodeUnits: low,
        firstRejectedValueUtf16CodeUnits: high,
        maxAcceptedValueUtf16Bytes: low * 2,
        firstRejectedValueUtf16Bytes: high * 2,
        maxAcceptedValueUtf8Bytes: repetitions * utf8BytesPerCodePoint,
        firstRejectedValueUtf8Bytes: (high / character.value.length) * utf8BytesPerCodePoint,
        maxAcceptedValueSha256Utf8: await crypto.subtle.digest(
          'SHA-256', new TextEncoder().encode(character.value.repeat(repetitions)),
        ).then(bytes => Array.from(new Uint8Array(bytes), byte => byte.toString(16).padStart(2, '0')).join('')),
        acceptedErrorName: null,
        rejectedErrorName: rejected.errorName,
      });
    }
    localStorage.clear();
    return {
      quotaSearchBoundUtf16CodeUnits: quotaLimit,
      maximumSingleValueOnly: true,
      includesKeyAndStorageOverhead: true,
      result: results,
    };
  });
}

const localServer = makeLocalServer();
const nonForwardingProxy = createServer((request, response) => {
  blockedProxyRequests.push({method: request.method ?? '', host: request.headers.host ?? null});
  response.writeHead(403, {'content-type': 'text/plain', connection: 'close'});
  response.end('This loopback-only Chrome storage-oracle proxy never forwards.');
});
nonForwardingProxy.on('connect', (request, socket) => {
  blockedProxyRequests.push({method: 'CONNECT', host: request.url ?? null});
  socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
});

let browser = null;
let context = null;
const ownedPages = new Set();
try {
  const actualPort = await listen(localServer, '127.0.0.1');
  originA = 'http://127.0.0.1:' + actualPort;
  originB = 'http://localhost:' + actualPort;
  const proxyPort = await listen(nonForwardingProxy, '127.0.0.1');
  browser = await chromium.launch({
    headless: true,
    executablePath: chromePath,
    proxy: {
      server: 'http://127.0.0.1:' + proxyPort,
      bypass: 'localhost,127.0.0.1,[::1]',
    },
    args: [
      '--disable-gpu',
      '--disable-background-networking',
      '--disable-component-update',
      '--disable-sync',
      '--no-first-run',
      '--no-default-browser-check',
      '--host-resolver-rules=MAP localhost 127.0.0.1',
    ],
  });
  assert.match(browser.version(), /^155\./, 'Fixture name is pinned to Chrome 155');

  context = await browser.newContext();
  context.on('request', request => {
    pageRequests.push({url: request.url(), method: request.method()});
  });
  await context.route('**/*', async route => {
    const url = new URL(route.request().url());
    const allowed = isSyntheticPageUrl(url.href);
    if (allowed) {
      await route.continue();
      return;
    }
    blockedPageRequests.push({method: route.request().method(), protocol: url.protocol, host: url.host});
    await route.abort();
  });

  const page = await context.newPage();
  ownedPages.add(page);
  await page.goto(originA + '/page?case=storage-origin-a', {waitUntil: 'load'});
  const initial = await page.evaluate(() => {
    localStorage.clear();
    sessionStorage.clear();
    return {
      href: location.href,
      origin: location.origin,
      localStorageLength: localStorage.length,
      sessionStorageLength: sessionStorage.length,
      storageTypes: {
        localStorage: Object.prototype.toString.call(localStorage),
        sessionStorage: Object.prototype.toString.call(sessionStorage),
      },
    };
  });
  assert.equal(initial.localStorageLength, 0);
  assert.equal(initial.sessionStorageLength, 0);

  const domStringAndOrdering = await page.evaluate(() => {
    const store = localStorage;
    store.clear();
    store.setItem(17, null);
    store.setItem(true, ['x', 'y']);
    store.setItem({toString() { return 'object-key'; }}, {toString() { return 'object-value'; }});
    const coercions = {
      numericKey: store.getItem('17'),
      nullValue: store.getItem('17'),
      booleanKey: store.getItem('true'),
      arrayValue: store.getItem('true'),
      objectKeyValue: store.getItem('object-key'),
      length: store.length,
      orderedEntries: Array.from({length: store.length}, (_, index) => [store.key(index), store.getItem(store.key(index))]),
    };

    store.clear();
    store.setItem('alpha', 'one');
    store.setItem('beta', 'two');
    store.setItem('gamma', 'three');
    const afterInsert = {
      keys: Object.keys(store),
      keyOrder: Array.from({length: store.length}, (_, i) => store.key(i)),
      negativeIndex: store.key(-1),
      indexAtLength: store.key(store.length),
    };
    store.setItem('beta', 'two-updated');
    const afterOverwrite = {keys: Object.keys(store), keyOrder: Array.from({length: store.length}, (_, i) => store.key(i))};
    store.removeItem('alpha');
    store.setItem('alpha', 'reinserted');
    const afterReinsert = {
      keys: Object.keys(store),
      keyOrder: Array.from({length: store.length}, (_, i) => store.key(i)),
      negativeIndex: store.key(-1),
      indexAtLength: store.key(store.length),
      values: Array.from({length: store.length}, (_, i) => [store.key(i), store.getItem(store.key(i))]),
    };

    store.clear();
    store.setItem('getItem', 'stored-getItem');
    store.setItem('setItem', 'stored-setItem');
    store.setItem('constructor', 'stored-constructor');
    store.setItem('length', 'stored-length');
    store.setItem('__proto__', 'stored-proto');
    store.setItem('toString', 'stored-toString');
    store.setItem('', 'stored-empty');
    store.namedProperty = 'assigned-value';
    const describe = name => {
      const value = store[name];
      return {
        type: typeof value,
        stringValue: typeof value === 'string' ? value : null,
        functionName: typeof value === 'function' ? (value.name || null) : null,
        equalsStoragePrototype: value === Object.getPrototypeOf(store),
      };
    };
    const nativeGetItem = Storage.prototype.getItem;
    const nativeSetItem = Storage.prototype.setItem;
    const reservedNames = ['getItem', 'setItem', 'constructor', 'length', '__proto__', 'toString', ''];
    const reservedStorageOnly = {
      storedValues: [...reservedNames, 'namedProperty'].map(name => [name, nativeGetItem.call(store, name)]),
      directProperties: [...reservedNames, 'namedProperty'].map(name => [name, describe(name)]),
      objectKeys: Object.keys(store),
      ownPropertyNames: Object.getOwnPropertyNames(store),
      ownPropertyDescriptors: [...reservedNames, 'namedProperty'].map(name => {
        const descriptor = Object.getOwnPropertyDescriptor(store, name);
        return {
          name,
          present: descriptor != null,
          enumerable: descriptor?.enumerable ?? null,
          configurable: descriptor?.configurable ?? null,
          writable: descriptor && Object.hasOwn(descriptor, 'writable') ? descriptor.writable : null,
          valueType: descriptor ? typeof descriptor.value : null,
        };
      }),
    };
    const propertyAssignments = reservedNames.map(name => {
      try {
        return {name, accepted: Reflect.set(store, name, 'assigned-' + (name || 'empty')), errorName: null};
      } catch (error) {
        return {name, accepted: false, errorName: error?.name ?? 'Error'};
      }
    });
    const propertyDescriptors = reservedNames.map(name => {
      const descriptor = Object.getOwnPropertyDescriptor(store, name);
      return {
        name,
        present: descriptor != null,
        enumerable: descriptor?.enumerable ?? null,
        configurable: descriptor?.configurable ?? null,
        writable: descriptor && Object.hasOwn(descriptor, 'writable') ? descriptor.writable : null,
        descriptorValueType: descriptor ? typeof descriptor.value : null,
      };
    });
    const reservedBeforeDelete = {
      storedValues: ['getItem', 'setItem', 'constructor', 'length', '__proto__', 'toString', '', 'namedProperty']
        .map(name => [name, nativeGetItem.call(store, name)]),
      directProperties: ['getItem', 'setItem', 'constructor', 'length', '__proto__', 'toString', '', 'namedProperty']
        .map(name => [name, describe(name)]),
      propertyAssignments,
      propertyDescriptors,
      getItemType: typeof store.getItem,
      lengthProperty: store.length,
      storagePrototypeUnchanged: Object.getPrototypeOf(store) === Storage.prototype,
      objectKeys: Object.keys(store),
      ownPropertyNames: Object.getOwnPropertyNames(store),
    };
    const propertyDeletes = reservedNames.map(name => {
      let accepted;
      let errorName = null;
      try {
        accepted = Reflect.deleteProperty(store, name);
      } catch (error) {
        accepted = false;
        errorName = error?.name ?? 'Error';
      }
      return {
        name,
        accepted,
        errorName,
        storedValueAfterDelete: nativeGetItem.call(store, name),
        directPropertyAfterDelete: describe(name),
      };
    });
    const afterReservedDeletes = {
      propertyDeletes,
      storagePrototypeUnchanged: Object.getPrototypeOf(store) === Storage.prototype,
      length: store.length,
      objectKeys: Object.keys(store),
    };
    const deleteNamedProperty = Reflect.deleteProperty(store, 'namedProperty');
    const afterDeleteNamedProperty = {
      deleteResult: deleteNamedProperty,
      storedValue: nativeGetItem.call(store, 'namedProperty'),
      directValue: store.namedProperty ?? null,
      length: store.length,
    };
    const beforeNoopLength = store.length;
    nativeSetItem.call(store, 'getItem', 'stored-getItem');
    nativeSetItem.call(store, 'length', 'stored-length');
    nativeSetItem.call(store, '__proto__', 'stored-proto');
    const noOpSetSameValuesPreservedLength = store.length === beforeNoopLength;
    store.clear();
    return {
      coercions,
      order: {afterInsert, afterOverwrite, afterReinsert},
      reservedStorageOnly,
      reserved: reservedBeforeDelete,
      afterReservedDeletes,
      afterDeleteNamedProperty,
      noOpSetSameValuesPreservedLength,
    };
  });
  assert.equal(domStringAndOrdering.coercions.numericKey, 'null');
  assert.equal(domStringAndOrdering.coercions.objectKeyValue, 'object-value');
  assert.equal(domStringAndOrdering.order.afterInsert.keyOrder.length, 3);
  assert.equal(domStringAndOrdering.order.afterOverwrite.keyOrder.length, 3);
  assert.equal(domStringAndOrdering.order.afterReinsert.keyOrder.length, 3);
  const orderCase = {
    caseId: 'domstring-properties-and-ordering',
    source: 'Actual Storage.setItem DOMString conversions, key()/Object.keys enumeration order, overwrite position, remove-and-reinsert order, and property get/set/delete collisions for getItem, setItem, constructor, length, __proto__, toString, and the empty name.',
    result: domStringAndOrdering,
  };

  const quota = await collectQuotaBoundary(page);
  const quotaCase = {
    caseId: 'localstorage-quota-utf16',
    source: 'One localStorage value at a time is binary-searched up to 5 * 1024 * 1024 + 64 * 1024 UTF-16 code units. Each probe clears the origin first, records only lengths/hashes/error names, and compares ASCII, non-ASCII BMP, and supplementary code points.',
    result: quota,
  };

  const persistence = await page.evaluate(() => {
    localStorage.clear();
    sessionStorage.clear();
    localStorage.setItem('reload-local', 'survives-reload');
    sessionStorage.setItem('reload-session', 'survives-reload');
    return {
      beforeReloadLocal: localStorage.getItem('reload-local'),
      beforeReloadSession: sessionStorage.getItem('reload-session'),
    };
  });
  await page.reload({waitUntil: 'load'});
  const afterReload = await page.evaluate(() => ({
    href: location.href,
    local: localStorage.getItem('reload-local'),
    session: sessionStorage.getItem('reload-session'),
  }));
  assert.equal(afterReload.local, 'survives-reload');
  assert.equal(afterReload.session, 'survives-reload');
  const persistenceCase = {
    caseId: 'reload-persistence',
    source: 'A same-tab reload reads back the real localStorage and sessionStorage entries written before navigation reload.',
    beforeReload: persistence,
    afterReload,
  };

  const pageB = await context.newPage();
  ownedPages.add(pageB);
  await pageB.goto(originB + '/page?case=storage-origin-b', {waitUntil: 'load'});
  const originBBefore = await pageB.evaluate(() => ({
    href: location.href,
    origin: location.origin,
    local: localStorage.getItem('cross-origin-key'),
    session: sessionStorage.getItem('cross-origin-session'),
  }));
  await page.evaluate(() => {
    localStorage.setItem('cross-origin-key', 'from-origin-a');
    sessionStorage.setItem('cross-origin-session', 'from-origin-a');
  });
  await pageB.evaluate(() => {
    localStorage.setItem('cross-origin-key', 'from-origin-b');
    sessionStorage.setItem('cross-origin-session', 'from-origin-b');
  });
  const originIsolation = {
    originA: await page.evaluate(() => ({origin: location.origin,
      local: localStorage.getItem('cross-origin-key'),
      session: sessionStorage.getItem('cross-origin-session')})),
    originBBeforeWrite: originBBefore,
    originBAfterWrite: await pageB.evaluate(() => ({origin: location.origin,
      local: localStorage.getItem('cross-origin-key'),
      session: sessionStorage.getItem('cross-origin-session')})),
    relation: '127.0.0.1 and localhost use the same port but are distinct origins and distinct sites in this Chrome run.',
  };
  assert.equal(originBBefore.local, null);
  assert.equal(originBBefore.session, null);
  assert.equal(originIsolation.originA.local, 'from-origin-a');
  assert.equal(originIsolation.originBAfterWrite.local, 'from-origin-b');
  const originCase = {
    caseId: 'cross-origin-storage-separation',
    source: 'Two actual loopback hostnames on the same port independently read and write localStorage and sessionStorage.',
    result: originIsolation,
  };

  await page.evaluate(() => {
    sessionStorage.clear();
    sessionStorage.setItem('opener-copy', 'original-at-open');
    sessionStorage.setItem('opener-only', 'parent-before-open');
  });
  const openerUrl = originA + '/page?case=session-opener-copy';
  const openerPagePromise = context.waitForEvent('page', {timeout: 5000});
  const openerReturnWasNull = await page.evaluate(url => window.open(url, '_blank') === null, openerUrl);
  const openerPopup = await openerPagePromise;
  ownedPages.add(openerPopup);
  await openerPopup.waitForLoadState('load');
  const openerInitial = await openerPopup.evaluate(() => ({
    href: location.href,
    openerIsNull: window.opener === null,
    entries: Array.from({length: sessionStorage.length}, (_, i) => [sessionStorage.key(i), sessionStorage.getItem(sessionStorage.key(i))]),
  }));
  await openerPopup.evaluate(() => {
    sessionStorage.setItem('opener-copy', 'child-after-open');
    sessionStorage.setItem('child-only', 'child-value');
  });
  await page.evaluate(() => sessionStorage.setItem('parent-after-open', 'parent-value'));
  const openerDivergence = {
    openerReturnWasNull,
    initial: openerInitial,
    parentAfterChildWrite: await page.evaluate(() => ({
      copy: sessionStorage.getItem('opener-copy'),
      childOnly: sessionStorage.getItem('child-only'),
      parentAfterOpen: sessionStorage.getItem('parent-after-open'),
    })),
    childAfterParentWrite: await openerPopup.evaluate(() => ({
      copy: sessionStorage.getItem('opener-copy'),
      childOnly: sessionStorage.getItem('child-only'),
      parentAfterOpen: sessionStorage.getItem('parent-after-open'),
    })),
  };
  assert.equal(openerInitial.openerIsNull, false);
  assert.equal(openerInitial.entries.find(([key]) => key === 'opener-copy')?.[1], 'original-at-open');
  assert.equal(openerDivergence.parentAfterChildWrite.copy, 'original-at-open');
  assert.equal(openerDivergence.parentAfterChildWrite.childOnly, null);
  assert.equal(openerDivergence.childAfterParentWrite.parentAfterOpen, null);

  const noOpenerUrl = originA + '/page?case=session-noopener';
  const noOpenerPagePromise = context.waitForEvent('page', {timeout: 5000});
  const noOpenerReturnWasNull = await page.evaluate(url => window.open(url, '_blank', 'noopener') === null, noOpenerUrl);
  const noOpenerPopup = await noOpenerPagePromise;
  ownedPages.add(noOpenerPopup);
  await noOpenerPopup.waitForLoadState('load');
  const noOpenerResult = await noOpenerPopup.evaluate(() => ({
    href: location.href,
    openerIsNull: window.opener === null,
    length: sessionStorage.length,
    openerCopy: sessionStorage.getItem('opener-copy'),
    openerOnly: sessionStorage.getItem('opener-only'),
  }));
  assert.equal(noOpenerResult.openerIsNull, true);
  assert.equal(noOpenerResult.openerCopy, null);
  assert.equal(noOpenerResult.openerOnly, null);
  const sessionCase = {
    caseId: 'session-per-window-and-opener-copy',
    source: 'A same-origin window.open child without noopener starts with a snapshot copy of opener sessionStorage and then diverges. A noopener child has null opener and an empty sessionStorage.',
    openerCopy: openerDivergence,
    noopener: {windowOpenReturnedNull: noOpenerReturnWasNull, result: noOpenerResult},
  };

  const peer = await context.newPage();
  ownedPages.add(peer);
  await page.goto(originA + '/page?case=storage-events-source', {waitUntil: 'load'});
  await peer.goto(originA + '/page?case=storage-events-peer', {waitUntil: 'load'});
  await page.evaluate(() => localStorage.clear());
  const listenerSourceUrl = await page.evaluate(() => location.href);
  await Promise.all([page, peer, pageB].map(target => target.evaluate(() => {
    window.__storageEvents = [];
    window.addEventListener('storage', event => window.__storageEvents.push({
      key: event.key,
      oldValue: event.oldValue,
      newValue: event.newValue,
      url: event.url,
      storageAreaIsLocalStorage: event.storageArea === localStorage,
    }));
  })));
  const eventObservations = [];
  let previousSourceEvents = 0;
  let previousPeerEvents = 0;
  let previousCrossOriginEvents = 0;
  const recordEventState = async (label, expectedPeerCount) => {
    if (expectedPeerCount != null) {
      await peer.waitForFunction(count => window.__storageEvents.length >= count, expectedPeerCount, {timeout: 2000});
    }
    await sleep(40);
    const sourceAll = await page.evaluate(() => window.__storageEvents.slice());
    const peerAll = await peer.evaluate(() => window.__storageEvents.slice());
    const crossOriginAll = await pageB.evaluate(() => window.__storageEvents.slice());
    eventObservations.push({
      label,
      sourceEventCount: sourceAll.length,
      sourceEvents: sourceAll.slice(previousSourceEvents),
      sameOriginPeerEventCount: peerAll.length,
      sameOriginPeerEvents: peerAll.slice(previousPeerEvents),
      crossOriginEventCount: crossOriginAll.length,
      crossOriginEvents: crossOriginAll.slice(previousCrossOriginEvents),
      expectedPeerCount,
    });
    previousSourceEvents = sourceAll.length;
    previousPeerEvents = peerAll.length;
    previousCrossOriginEvents = crossOriginAll.length;
  };
  await page.evaluate(() => localStorage.setItem('event-key', 'one'));
  await recordEventState('set-new-key', 1);
  await page.evaluate(() => localStorage.setItem('event-key', 'one'));
  await recordEventState('set-same-value-noop', 1);
  await page.evaluate(() => localStorage.removeItem('absent-key'));
  await recordEventState('remove-missing-key-noop', 1);
  await page.evaluate(() => localStorage.setItem('event-key', 'two'));
  await recordEventState('overwrite-existing-key', 2);
  await page.evaluate(() => localStorage.removeItem('event-key'));
  await recordEventState('remove-existing-key', 3);
  await page.evaluate(() => {
    localStorage.setItem('clear-a', 'a');
    localStorage.setItem('clear-b', 'b');
  });
  await recordEventState('seed-before-clear', 5);
  await page.evaluate(() => localStorage.clear());
  await recordEventState('clear-nonempty-storage', 6);
  await page.evaluate(() => localStorage.clear());
  await recordEventState('clear-empty-storage-noop', 6);
  await page.evaluate(() => history.pushState({storageOracle: true}, '', '/events/after-pushstate?case=storage-event-url'));
  const pushStateSourceUrl = await page.evaluate(() => location.href);
  await page.evaluate(() => localStorage.setItem('after-pushstate', 'written'));
  await recordEventState('mutation-after-pushstate', 7);
  assert.equal(eventObservations[0].sourceEvents.length, 0, 'The source window must not receive its own storage event');
  assert.equal(eventObservations[1].sameOriginPeerEvents.length, 0, 'Setting the same value must not dispatch a storage event');
  assert.equal(eventObservations[2].sameOriginPeerEvents.length, 0, 'Removing a missing key must not dispatch a storage event');
  assert.deepEqual(eventObservations[0].sameOriginPeerEvents[0], {
    key: 'event-key', oldValue: null, newValue: 'one',
    url: listenerSourceUrl, storageAreaIsLocalStorage: true,
  });
  assert.deepEqual(eventObservations[6].sameOriginPeerEvents[0], {
    key: null, oldValue: null, newValue: null,
    url: listenerSourceUrl, storageAreaIsLocalStorage: true,
  });
  assert.equal(eventObservations[8].sameOriginPeerEvents[0].url, pushStateSourceUrl);
  assert.ok(eventObservations.every(item => item.sourceEventCount === 0));
  assert.ok(eventObservations.every(item => item.crossOriginEventCount === 0));
  const eventsCase = {
    caseId: 'storage-events-and-pushstate-url',
    source: 'Actual localStorage storage events in a second same-origin top-level window record key/oldValue/newValue/url/storageArea; source and cross-origin windows receive none. Same-value set, missing remove, and clear-on-empty are no-ops. A mutation after pushState reports the updated source URL.',
    listenerSourceUrl,
    pushStateSourceUrl,
    observations: eventObservations,
  };

  const peerEventCountBeforeBlobSeed = await peer.evaluate(() => window.__storageEvents.length);
  const blobUrl = await page.evaluate(() => {
    localStorage.setItem('blob-local-seed', 'created-from-http-origin');
    sessionStorage.setItem('blob-session-seed', 'created-from-http-origin');
    const source = `<!doctype html><html><head><meta charset="utf-8"><title>blob Storage probe</title></head><body><script>
      (() => {
        const result = {href: location.href, origin: location.origin, localBefore: null, sessionBefore: null};
        try {
          result.localBefore = localStorage.getItem('blob-local-seed');
          result.sessionBefore = sessionStorage.getItem('blob-session-seed');
          localStorage.setItem('blob-local-seed', 'written-from-blob');
          sessionStorage.setItem('blob-session-seed', 'written-from-blob');
          result.localAfter = localStorage.getItem('blob-local-seed');
          result.sessionAfter = sessionStorage.getItem('blob-session-seed');
          result.error = null;
        } catch (error) {
          result.error = {name: error?.name ?? 'Error', message: error?.message ?? String(error)};
        }
        result.complete = true;
        window.__storageBlobProbe = result;
      })();
    </script></body></html>`;
    return URL.createObjectURL(new Blob([source], {type: 'text/html'}));
  });
  await peer.waitForFunction(count => window.__storageEvents.length >= count, peerEventCountBeforeBlobSeed + 1, {timeout: 2000});
  const creatorSeedStorageEvents = await peer.evaluate(count => window.__storageEvents.slice(count), peerEventCountBeforeBlobSeed);
  const peerEventCountBeforeBlob = await peer.evaluate(() => window.__storageEvents.length);
  await page.goto(blobUrl, {waitUntil: 'load'});
  await page.waitForFunction(() => window.__storageBlobProbe?.complete === true, null, {timeout: 3000});
  const blobResult = await page.evaluate(() => window.__storageBlobProbe);
  await peer.waitForFunction(count => window.__storageEvents.length >= count, peerEventCountBeforeBlob + 1, {timeout: 2000});
  const blobPeerEvents = await peer.evaluate(count => window.__storageEvents.slice(count), peerEventCountBeforeBlob);
  assert.equal(blobResult.origin, originA);
  assert.equal(blobResult.localBefore, 'created-from-http-origin');
  assert.equal(blobResult.sessionBefore, 'created-from-http-origin');
  assert.equal(blobResult.localAfter, 'written-from-blob');
  assert.equal(blobResult.sessionAfter, 'written-from-blob');
  assert.equal(blobResult.error, null);
  assert.equal(blobPeerEvents.length, 1);
  assert.deepEqual(blobPeerEvents[0], {
    key: 'blob-local-seed',
    oldValue: 'created-from-http-origin',
    newValue: 'written-from-blob',
    url: blobResult.href,
    storageAreaIsLocalStorage: true,
  });
  const blobCase = {
    caseId: 'blob-document-inherited-origin',
    source: 'A Blob HTML document created by an HTTP 127.0.0.1 document reads and writes that creator origin localStorage and sessionStorage. A second same-origin HTTP window receives the actual localStorage event; event.url is compared to the Blob document URL.',
    result: blobResult,
    creatorSeedStorageEvents,
    sameOriginPeerStorageEvents: blobPeerEvents,
  };

  const opaquePage = await context.newPage();
  ownedPages.add(opaquePage);
  await opaquePage.goto('data:text/html,<title>opaque storage probe</title><body>synthetic opaque origin</body>', {waitUntil: 'load'});
  const opaqueResult = await opaquePage.evaluate(() => {
    const inspect = property => {
      try {
        const storage = window[property];
        return {status: 'available', length: storage.length};
      } catch (error) {
        return {status: 'throws', name: error?.name ?? 'Error', message: error?.message ?? String(error)};
      }
    };
    return {origin: location.origin, localStorage: inspect('localStorage'), sessionStorage: inspect('sessionStorage')};
  });
  assert.equal(opaqueResult.origin, 'null');
  assert.equal(opaqueResult.localStorage.name, 'SecurityError');
  assert.equal(opaqueResult.sessionStorage.name, 'SecurityError');
  const opaqueCase = {
    caseId: 'opaque-origin-security-error',
    source: 'An inline data: document attempts to access both Storage getters and records the actual exception names; no external resource is loaded.',
    result: opaqueResult,
  };

  const commandLine = launchedChromeCommandLine();
  const normalizedCommandLine = commandLine
    .replace(/--user-data-dir=\S+/, '--user-data-dir=<temporary-profile>')
    .replace(/--remote-debugging-pipe/, '--remote-debugging-pipe');
  const runnerBytes = await readFile(fileURLToPath(import.meta.url));
  const normalizedRequests = normalize(requests, actualPort, proxyPort);
  const unexpectedPageRequests = pageRequests.filter(item => {
    return !isSyntheticPageUrl(item.url);
  });
  assert.equal(unexpectedPageRequests.length, 0, 'No page request may leave the synthetic loopback origins');
  assert.equal(blockedPageRequests.length, 0, 'No page request may use a non-loopback origin');
  assert.ok(requests.length > 0);
  assert.ok(requests.every(item => item.authorizationPresent === false));
  assert.ok(requests.every(item => item.host === '127.0.0.1' || item.host === 'localhost'));

  const fixture = {
    browserVersion: browser.version(),
    browserExecutable: chromePath,
    runner: 'apps/android/tool/parity/verify_document_storage_browser.mjs',
    runnerSha256: createHash('sha256').update(runnerBytes).digest('hex'),
    browserFlags: {
      hostResolverRules: 'MAP localhost 127.0.0.1',
      backgroundNetworkingDisabled: true,
      externalProxyConfigured: true,
      externalProxyForwards: false,
      pageRequestsRestrictedToSyntheticLoopback: true,
      observedChromeCommandLine: normalizedCommandLine || null,
      commandLineCaptured: Boolean(commandLine),
    },
    origins: {
      a: fixtureOrigins.a,
      b: fixtureOrigins.b,
      relation: 'Same ephemeral port, distinct hosts and origins: 127.0.0.1 and localhost. Chrome resolves localhost to 127.0.0.1. Site/origin separation is based on the actual browser URLs and captured requests.',
    },
    caseCount: 8,
    caseSources: [
      {caseId: 'domstring-properties-and-ordering', source: orderCase.source},
      {caseId: 'localstorage-quota-utf16', source: quotaCase.source},
      {caseId: 'reload-persistence', source: persistenceCase.source},
      {caseId: 'cross-origin-storage-separation', source: originCase.source},
      {caseId: 'session-per-window-and-opener-copy', source: sessionCase.source},
      {caseId: 'storage-events-and-pushstate-url', source: eventsCase.source},
      {caseId: 'blob-document-inherited-origin', source: blobCase.source},
      {caseId: 'opaque-origin-security-error', source: opaqueCase.source},
      {caseId: 'local-server-request-receipts', source: 'All served document requests are captured from the Node loopback server with actual method, host, path, Origin, Referer, authorization presence, cookie presence, Sec-Fetch-Site, body length/hash, and response status.'},
    ],
    cases: [orderCase, quotaCase, persistenceCase, originCase, sessionCase, eventsCase, blobCase, opaqueCase],
    serverRequests: normalizedRequests,
    pageRequests: normalize(pageRequests, actualPort, proxyPort),
    externalProxy: {
      origin: 'http://127.0.0.1:43199',
      forwardsRequests: false,
      blockedRequestCount: blockedProxyRequests.length,
      blockedCountsByMethod: blockedProxyRequests.reduce((counts, item) => {
        counts[item.method] = (counts[item.method] ?? 0) + 1;
        return counts;
      }, {}),
      blockedDestinationsRecorded: false,
      pageRequestOutsideLoopbackCount: unexpectedPageRequests.length,
      pageRequestsOutsideLoopback: unexpectedPageRequests,
    },
    scope: {
      tested: 'Storage.setItem DOMString conversion; length/key/Object.keys and observed enumeration ordering; overwrite and reinsertion; named properties and built-in collisions; synchronous localStorage/sessionStorage reads; localStorage reload persistence; per-origin separation; sessionStorage opener snapshot and noopener isolation; inherited HTTP-origin Blob document local/session storage and Blob storage event URL; storage event details and no-op dispatch suppression; event URL after pushState; opaque data: SecurityError; bounded near-5-Mi-code-unit localStorage quota for ASCII, BMP non-ASCII, and supplementary characters.',
      quota: 'Each quota trial uses one synthetic localStorage value and clears before the next trial. The search bound is 5 Mi UTF-16 code units + 64 Ki code units. The fixture records lengths, UTF-8 SHA-256, accepted/rejected names, and no payload bytes.',
      notTested: 'Storage persistence across browser restarts/profiles, browser eviction, private browsing, partitioned storage/third-party contexts, file: origins, StorageManager.estimate(), multi-process races, quota under multiple keys or sessionStorage quota, and crash recovery.',
      transport: 'Plain HTTP is served only from 127.0.0.1; localhost is explicitly mapped to 127.0.0.1. The configured 127.0.0.1 proxy never forwards and page routing allows only loopback HTTP, synthetic data:, and Blob URLs with loopback embedded origins. No TLS is used. Any proxy attempts are locally denied and included in externalProxy.',
    },
  };
  const normalizedFixture = normalize(fixture, actualPort, proxyPort);
  const fixturePath = process.env.PIRC_FIXTURE_PATH ??
    path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-storage-chrome155.json');
  await writeFile(fixturePath, JSON.stringify(normalizedFixture, null, 2) + '\n');
  const fixtureBytes = await readFile(fixturePath);
  process.stdout.write(JSON.stringify({
    browserVersion: normalizedFixture.browserVersion,
    fixturePath,
    runnerSha256: normalizedFixture.runnerSha256,
    fixtureSha256: createHash('sha256').update(fixtureBytes).digest('hex'),
    caseCount: normalizedFixture.caseCount,
    requestCount: normalizedFixture.serverRequests.length,
    pageRequestCount: normalizedFixture.pageRequests.length,
    blockedProxyRequestCount: normalizedFixture.externalProxy.blockedRequestCount,
    authorizationPresentCount: normalizedFixture.serverRequests.filter(item => item.authorizationPresent).length,
    cookiePresentCount: normalizedFixture.serverRequests.filter(item => item.cookiePresent).length,
    quota: quota.result.map(item => ({
      id: item.id,
      maxAcceptedValueUtf16CodeUnits: item.maxAcceptedValueUtf16CodeUnits,
      firstRejectedValueUtf16CodeUnits: item.firstRejectedValueUtf16CodeUnits,
      acceptedAtBound: item.acceptedAtBound,
      rejectedErrorName: item.rejectedErrorName,
    })),
    cases: normalizedFixture.cases.map(item => item.caseId),
  }, null, 2) + '\n');
} finally {
  for (const page of ownedPages) {
    if (!page.isClosed()) await page.close().catch(() => {});
  }
  if (context) await context.close().catch(() => {});
  if (browser) await browser.close().catch(() => {});
  await Promise.all([closeServer(localServer), closeServer(nonForwardingProxy)]);
}
