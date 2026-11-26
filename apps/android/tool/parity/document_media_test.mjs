import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createContext, runInContext} from 'node:vm';
import {test} from 'node:test';
import {fileURLToPath} from 'node:url';
import {Event as LinkeDOMEvent, EventTarget as LinkeDOMEventTarget} from './vendor/linkedom-0.18.13/worker.js';

const sourcePath = fileURLToPath(new URL('./document_media_source.js', import.meta.url));
const source = await readFile(sourcePath, 'utf8');

function createHelper(options = {}) {
  const context = createContext({});
  if (Object.prototype.hasOwnProperty.call(options, 'WeakRef')) context.WeakRef = options.WeakRef;
  runInContext(source + '\n;globalThis.__factory = createPircDocumentMedia;', context, {filename: sourcePath});
  const resizeEvents = [];
  const diagnostics = [];
  const helper = context.__factory({
    environment: options.environment,
    Event: LinkeDOMEvent,
    EventTarget: LinkeDOMEventTarget,
    dispatchResize: options.dispatchResize || (detail => resizeEvents.push(detail)),
    diagnostic: (...args) => diagnostics.push(args),
  });
  return {helper, resizeEvents, diagnostics};
}

test('defaults and installed viewport/screen getters stay live without initial events', () => {
  const {helper, resizeEvents} = createHelper();
  const initial = helper.snapshot();
  assert.deepEqual(JSON.parse(JSON.stringify(initial)), {
    width: 390,
    height: 844,
    devicePixelRatio: 1,
    dark: false,
    reducedMotion: false,
    pointer: 'coarse',
    hover: 'none',
    screenWidth: 390,
    screenHeight: 844,
  });
  const target = {};
  assert.equal(helper.install(target), target);
  assert.equal(target.innerWidth, 390);
  assert.equal(target.innerHeight, 844);
  assert.equal(target.devicePixelRatio, 1);
  const screen = target.screen;
  assert.equal(screen.width, 390);
  assert.equal(screen.height, 844);
  assert.equal(target.matchMedia('(min-width: 390px)').matches, true);
  assert.equal(target.matchMedia('').matches, true);
  assert.equal(target.matchMedia('').media, '');
  assert.equal(target.matchMedia('not').matches, false);
  assert.equal(target.matchMedia('not').media, 'not all');
  assert.equal(resizeEvents.length, 0);

  helper.update({width: 640, height: 360, devicePixelRatio: 2, screenWidth: 900, screenHeight: 600});
  assert.equal(target.innerWidth, 640);
  assert.equal(target.innerHeight, 360);
  assert.equal(target.devicePixelRatio, 2);
  assert.equal(target.screen, screen);
  assert.equal(screen.width, 900);
  assert.equal(screen.height, 600);
  assert.deepEqual(JSON.parse(JSON.stringify(resizeEvents)), [{width: 640, height: 360}]);
  assert.equal(helper.install(target), target);
  assert.equal(resizeEvents.length, 1);
});

test('screen media types, boolean expressions, dimensions, units, and MQ4 ranges match', () => {
  const {helper} = createHelper({environment: {
    width: 800,
    height: 600,
    devicePixelRatio: 2,
    dark: true,
    reducedMotion: true,
    pointer: 'coarse',
    hover: 'none',
    screenWidth: 1200,
    screenHeight: 900,
  }});
  const matches = query => helper.matchMedia(query).matches;

  for (const query of [
    'all',
    'screen',
    'only screen',
    'screen and (min-width: 50em)',
    '(min-width: 800px) and (max-height: 600px)',
    '(width: 50rem)',
    '(width >= 800px)',
    '(600px < width <= 800px)',
    '(height < 700px)',
    '(device-width: 1200px)',
    '(orientation: landscape)',
    '(aspect-ratio: 4/3)',
    '(min-resolution: 192dpi)',
    '(resolution = 2dppx)',
    '(resolution: 75.59055118110236dpcm)',
    '(pointer: coarse)',
    '(any-pointer: coarse)',
    '(hover: none)',
    '(any-hover: none)',
    '(prefers-color-scheme: dark)',
    '(prefers-reduced-motion: reduce)',
    '((min-width: 900px) or (max-height: 700px))',
    '(min-width: 900px), screen and (max-height: 700px)',
    'not (width > 800px)',
  ]) assert.equal(matches(query), true, query);

  for (const query of [
    'print',
    'not all',
    '(min-width: 801px)',
    '(width: 799px)',
    '(orientation: portrait)',
    '(aspect-ratio: 16/9)',
    '(resolution: 1dppx)',
    '(pointer: fine)',
    '(hover: hover)',
    '(prefers-color-scheme: light)',
    '(prefers-reduced-motion: no-preference)',
    '(unknown-feature: anything)',
    '(',
  ]) assert.equal(matches(query), false, query);

  assert.equal(matches('not nonsense'), true);
  assert.equal(matches('not (unknown-feature: anything)'), false);
  assert.equal(matches('(width > 800px) or (height < 700px)'), true);
  assert.equal(matches('(width > 800px) and (height < 700px)'), false);
  assert.equal(matches('(min-width: 20rem) and ((orientation: landscape) or (prefers-color-scheme: dark))'), true);
});

test('matches every captured Chromium 153 query across viewport, scale, preference, and touch contexts', async () => {
  const fixture = JSON.parse(await readFile(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-media-chromium153.json', import.meta.url), 'utf8'));
  const contexts = [
    ...fixture.viewportMatrix.cases.map(row => ['desktop', row]),
    ...fixture.resolutionContexts.map(row => ['desktop', row]),
    ...fixture.touchContext.cases.map(row => ['touch', row]),
  ];
  const context = createContext({});
  runInContext(source + '\n;globalThis.__factory = createPircDocumentMedia;', context, {filename: sourcePath});

  for (const [inputMode, row] of contexts) {
    const configured = row.configured;
    const helper = context.__factory({
      environment: {
        width: row.innerWidth == null ? configured.width : row.innerWidth,
        height: row.innerHeight == null ? configured.height : row.innerHeight,
        devicePixelRatio: row.devicePixelRatio == null
          ? (configured.deviceScaleFactor == null ? 1 : configured.deviceScaleFactor)
          : row.devicePixelRatio,
        dark: (configured.colorScheme || 'light') === 'dark',
        reducedMotion: configured.reducedMotion === 'reduce',
        pointer: inputMode === 'touch' ? 'coarse' : 'fine',
        hover: inputMode === 'touch' ? 'none' : 'hover',
        screenWidth: row.screen ? row.screen.width : configured.width,
        screenHeight: row.screen ? row.screen.height : configured.height,
      },
      Event: LinkeDOMEvent,
      EventTarget: LinkeDOMEventTarget,
    });
    const observations = [...(row.queryObservations || []), ...(row.resolutionQueries || [])];
    for (const observation of observations) {
      const media = helper.matchMedia(observation.query);
      assert.equal(media.matches, observation.matches, `${row.id}: ${observation.query}`);
      assert.equal(media.media, observation.media, `${row.id}: media serialization for ${observation.query}`);
    }
  }
});

test('matchMedia returns distinct event targets with modern and deprecated change listeners', () => {
  const {helper, resizeEvents, diagnostics} = createHelper();
  const wide = helper.matchMedia('(min-width: 500px)');
  const narrow = helper.matchMedia('(max-width: 500px)');
  const wideAgain = helper.matchMedia('(min-width: 500px)');
  assert.notEqual(wide, wideAgain);
  assert.equal(wide.matches, false);
  assert.equal(narrow.matches, true);
  assert.equal(wide.media, '(min-width: 500px)');
  assert.equal(typeof wide.addEventListener, 'function');

  const publicEvent = new helper.MediaQueryListEvent('change', {matches: true, media: '(min-width: 500px)'});
  assert.equal(publicEvent.matches, true);
  assert.equal(publicEvent.media, '(min-width: 500px)');
  assert.equal(publicEvent.isTrusted, false);
  assert.equal(Object.getOwnPropertyDescriptor(publicEvent, 'matches').set, undefined);
  assert.equal(Reflect.set(publicEvent, 'matches', false), false);
  assert.equal(Reflect.set(wide, 'matches', true), false);

  const changes = [];
  const hostEvents = [];
  const deprecated = event => changes.push(['deprecated', event.matches, event.isTrusted]);
  wide.addEventListener('change', event => {
    hostEvents.push(event);
    changes.push(['modern', event.matches, event.target === wide, narrow.matches, event.isTrusted]);
  });
  wide.addListener(deprecated);
  wide.onchange = event => changes.push(['onchange', event.matches]);
  narrow.onchange = () => changes.push(['narrow', narrow.matches]);
  const secondOnchange = () => changes.push(['stale-onchange']);
  wide.onchange = secondOnchange;
  wide.onchange = event => changes.push(['onchange-latest', event.matches]);
  wide.removeListener(deprecated);

  const result = helper.update({width: 600});
  assert.equal(result.resized, true);
  assert.equal(result.changes, 2);
  assert.equal(wide.matches, true);
  assert.equal(wideAgain.matches, true);
  assert.equal(narrow.matches, false);
  assert.deepEqual(changes, [
    ['modern', true, true, false, true],
    ['onchange-latest', true],
    ['narrow', false],
  ]);
  assert.equal(hostEvents[0].bubbles, false);
  assert.equal(hostEvents[0].cancelable, false);
  assert.equal(hostEvents[0].isTrusted, true);
  assert.equal(Object.getOwnPropertyDescriptor(hostEvents[0], 'matches').set, undefined);
  assert.equal(Reflect.set(hostEvents[0], 'matches', false), false);
  assert.deepEqual(JSON.parse(JSON.stringify(resizeEvents)), [{width: 600, height: 844}]);

  helper.update({width: 600});
  assert.equal(resizeEvents.length, 1);
  helper.update({dark: true});
  assert.equal(resizeEvents.length, 1);
  assert.equal(changes.some(item => item[0] === 'stale-onchange'), false);
  assert.equal(diagnostics.length, 0);
});

test('deprecated removeListener stops a callback after its first change', () => {
  const {helper} = createHelper();
  const list = helper.matchMedia('(min-width: 500px)');
  let calls = 0;
  const listener = () => calls++;
  list.addListener(listener);
  helper.update({width: 600});
  assert.equal(calls, 1);
  list.removeListener(listener);
  helper.update({width: 390});
  assert.equal(calls, 1);
});

test('temporary queries stay untracked while active listeners survive without weak retention', () => {
  const {helper} = createHelper({WeakRef: class {constructor() {throw new Error('Active listeners must not use weak retention');}}});
  for (let index=0; index<1000; index++) helper.matchMedia('(min-width: 500px)').matches;
  assert.equal(helper.update({width: 600}).changes, 0);
  let calls = 0;
  const list = helper.matchMedia('(min-width: 500px)');
  const listener = () => calls++;
  list.addEventListener('change', listener);
  assert.equal(helper.update({width: 390}).changes, 1);
  assert.equal(calls, 1);
  list.removeEventListener('change', listener);
  assert.equal(helper.update({width: 600}).changes, 0);
  assert.equal(list.matches, true);
});

test('change events follow query creation order even when listeners register in reverse', () => {
  const {helper} = createHelper();
  const first = helper.matchMedia('(min-width: 500px)');
  const second = helper.matchMedia('(min-width: 500px)');
  const seen = [];
  second.addListener(() => seen.push('second'));
  first.addListener(() => seen.push('first'));
  helper.update({width: 600});
  assert.deepEqual(seen, ['first','second']);
});

test('active-listener retention releases once and aborted listeners', () => {
  const {helper} = createHelper({WeakRef: undefined});
  const list = helper.matchMedia('(min-width: 500px)');
  let calls = 0;
  list.addEventListener('change', () => calls++, {once: true});
  helper.update({width: 600});
  assert.equal(calls, 1);
  helper.update({width: 390});
  assert.equal(calls, 1);
  assert.equal(list.matches, false);

  const abortable = helper.matchMedia('(min-width: 700px)');
  const controller = new AbortController();
  let abortedCalls = 0;
  abortable.addEventListener('change', () => abortedCalls++, {signal: controller.signal});
  controller.abort();
  helper.update({width: 800});
  assert.equal(abortedCalls, 0);
});

test('preference and resolution changes update matches without a resize event', () => {
  const {helper, resizeEvents} = createHelper();
  const dark = helper.matchMedia('(prefers-color-scheme: dark)');
  const reduce = helper.matchMedia('(prefers-reduced-motion: reduce)');
  const retina = helper.matchMedia('(min-resolution: 2dppx)');
  const events = [];
  dark.addEventListener('change', event => events.push([event.media, event.matches, event.isTrusted]));
  reduce.addListener(event => events.push([event.media, event.matches, event.isTrusted]));
  retina.onchange = event => events.push([event.media, event.matches, event.isTrusted]);

  helper.update({dark: true, reducedMotion: true, devicePixelRatio: 2});
  assert.equal(dark.matches, true);
  assert.equal(reduce.matches, true);
  assert.equal(retina.matches, true);
  assert.deepEqual(events, [
    ['(prefers-color-scheme: dark)', true, true],
    ['(prefers-reduced-motion: reduce)', true, true],
    ['(min-resolution: 2dppx)', true, true],
  ]);
  assert.deepEqual(resizeEvents, []);
});

test('listener failures are diagnosed without stopping later listeners or query updates', () => {
  const {helper, diagnostics} = createHelper();
  const first = helper.matchMedia('(min-width: 500px)');
  const second = helper.matchMedia('(min-width: 500px)');
  let laterListenerRan = false;
  let secondQueryRan = false;
  first.addEventListener('change', () => { throw new Error('listener failed'); });
  first.addEventListener('change', () => { laterListenerRan = true; });
  second.addEventListener('change', () => { secondQueryRan = true; });

  helper.update({width: 600});
  assert.equal(first.matches, true);
  assert.equal(second.matches, true);
  assert.equal(laterListenerRan, true);
  assert.equal(secondQueryRan, true);
  assert.equal(diagnostics.filter(item => item[0] === 'media.listener').length, 1);
});

