import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
import {readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {requireTestBrowserExecutable} from './test_browser.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const scriptDirectory = path.dirname(scriptPath);
const repositoryRoot = path.resolve(scriptDirectory, '../../../..');
const require = createRequire(import.meta.url);
const {chromium} = require(require.resolve('playwright-core', {
  paths: [path.join(repositoryRoot, 'apps/gateway')],
}));
const playwrightPackage = require(require.resolve('playwright-core/package.json', {
  paths: [path.join(repositoryRoot, 'apps/gateway')],
}));
const browserExecutable = requireTestBrowserExecutable();
assert.ok(!browserExecutable.includes('/Applications/Google Chrome.app/'));
assert.ok(browserExecutable.includes('/.pirc/test-browsers/'));

const fixturePath = path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-media-chromium153.json');
const fixtureOrigin = 'http://127.0.0.1:43100';
const viewportConfigurations = [
  {id: '390x844-light-root1', width: 390, height: 844, colorScheme: 'light', rootFontScale: 1},
  {id: '390x844-dark-root2', width: 390, height: 844, colorScheme: 'dark', rootFontScale: 2},
  {id: '390x1024-light-root2', width: 390, height: 1024, colorScheme: 'light', rootFontScale: 2},
  {id: '390x1024-dark-root1', width: 390, height: 1024, colorScheme: 'dark', rootFontScale: 1},
  {id: '768x844-light-root2', width: 768, height: 844, colorScheme: 'light', rootFontScale: 2},
  {id: '768x844-dark-root1', width: 768, height: 844, colorScheme: 'dark', rootFontScale: 1},
  {id: '768x1024-light-root1', width: 768, height: 1024, colorScheme: 'light', rootFontScale: 1},
  {id: '768x1024-dark-root2', width: 768, height: 1024, colorScheme: 'dark', rootFontScale: 2},
  {id: '390x844-light-root2', width: 390, height: 844, colorScheme: 'light', rootFontScale: 2},
  {id: '390x844-dark-root1', width: 390, height: 844, colorScheme: 'dark', rootFontScale: 1},
  {id: '390x1024-light-root1', width: 390, height: 1024, colorScheme: 'light', rootFontScale: 1},
  {id: '390x1024-dark-root2', width: 390, height: 1024, colorScheme: 'dark', rootFontScale: 2},
  {id: '768x844-light-root1', width: 768, height: 844, colorScheme: 'light', rootFontScale: 1},
  {id: '768x844-dark-root2', width: 768, height: 844, colorScheme: 'dark', rootFontScale: 2},
  {id: '768x1024-light-root2', width: 768, height: 1024, colorScheme: 'light', rootFontScale: 2},
  {id: '768x1024-dark-root1', width: 768, height: 1024, colorScheme: 'dark', rootFontScale: 1},
];

const queryCorpus = [
  {id: 'width-min-390', query: '(min-width: 390px)'},
  {id: 'width-exact-390', query: '(width: 390px)'},
  {id: 'width-max-767', query: '(max-width: 767px)'},
  {id: 'width-min-768', query: '(min-width: 768px)'},
  {id: 'height-exact-844', query: '(height: 844px)'},
  {id: 'height-min-1024', query: '(min-height: 1024px)'},
  {id: 'viewport-width-min-600', query: '(min-width: 600px)'},
  {id: 'viewport-height-min-600', query: '(min-height: 600px)'},
  {id: 'width-em-24', query: '(min-width: 24em)'},
  {id: 'width-em-30', query: '(min-width: 30em)'},
  {id: 'width-rem-25', query: '(min-width: 25rem)'},
  {id: 'height-rem-52', query: '(min-height: 52rem)'},
  {id: 'orientation-portrait', query: '(orientation: portrait)'},
  {id: 'orientation-landscape', query: '(orientation: landscape)'},
  {id: 'aspect-exact-390-844', query: '(aspect-ratio: 390 / 844)'},
  {id: 'aspect-min-square', query: '(min-aspect-ratio: 1 / 1)'},
  {id: 'aspect-min-3-2', query: '(min-aspect-ratio: 3 / 2)'},
  {id: 'resolution-1dppx', query: '(resolution: 1dppx)'},
  {id: 'resolution-2dppx', query: '(resolution: 2dppx)'},
  {id: 'resolution-192dpi', query: '(resolution: 192dpi)'},
  {id: 'resolution-max-3dppx', query: '(max-resolution: 3dppx)'},
  {id: 'scheme-light', query: '(prefers-color-scheme: light)'},
  {id: 'scheme-dark', query: '(prefers-color-scheme: dark)'},
  {id: 'motion-no-preference', query: '(prefers-reduced-motion: no-preference)'},
  {id: 'motion-reduce', query: '(prefers-reduced-motion: reduce)'},
  {id: 'pointer-coarse', query: '(pointer: coarse)'},
  {id: 'pointer-fine', query: '(pointer: fine)'},
  {id: 'pointer-none', query: '(pointer: none)'},
  {id: 'hover-hover', query: '(hover: hover)'},
  {id: 'hover-none', query: '(hover: none)'},
  {id: 'any-pointer-coarse', query: '(any-pointer: coarse)'},
  {id: 'any-pointer-fine', query: '(any-pointer: fine)'},
  {id: 'any-hover-hover', query: '(any-hover: hover)'},
  {id: 'media-screen', query: 'screen'},
  {id: 'media-print', query: 'print'},
  {id: 'media-not-print', query: 'not print'},
  {id: 'media-only-screen', query: 'only screen'},
  {id: 'screen-and-min-width', query: 'screen and (min-width: 600px)'},
  {id: 'comma-screen-print', query: 'screen, print'},
  {id: 'not-screen-and-min-width', query: 'not screen and (min-width: 600px)'},
  {id: 'not-min-width', query: 'not (min-width: 600px)'},
  {id: 'not-all-and-width', query: 'not all and (min-width: 600px)'},
  {id: 'or-width-height', query: '(width >= 600px) or (height < 500px)'},
  {id: 'range-width-chain', query: '(400px <= width <= 800px)'},
  {id: 'range-width-and', query: '(width >= 400px) and (width <= 800px)'},
  {id: 'or-width-height-range', query: '(width < 500px) or (height < 500px)'},
  {id: 'unknown-feature-value', query: '(codex-unknown: 1)'},
  {id: 'unknown-feature-boolean', query: '(unknown-feature)'},
  {id: 'not-unknown-feature', query: 'not (unknown-feature)'},
  {id: 'not-all-unknown-feature', query: 'not all and (unknown-feature)'},
  {id: 'not-screen-unknown-feature', query: 'not screen and (unknown-feature)'},
  {id: 'parenthesized-not-unknown-feature', query: '(not (unknown-feature))'},
  {id: 'not-unknown-media-type', query: 'not nonsense'},
  {id: 'not-invalid-width-value', query: 'not (width: bogus)'},
  {id: 'not-invalid-width-range-value', query: 'not (width > nope)'},
  {id: 'invalid-comma-valid-screen-branch', query: '(width: bogus), screen'},
  {id: 'invalid-comma-valid-width-branch', query: '(width > nope), (min-width: 600px)'},
  {id: 'unknown-media-type', query: 'codex-unknown and (min-width: 600px)'},
  {id: 'unknown-type-comma-screen', query: 'codex-unknown, screen'},
  {id: 'invalid-empty', query: ''},
  {id: 'invalid-open-paren', query: '('},
  {id: 'invalid-feature-value', query: '(min-width:)'},
  {id: 'invalid-trailing-and', query: 'screen and ('},
  {id: 'invalid-lone-not', query: 'not'},
  {id: 'range-width-ge-600', query: '(width >= 600px)'},
];

const serverRequests = [];
const pageRequests = [];
const blockedPageRequests = [];
const blockedProxyRequests = [];
const ownedContexts = new Set();
const runnerStart = performance.now();
let actualOrigin = '';

function responseBody(url) {
  if (url.pathname === '/page') {
    return {
      status: 200,
      contentType: 'text/html; charset=utf-8',
      body: '<!doctype html><html><head><meta charset="utf-8">' +
        '<meta name="viewport" content="width=device-width, initial-scale=1">' +
        '<title>synthetic media oracle</title></head><body>' +
        '<div id="probe"></div></body></html>',
    };
  }
  return {status: 404, contentType: 'text/plain; charset=utf-8', body: 'synthetic media oracle: not found'};
}

const server = createServer((request, response) => {
  const hostHeader = request.headers.host ?? '';
  const requestUrl = new URL(request.url ?? '/', 'http://' + hostHeader);
  const spec = responseBody(requestUrl);
  serverRequests.push({
    sequence: serverRequests.length + 1,
    elapsedMs: Number((performance.now() - runnerStart).toFixed(1)),
    method: request.method ?? '',
    hostname: requestUrl.hostname,
    path: requestUrl.pathname + requestUrl.search,
    url: requestUrl.href,
    origin: request.headers.origin ?? null,
    referer: request.headers.referer ?? null,
    authorizationPresent: Boolean(request.headers.authorization),
    cookiePresent: Boolean(request.headers.cookie),
    secFetchSite: request.headers['sec-fetch-site'] ?? null,
    secFetchMode: request.headers['sec-fetch-mode'] ?? null,
    secFetchDest: request.headers['sec-fetch-dest'] ?? null,
    responseStatus: spec.status,
    responseContentType: spec.contentType,
  });
  request.resume();
  response.writeHead(spec.status, {
    'cache-control': 'no-store',
    'content-type': spec.contentType,
  });
  response.end(spec.body);
});

const nonForwardingProxy = createServer((request, response) => {
  blockedProxyRequests.push({method: request.method ?? ''});
  response.writeHead(403, {
    'content-type': 'text/plain; charset=utf-8',
    connection: 'close',
  });
  response.end('This synthetic media oracle proxy never forwards requests.');
});
nonForwardingProxy.on('connect', (_request, socket) => {
  blockedProxyRequests.push({method: 'CONNECT'});
  socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
});

async function listen(target, host) {
  await new Promise((resolve, reject) => {
    target.once('error', reject);
    target.listen(0, host, () => {
      target.off('error', reject);
      resolve();
    });
  });
  const address = target.address();
  assert.ok(address && typeof address === 'object');
  return address.port;
}

async function closeServer(target) {
  if (target.closeAllConnections) target.closeAllConnections();
  if (target.listening) await new Promise(resolve => target.close(resolve));
}

async function makeContext(options, tag) {
  const context = await browser.newContext(options);
  ownedContexts.add(context);
  await context.route('**/*', async route => {
    const requestUrl = route.request().url();
    if (new URL(requestUrl).origin === actualOrigin) {
      await route.continue();
      return;
    }
    blockedPageRequests.push({tag, method: route.request().method(), url: requestUrl});
    await route.abort();
  });
  return context;
}

async function makePage(context, caseId) {
  const page = await context.newPage();
  page.on('request', request => pageRequests.push({
    caseId,
    url: request.url(),
    method: request.method(),
    resourceType: request.resourceType(),
  }));
  await page.goto(actualOrigin + '/page?case=' + encodeURIComponent(caseId), {
    waitUntil: 'load',
  });
  return page;
}

async function inspectQueries(page, queries = queryCorpus, rootFontScale = 1) {
  return page.evaluate(({queries, rootFontScale}) => {
    const probe = document.querySelector('#probe');
    document.documentElement.style.fontSize = `${16 * rootFontScale}px`;
    const styleFor = (query, index) => {
      const style = document.createElement('style');
      const property = `--mq-${index}`;
      style.textContent = `#probe { ${property}: inactive; }\n@media ${query} { #probe { ${property}: active; } }`;
      document.head.append(style);
      return property;
    };
    const properties = queries.map((entry, index) => styleFor(entry.query, index));
    const computed = getComputedStyle(probe);
    const observations = queries.map((entry, index) => {
      let media = null;
      let matches = null;
      let error = null;
      try {
        const query = window.matchMedia(entry.query);
        media = query.media;
        matches = query.matches;
      } catch (caught) {
        error = String(caught);
      }
      const cssStatus = computed.getPropertyValue(properties[index]).trim() || null;
      return {
        id: entry.id,
        query: entry.query,
        media,
        matches,
        cssStatus,
        cssApplied: cssStatus === 'active',
        error,
      };
    });
    const rect = probe.getBoundingClientRect();
    return {
      innerWidth: window.innerWidth,
      innerHeight: window.innerHeight,
      visualViewport: window.visualViewport ? {
        width: Number(window.visualViewport.width.toFixed(2)),
        height: Number(window.visualViewport.height.toFixed(2)),
        scale: window.visualViewport.scale,
      } : null,
      devicePixelRatio: window.devicePixelRatio,
      screen: {width: window.screen.width, height: window.screen.height},
      computedRootFontSize: getComputedStyle(document.documentElement).fontSize,
      probe: {
        computedWidth: getComputedStyle(probe).width,
        computedHeight: getComputedStyle(probe).height,
        rectWidth: Number(rect.width.toFixed(2)),
        rectHeight: Number(rect.height.toFixed(2)),
      },
      queryObservations: observations,
    };
  }, {queries, rootFontScale});
}

async function waitForMediaFrame(page) {
  await page.evaluate(() => new Promise(resolve => {
    requestAnimationFrame(() => requestAnimationFrame(resolve));
  }));
}

async function captureViewportConfiguration(browser, config) {
  const context = await makeContext({
    viewport: {width: config.width, height: config.height},
    deviceScaleFactor: 1,
    isMobile: false,
    hasTouch: false,
    colorScheme: config.colorScheme,
    reducedMotion: 'no-preference',
  }, config.id);
  try {
    const page = await makePage(context, config.id);
    const observations = await inspectQueries(page, queryCorpus, config.rootFontScale);
    return {
      id: config.id,
      configured: {...config, deviceScaleFactor: 1, isMobile: false, hasTouch: false,
        reducedMotion: 'no-preference'},
      ...observations,
    };
  } finally {
    await context.close();
    ownedContexts.delete(context);
  }
}

async function captureResolutionContext(browser, dpr) {
  const id = `device-scale-${dpr}x`;
  const context = await makeContext({
    viewport: {width: 390, height: 844},
    deviceScaleFactor: dpr,
    isMobile: false,
    hasTouch: false,
    colorScheme: 'light',
    reducedMotion: 'no-preference',
  }, id);
  try {
    const page = await makePage(context, id);
    const observations = await inspectQueries(page, queryCorpus, 1);
    return {
      id,
      configured: {width: 390, height: 844, deviceScaleFactor: dpr,
        isMobile: false, hasTouch: false},
      ...observations,
      resolutionQueries: observations.queryObservations.filter(item => item.id.startsWith('resolution-')),
    };
  } finally {
    await context.close();
    ownedContexts.delete(context);
  }
}

async function captureTouchContext(browser) {
  const commonIds = new Set([
    'width-min-390', 'width-min-768', 'height-exact-844', 'height-min-1024',
    'orientation-portrait', 'orientation-landscape', 'aspect-min-square',
    'resolution-1dppx', 'scheme-light', 'scheme-dark', 'motion-no-preference',
    'motion-reduce', 'pointer-coarse', 'pointer-fine', 'pointer-none',
    'hover-hover', 'hover-none', 'any-pointer-coarse', 'any-pointer-fine',
    'any-hover-hover',
  ]);
  const commonQueries = queryCorpus.filter(item => commonIds.has(item.id));
  const configurations = [
    {id: 'touch-phone-390x844-light', width: 390, height: 844, colorScheme: 'light'},
    {id: 'touch-phone-390x844-dark', width: 390, height: 844, colorScheme: 'dark'},
    {id: 'touch-tablet-768x1024-light', width: 768, height: 1024, colorScheme: 'light'},
    {id: 'touch-tablet-768x1024-dark', width: 768, height: 1024, colorScheme: 'dark'},
  ];
  const cases = [];
  for (const config of configurations) {
    const context = await makeContext({
      viewport: {width: config.width, height: config.height},
      deviceScaleFactor: 1,
      isMobile: false,
      hasTouch: true,
      colorScheme: config.colorScheme,
      reducedMotion: 'no-preference',
    }, config.id);
    try {
      const page = await makePage(context, config.id);
      const observations = await inspectQueries(page, commonQueries, 1);
      const platform = await page.evaluate(() => ({
        innerWidth: window.innerWidth,
        innerHeight: window.innerHeight,
        visualViewportWidth: window.visualViewport?.width ?? null,
        screenWidth: screen.width,
        devicePixelRatio: window.devicePixelRatio,
        maxTouchPoints: navigator.maxTouchPoints,
        ontouchstartInWindow: 'ontouchstart' in window,
      }));
      cases.push({
        id: config.id,
        design: config.width === 390 ? 'phone' : 'tablet',
        configured: {...config, deviceScaleFactor: 1, isMobile: false, hasTouch: true,
          reducedMotion: 'no-preference'},
        ...platform,
        ...observations,
      });
    } finally {
      await context.close();
      ownedContexts.delete(context);
    }
  }
  return {design: 'phone/tablet × light/dark; hasTouch=true and isMobile=false', cases};
}

async function captureResizeEvents(browser) {
  const id = 'viewport-resize-reverse-rotation-and-mql-events';
  const context = await makeContext({
    viewport: {width: 390, height: 844}, deviceScaleFactor: 1,
    isMobile: false, hasTouch: false, colorScheme: 'light',
    reducedMotion: 'no-preference',
  }, id);
  try {
    const page = await makePage(context, id);
    const initial = await page.evaluate(({querySpecs}) => {
      const records = querySpecs.map(entry => ({
        id: entry.id,
        media: entry.query,
        list: matchMedia(entry.query),
      }));
      const byId = new Map(records.map(record => [record.id, record.list]));
      const width = byId.get('viewport-width-min-600');
      const height = byId.get('viewport-height-min-600');
      const portrait = byId.get('orientation-portrait');
      const events = [];
      window.__mediaEventRecords = events;
      const state = () => ({
        width: innerWidth,
        height: innerHeight,
        matches: Object.fromEntries(records.map(record => [record.id, record.list.matches])),
      });
      const descriptor = (event, property) => {
        for (let prototype = event; prototype; prototype = Object.getPrototypeOf(prototype)) {
          const value = Object.getOwnPropertyDescriptor(prototype, property);
          if (value) return {hasGetter: typeof value.get === 'function',
            hasSetter: typeof value.set === 'function', writable: value.writable ?? null};
        }
        return null;
      };
      const log = (api, event) => {
        const originalMatches = event.matches;
        let assignmentError = null;
        try { event.matches = !originalMatches; } catch (error) { assignmentError = String(error); }
        events.push({
          api,
          type: event.type,
          media: event.media,
          matches: originalMatches,
          matchesAfterReadonlyWrite: event.matches,
          readonlyWriteChangedValue: originalMatches !== event.matches,
          assignmentError,
          bubbles: event.bubbles,
          cancelable: event.cancelable,
          isTrusted: event.isTrusted,
          matchesDescriptor: descriptor(event, 'matches'),
          mediaDescriptor: descriptor(event, 'media'),
          finalState: state(),
        });
      };
      const widthListener = event => log('addListener', event);
      width.addListener(widthListener);
      window.__removeWidthListener = () => width.removeListener(widthListener);
      portrait.onchange = event => log('onchange', event);
      height.addEventListener('change', event => log('addEventListener', event));
      return {
        state: state(),
        mql: Object.fromEntries(records.map(record => [record.id, {
          media: record.list.media,
          matches: record.list.matches,
          onchangeInitiallyNull: record.list.onchange === null,
          addListenerType: typeof record.list.addListener,
          removeListenerType: typeof record.list.removeListener,
        }])),
      };
    }, {querySpecs: queryCorpus});

    await page.setViewportSize({width: 844, height: 390});
    await waitForMediaFrame(page);
    const landscapeMeasurements = await inspectQueries(page, queryCorpus, 1);
    const landscapeEvents = await page.evaluate(() => [...window.__mediaEventRecords]);
    const landscape = {...landscapeMeasurements, events: landscapeEvents};
    await page.evaluate(() => window.__removeWidthListener?.());
    await page.setViewportSize({width: 390, height: 844});
    await waitForMediaFrame(page);
    const portraitMeasurements = await inspectQueries(page, queryCorpus, 1);
    const portraitEvents = await page.evaluate(() => [...window.__mediaEventRecords]);
    const portrait = {...portraitMeasurements, events: portraitEvents};

    const landscapeExpected = Object.fromEntries(
      landscape.queryObservations.map(item => [item.id, item.matches]),
    );
    const atomicEvents = landscape.events.every(event =>
      event.finalState.width === 844 && event.finalState.height === 390 &&
      Object.entries(landscapeExpected).every(([queryId, matches]) =>
        event.finalState.matches[queryId] === matches));
    const portraitExpected = Object.fromEntries(
      portrait.queryObservations.map(item => [item.id, item.matches]),
    );
    const reverseEvents = portrait.events.slice(landscape.events.length);
    const reverseAtomicEvents = reverseEvents.every(event =>
      event.finalState.width === 390 && event.finalState.height === 844 &&
      Object.entries(portraitExpected).every(([queryId, matches]) =>
        event.finalState.matches[queryId] === matches));
    const widthEventsLandscape = landscape.events.filter(event => event.api === 'addListener').length;
    const widthEventsAfterRemoval = portrait.events.filter(event => event.api === 'addListener').length;
    assert.equal(widthEventsLandscape, 1, 'width addListener fires once on the first resize');
    assert.equal(widthEventsAfterRemoval, 1, 'removeListener suppresses the reverse-resize callback');
    assert.ok(atomicEvents, 'each MQL change event sees the complete final landscape query state');
    assert.ok(reverseAtomicEvents, 'each reverse-resize event sees the complete final portrait query state');

    return {
      id,
      initial,
      landscape,
      portrait,
      assertions: {
        allQueryMatchesAtomicAfterLandscapeResize: atomicEvents,
        allQueryMatchesAtomicAfterReverseResize: reverseAtomicEvents,
        widthListenerFiredOnceThenRemoved: widthEventsLandscape === 1 && widthEventsAfterRemoval === 1,
      },
    };
  } finally {
    await context.close();
    ownedContexts.delete(context);
  }
}

async function captureEmulatedPreferences(browser) {
  const id = 'emulate-color-scheme-and-reduced-motion';
  const context = await makeContext({
    viewport: {width: 390, height: 844}, deviceScaleFactor: 1,
    isMobile: false, hasTouch: false, colorScheme: 'light',
    reducedMotion: 'no-preference',
  }, id);
  try {
    const page = await makePage(context, id);
    await page.emulateMedia({media: 'screen', colorScheme: 'light', reducedMotion: 'no-preference'});
    const initial = await page.evaluate(() => {
      const style = document.createElement('style');
      style.textContent = '#probe { --scheme: base; --motion: base; }' +
        '@media (prefers-color-scheme: dark) { #probe { --scheme: dark; } }' +
        '@media (prefers-color-scheme: light) { #probe { --scheme: light; } }' +
        '@media (prefers-reduced-motion: reduce) { #probe { --motion: reduce; } }' +
        '@media (prefers-reduced-motion: no-preference) { #probe { --motion: no-preference; } }';
      document.head.append(style);
      const color = matchMedia('(prefers-color-scheme: dark)');
      const motion = matchMedia('(prefers-reduced-motion: reduce)');
      const events = [];
      color.addEventListener('change', event => events.push({type: event.type,
        media: event.media, matches: event.matches, finalColor: color.matches, finalMotion: motion.matches}));
      motion.onchange = event => events.push({type: event.type, media: event.media,
        matches: event.matches, finalColor: color.matches, finalMotion: motion.matches});
      const state = () => ({
        colorScheme: matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light',
        reducedMotion: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'reduce' : 'no-preference',
        cssScheme: getComputedStyle(document.querySelector('#probe')).getPropertyValue('--scheme').trim(),
        cssMotion: getComputedStyle(document.querySelector('#probe')).getPropertyValue('--motion').trim(),
      });
      window.__preferenceState = state;
      window.__preferenceEvents = events;
      return state();
    });
    await page.emulateMedia({media: 'screen', colorScheme: 'dark', reducedMotion: 'reduce'});
    await waitForMediaFrame(page);
    const darkReduced = await page.evaluate(() => ({state: window.__preferenceState(), events: [...window.__preferenceEvents]}));
    await page.emulateMedia({media: 'screen', colorScheme: 'light', reducedMotion: 'no-preference'});
    await waitForMediaFrame(page);
    const restored = await page.evaluate(() => ({state: window.__preferenceState(), events: [...window.__preferenceEvents]}));
    return {id, initial, darkReduced, restored};
  } finally {
    await context.close();
    ownedContexts.delete(context);
  }
}

async function capturePrintEmulation(browser) {
  const id = 'emulate-screen-print';
  const context = await makeContext({
    viewport: {width: 390, height: 844}, deviceScaleFactor: 1,
    isMobile: false, hasTouch: false,
  }, id);
  try {
    const page = await makePage(context, id);
    await page.emulateMedia({media: 'screen'});
    const queries = [
      {id: 'screen', query: 'screen'},
      {id: 'print', query: 'print'},
      {id: 'not-print', query: 'not print'},
      {id: 'only-screen', query: 'only screen'},
      {id: 'comma-screen-print', query: 'screen, print'},
    ];
    const screen = await inspectQueries(page, queries, 1);
    await page.emulateMedia({media: 'print'});
    await waitForMediaFrame(page);
    const print = await inspectQueries(page, queries, 1);
    return {id, screen, print};
  } finally {
    await context.close();
    ownedContexts.delete(context);
  }
}

function normalizeText(text, origin) {
  return String(text).replaceAll(origin, fixtureOrigin);
}

function normalize(value, origin) {
  if (typeof value === 'string') return normalizeText(value, origin);
  if (Array.isArray(value)) return value.map(item => normalize(item, origin));
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, normalize(item, origin)]));
  }
  return value;
}

let browser = null;
let port = null;
let proxyPort = null;
try {
  port = await listen(server, '127.0.0.1');
  actualOrigin = 'http://127.0.0.1:' + port;
  proxyPort = await listen(nonForwardingProxy, '127.0.0.1');
  browser = await chromium.launch({
    headless: true,
    executablePath: browserExecutable,
    proxy: {
      server: 'http://127.0.0.1:' + proxyPort,
      bypass: 'localhost,127.0.0.1,[::1]',
    },
    args: [
      '--disable-background-networking',
      '--disable-component-update',
      '--disable-sync',
      '--no-first-run',
      '--no-default-browser-check',
      '--host-resolver-rules=MAP localhost 127.0.0.1',
    ],
  });
  assert.match(browser.version(), /^153\./, 'This fixture must use the dedicated Chromium 153 Headless Shell');

  const viewportCases = [];
  for (const config of viewportConfigurations) viewportCases.push(await captureViewportConfiguration(browser, config));
  const resize = await captureResizeEvents(browser);
  const preferences = await captureEmulatedPreferences(browser);
  const printEmulation = await capturePrintEmulation(browser);
  const resolutionContexts = [
    await captureResolutionContext(browser, 2),
    await captureResolutionContext(browser, 3),
  ];
  const touchContext = await captureTouchContext(browser);

  const blockedCountsByMethod = Object.fromEntries([...new Set(blockedProxyRequests.map(item => item.method))]
    .map(method => [method, blockedProxyRequests.filter(item => item.method === method).length]));
  const runnerBytes = await readFile(scriptPath);
  const runnerSha256 = createHash('sha256').update(runnerBytes).digest('hex');
  const rawFixture = {
    fixture: 'packages/pirc_render/test/fixtures/parity/document-media-chromium153.json',
    capturedAtUtc: new Date().toISOString(),
    browserProduct: 'Playwright-pinned Chromium Headless Shell 153',
    browserVersion: browser.version(),
    browserExecutable,
    nodeVersion: process.version,
    playwrightVersion: playwrightPackage.version,
    runner: 'apps/android/tool/parity/verify_document_media_browser.mjs',
    runnerSha256,
    viewportMatrix: {
      design: 'Full 16-row Cartesian product of width 390/768 × height 844/1024 × color scheme light/dark × root-font-scale 1x/2x; every screen/theme/font-size tuple is present. All primary rows use desktop input emulation (hasTouch=false, isMobile=false).',
      cases: viewportCases,
    },
    resize,
    emulatedPreferences: preferences,
    printEmulation,
    resolutionContexts,
    touchContext,
    serverRequests,
    pageRequests,
    blockedPageRequests,
    externalProxy: {
      origin: 'http://127.0.0.1:43199',
      forwardsRequests: false,
      blockedRequestCount: blockedProxyRequests.length,
      blockedCountsByMethod,
    },
    integrity: {
      authorizationPresentCount: serverRequests.filter(item => item.authorizationPresent).length,
      cookiePresentCount: serverRequests.filter(item => item.cookiePresent).length,
      allPageRequestsSyntheticLoopback: pageRequests.every(item => new URL(item.url).origin === actualOrigin),
      hostResolverRules: 'MAP localhost 127.0.0.1',
      backgroundNetworkingDisabled: true,
      nonForwardingProxyConfigured: true,
      browserProfile: 'fresh Playwright-owned temporary profile; no personal profile or tabs accessed',
    },
    scope: {
      tested: 'Full 16-row viewport matrix: width 390/768 × height 844/1024 × light/dark × root font scale 1x/2x, each row captured independently with hasTouch=false and isMobile=false; common matchMedia serialization and matches for viewport width/height in px, em and rem; orientation; aspect ratio; resolution; preferred color scheme; reduced motion; pointer/hover and any-pointer/any-hover; screen/print; only/not/comma/and/or media queries; unknown media feature/type negation; invalid-query behavior; CSS @media custom-property status; viewport swap/reverse resize and MQL onchange/addListener/removeListener/addEventListener; event readonly fields and final matches visibility during updates; color-scheme/reduced-motion emulation; 2x/3x device scale factors; four touch input supplement rows (phone/tablet × light/dark) with hasTouch=true and isMobile=false.',
      notTested: 'Container queries, print pagination/layout, browser zoom, platform accessibility font scaling, user stylesheet overrides, real hardware input devices, actual display color calibration, fullscreen, embedded webviews, and other Chromium versions.',
      transport: 'Synthetic HTML is served only from a Node server bound to 127.0.0.1. Page routing permits only that exact ephemeral origin. The browser proxy binds to 127.0.0.1 and rejects every request without forwarding. Browser background networking is disabled. No external requests or TLS are used.',
    },
  };
  const fixture = normalize(rawFixture, actualOrigin);
  await writeFile(fixturePath, JSON.stringify(fixture, null, 2) + '\n');
  const fixtureBytes = await readFile(fixturePath);
  process.stdout.write(JSON.stringify({
    browserVersion: fixture.browserVersion,
    browserExecutable: fixture.browserExecutable,
    runnerSha256: fixture.runnerSha256,
    fixturePath,
    fixtureSha256: createHash('sha256').update(fixtureBytes).digest('hex'),
    viewportCaseCount: viewportCases.length,
    queryCountPerViewport: queryCorpus.length,
    resizeEventCount: resize.landscape.events.length,
    serverRequestCount: fixture.serverRequests.length,
    pageRequestCount: fixture.pageRequests.length,
    blockedPageRequestCount: fixture.blockedPageRequests.length,
    blockedProxyRequestCount: fixture.externalProxy.blockedRequestCount,
    authorizationPresentCount: fixture.integrity.authorizationPresentCount,
    cookiePresentCount: fixture.integrity.cookiePresentCount,
    configQuickRead: viewportCases.map(item => ({id: item.id, viewport: `${item.innerWidth}x${item.innerHeight}`,
      dpr: item.devicePixelRatio, rootFontSize: item.computedRootFontSize,
      portrait: item.queryObservations.find(query => query.id === 'orientation-portrait')?.matches,
      schemeDark: item.queryObservations.find(query => query.id === 'scheme-dark')?.matches,
      minWidth30em: item.queryObservations.find(query => query.id === 'width-em-30')?.matches,
      minWidth25rem: item.queryObservations.find(query => query.id === 'width-rem-25')?.matches})),
    resize: {initial: resize.initial.state, landscape: {width: resize.landscape.innerWidth, height: resize.landscape.innerHeight},
      portrait: {width: resize.portrait.innerWidth, height: resize.portrait.innerHeight},
      events: resize.landscape.events.map(item => ({api: item.api, media: item.media, matches: item.matches,
        finalState: item.finalState, readonlyWriteChangedValue: item.readonlyWriteChangedValue}))},
    preferences: {initial: preferences.initial, darkReduced: preferences.darkReduced.state,
      restored: preferences.restored.state},
    dpr: resolutionContexts.map(item => ({id: item.id, devicePixelRatio: item.devicePixelRatio,
      resolutions: item.resolutionQueries.map(query => ({query: query.query, matches: query.matches, cssApplied: query.cssApplied}))})),
    touch: touchContext.cases.map(item => ({id: item.id, design: item.design,
      configured: item.configured, innerWidth: item.innerWidth, innerHeight: item.innerHeight,
      visualViewportWidth: item.visualViewportWidth, maxTouchPoints: item.maxTouchPoints,
      matches: item.queryObservations})),
  }, null, 2) + '\n');
} finally {
  for (const context of ownedContexts) await context.close().catch(() => {});
  if (browser) await browser.close();
  await closeServer(server);
  await closeServer(nonForwardingProxy);
}
