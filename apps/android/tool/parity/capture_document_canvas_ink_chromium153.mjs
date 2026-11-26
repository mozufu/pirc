import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { requireTestBrowserExecutable } from './test_browser.mjs';

const require = createRequire(new URL('../../../../package.json', import.meta.url));
const { chromium } = require('playwright-core');
const fontPath = new URL('./vendor/canvas-text-fixture-font/Roboto-Regular.ttf', import.meta.url);
const fontBytes = readFileSync(fontPath);
const fontSha256 = createHash('sha256').update(fontBytes).digest('hex');
const expectedFontSha256 = '79e851404657dac2106b3d22ad256d47824a9a5765458edb72c9102a45816d95';
if (fontSha256 !== expectedFontSha256) throw new Error(`Unexpected Roboto fixture SHA-256: ${fontSha256}`);

const FAMILY = 'PircParityRoboto';
const PRIMARY_FONT = `16px "${FAMILY}"`;
const metricProperties = [
  'width',
  'actualBoundingBoxLeft',
  'actualBoundingBoxRight',
  'actualBoundingBoxAscent',
  'actualBoundingBoxDescent',
  'fontBoundingBoxAscent',
  'fontBoundingBoxDescent',
  'emHeightAscent',
  'emHeightDescent',
  'hangingBaseline',
  'alphabeticBaseline',
  'ideographicBaseline',
];
const corpus = [
  { id: 'empty', text: '' },
  { id: 'spaces-only', text: '   ' },
  { id: 'leading-space', text: ' AV' },
  { id: 'trailing-space', text: 'AV ' },
  { id: 'trailing-two-spaces', text: 'AV  ' },
  { id: 'trailing-tab', text: 'AV\t' },
  { id: 'trailing-newline', text: 'AV\n' },
  { id: 'nonbreaking-space', text: 'AV\u00a0' },
  { id: 'kerning-av', text: 'AV' },
  { id: 'kerning-to', text: 'To' },
  { id: 'ligature-ffi', text: 'ffi' },
  { id: 'ligature-office', text: 'office' },
  { id: 'combining-composed-e-acute', text: 'café' },
  { id: 'combining-decomposed-e-acute', text: 'cafe\u0301' },
  { id: 'combining-a-acute', text: 'A\u0301' },
  { id: 'greek', text: 'Καλημέρα κόσμε' },
  { id: 'cyrillic', text: 'Привет, мир' },
  { id: 'rtl-covered-latin', text: 'AV To', direction: 'rtl' },
];
const sizeCases = [
  { id: 'size-12', text: 'AV', font: `12px "${FAMILY}"` },
  { id: 'size-16-5', text: 'AV', font: `16.5px "${FAMILY}"` },
  { id: 'size-32', text: 'AV', font: `32px "${FAMILY}"` },
];
const alignmentCases = ['left', 'right', 'center', 'start', 'end'].flatMap(textAlign =>
  ['top', 'hanging', 'middle', 'alphabetic', 'ideographic', 'bottom'].map(textBaseline => ({
    id: `align-${textAlign}-baseline-${textBaseline}`,
    text: 'AV',
    direction: 'ltr',
    textAlign,
    textBaseline,
  })),
);
const edgeCases = [
  { id: 'empty-top', text: '', textAlign: 'left', textBaseline: 'top' },
  { id: 'empty-middle', text: '', textAlign: 'left', textBaseline: 'middle' },
  { id: 'empty-bottom', text: '', textAlign: 'left', textBaseline: 'bottom' },
  { id: 'spaces-only-right-alphabetic', text: '   ', textAlign: 'right', textBaseline: 'alphabetic' },
  { id: 'spaces-only-center-alphabetic', text: '   ', textAlign: 'center', textBaseline: 'alphabetic' },
  { id: 'spaces-only-right-top', text: '   ', textAlign: 'right', textBaseline: 'top' },
].map(item => ({ ...item, font: PRIMARY_FONT, direction: 'ltr' }));
const caseDefinitions = [
  ...corpus.map(item => ({ ...item, font: PRIMARY_FONT })),
  ...sizeCases,
  ...alignmentCases,
  ...edgeCases,
].map(item => ({
  ...item,
  font: item.font ?? PRIMARY_FONT,
  direction: item.direction ?? 'ltr',
  textAlign: item.textAlign ?? 'left',
  textBaseline: item.textBaseline ?? 'alphabetic',
}));

function cmapTable(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const tableCount = view.getUint16(4, false);
  for (let index = 0; index < tableCount; index++) {
    const record = 12 + index * 16;
    if (String.fromCharCode(...bytes.subarray(record, record + 4)) === 'cmap') return view.getUint32(record + 8, false);
  }
  throw new Error('Roboto fixture has no cmap table.');
}

function supportsCodepoint(bytes, codepoint) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const cmap = cmapTable(bytes);
  const encodingCount = view.getUint16(cmap + 2, false);
  const subtables = [];
  for (let index = 0; index < encodingCount; index++) {
    const record = cmap + 4 + index * 8;
    const offset = cmap + view.getUint32(record + 4, false);
    subtables.push({ format: view.getUint16(offset, false), offset });
  }
  subtables.sort((left, right) => (right.format === 12) - (left.format === 12));
  for (const { format, offset } of subtables) {
    if (format === 12) {
      const groupCount = view.getUint32(offset + 12, false);
      let low = 0;
      let high = groupCount - 1;
      while (low <= high) {
        const mid = (low + high) >>> 1;
        const group = offset + 16 + mid * 12;
        const first = view.getUint32(group, false);
        const last = view.getUint32(group + 4, false);
        if (codepoint < first) high = mid - 1;
        else if (codepoint > last) low = mid + 1;
        else return view.getUint32(group + 8, false) + codepoint - first !== 0;
      }
    } else if (format === 4 && codepoint <= 0xffff) {
      const segmentCount = view.getUint16(offset + 6, false) / 2;
      const endBase = offset + 14;
      const startBase = endBase + segmentCount * 2 + 2;
      const deltaBase = startBase + segmentCount * 2;
      const rangeBase = deltaBase + segmentCount * 2;
      for (let index = 0; index < segmentCount; index++) {
        const end = view.getUint16(endBase + index * 2, false);
        const start = view.getUint16(startBase + index * 2, false);
        if (codepoint < start || codepoint > end) continue;
        const delta = view.getInt16(deltaBase + index * 2, false);
        const rangeOffsetAddress = rangeBase + index * 2;
        const rangeOffset = view.getUint16(rangeOffsetAddress, false);
        if (rangeOffset === 0) return ((codepoint + delta) & 0xffff) !== 0;
        const glyphAddress = rangeOffsetAddress + rangeOffset + (codepoint - start) * 2;
        const glyph = view.getUint16(glyphAddress, false);
        return glyph !== 0 && ((glyph + delta) & 0xffff) !== 0;
      }
    }
  }
  return false;
}

function fontCoverage(text) {
  const missingCodepoints = [...new Set([...text]
    .map(character => character.codePointAt(0))
    .filter(codepoint => codepoint > 0x20 && codepoint !== 0x7f && !supportsCodepoint(fontBytes, codepoint)))];
  return {
    allNonWhitespaceCodepointsPresent: missingCodepoints.length === 0,
    missingCodepoints: missingCodepoints.map(codepoint => `U+${codepoint.toString(16).toUpperCase().padStart(4, '0')}`),
  };
}

let browser;
try {
  const executable = requireTestBrowserExecutable();
  browser = await chromium.launch({ executablePath: executable, headless: true });
  const browserVersion = browser.version();
  if (!browserVersion.startsWith('153.')) throw new Error(`Expected dedicated Chromium 153, got ${browserVersion}`);

  const viewports = [];
  for (const viewport of [
    { id: 'phone-390', width: 390, height: 844 },
    { id: 'tablet-768', width: 768, height: 1024 },
  ]) {
    const context = await browser.newContext({
      viewport: { width: viewport.width, height: viewport.height },
      deviceScaleFactor: 1,
      isMobile: true,
      hasTouch: true,
    });
    const requests = [];
    await context.route('**/*', async route => {
      requests.push(route.request().url());
      await route.abort('blockedbyclient');
    });
    const page = await context.newPage();
    await page.setContent('<!doctype html><html><head><meta charset="utf-8"></head><body></body></html>', { waitUntil: 'load' });
    const observed = await page.evaluate(async ({ base64Font, family, cases, metricProperties }) => {
      const binary = atob(base64Font);
      const bytes = new Uint8Array(binary.length);
      for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
      const face = await new FontFace(family, bytes.buffer, { style: 'normal', weight: '400' }).load();
      document.fonts.add(face);
      await document.fonts.ready;

      const canvas = document.createElement('canvas');
      const context = canvas.getContext('2d');
      const state = () => Object.fromEntries(['font', 'direction', 'textAlign', 'textBaseline', 'fontKerning']
        .map(key => [key, key in context ? context[key] : null]));
      const fontLoaded = document.fonts.check(`16px "${family}"`, 'Hamburgefontsiv');
      const measurements = cases.map(item => {
        context.font = item.font;
        context.direction = item.direction;
        context.textAlign = item.textAlign;
        context.textBaseline = item.textBaseline;
        if ('fontKerning' in context) context.fontKerning = 'normal';
        const stateBefore = state();
        const metric = context.measureText(item.text);
        const stateAfter = state();
        const values = Object.fromEntries(metricProperties.map(key => [
          key,
          typeof metric[key] === 'number' && Number.isFinite(metric[key]) ? metric[key] : null,
        ]));
        const unsupportedMetricProperties = metricProperties.filter(key => values[key] === null);
        return {
          id: item.id,
          text: item.text,
          direction: context.direction,
          font: context.font,
          textAlign: context.textAlign,
          textBaseline: context.textBaseline,
          metrics: values,
          unsupportedMetricProperties,
          contextStateUnchanged: JSON.stringify(stateBefore) === JSON.stringify(stateAfter),
        };
      });

      context.font = `16px "${family}"`;
      context.direction = 'ltr';
      context.textAlign = 'left';
      context.textBaseline = 'alphabetic';
      if ('fontKerning' in context) context.fontKerning = 'normal';
      const stateBeforeReadonlyCheck = state();
      context.measureText('AV');
      const stateAfterReadonlyCheck = state();
      const readonlyMetric = context.measureText('AV');
      const readonlyWidth = readonlyMetric.width;
      const readonlyDescriptors = metricProperties.map(name => {
        const descriptor = Object.getOwnPropertyDescriptor(TextMetrics.prototype, name);
        return {
          name,
          present: !!descriptor,
          configurable: descriptor?.configurable ?? null,
          enumerable: descriptor?.enumerable ?? null,
          getter: typeof descriptor?.get === 'function',
          setter: typeof descriptor?.set === 'function',
        };
      });
      const reflectSetResult = Reflect.set(readonlyMetric, 'width', readonlyWidth + 100);
      let strictAssignmentError = null;
      try {
        (function () { 'use strict'; readonlyMetric.width = readonlyWidth + 200; })();
      } catch (error) {
        strictAssignmentError = error.name;
      }
      const readonly = {
        widthBefore: readonlyWidth,
        widthAfter: readonlyMetric.width,
        reflectSetResult,
        strictAssignmentError,
        ownWidthAfterAssignment: Object.hasOwn(readonlyMetric, 'width'),
        extensible: Object.isExtensible(readonlyMetric),
        prototypeDescriptors: readonlyDescriptors,
      };

      let illegalConstructor;
      try {
        new TextMetrics();
        illegalConstructor = { succeeded: true, errorName: null, errorMessage: null };
      } catch (error) {
        illegalConstructor = { succeeded: false, errorName: error.name, errorMessage: error.message };
      }
      return {
        fontLoaded,
        resolvedFont: context.font,
        fontKerning: 'fontKerning' in context ? context.fontKerning : null,
        measurements,
        readonly,
        textMetricsConstructor: {
          type: typeof TextMetrics,
          instanceOf: readonlyMetric instanceof TextMetrics,
          illegalConstruction: illegalConstructor,
        },
        contextState: {
          before: stateBeforeReadonlyCheck,
          after: stateAfterReadonlyCheck,
          unchangedByMeasureText: JSON.stringify(stateBeforeReadonlyCheck) === JSON.stringify(stateAfterReadonlyCheck),
        },
      };
    }, {
      base64Font: fontBytes.toString('base64'),
      family: FAMILY,
      cases: caseDefinitions,
      metricProperties,
    });
    if (!observed.fontLoaded) throw new Error(`Roboto did not load in viewport ${viewport.id}.`);
    if (requests.length) throw new Error(`Unexpected request while measuring ink metrics: ${requests.join(', ')}`);
    if (observed.measurements.some(item => !item.contextStateUnchanged)) {
      throw new Error(`measureText changed drawing state in viewport ${viewport.id}.`);
    }
    if (observed.readonly.prototypeDescriptors.some(item => item.setter)) {
      throw new Error(`Unexpected writable TextMetrics prototype property in viewport ${viewport.id}.`);
    }
    if (observed.textMetricsConstructor.illegalConstruction.succeeded) {
      throw new Error(`new TextMetrics() unexpectedly succeeded in viewport ${viewport.id}.`);
    }

    const coverageById = new Map(caseDefinitions.map(item => [item.id, fontCoverage(item.text)]));
    viewports.push({
      id: viewport.id,
      viewportCssPixels: { width: viewport.width, height: viewport.height, deviceScaleFactor: 1, isMobile: true, hasTouch: true },
      fontLoaded: observed.fontLoaded,
      resolvedFont: observed.resolvedFont,
      fontKerning: observed.fontKerning,
      textMetricsConstructor: observed.textMetricsConstructor,
      readonly: observed.readonly,
      contextState: observed.contextState,
      cases: observed.measurements.map(item => {
        const fontCoverage = coverageById.get(item.id);
        return { ...item, fontCoverage, sameFontOracle: fontCoverage.allNonWhitespaceCodepointsPresent };
      }),
      externalRequests: requests,
    });
    await context.close();
  }

  const fixture = {
    schemaVersion: 1,
    capturedBy: 'apps/android/tool/parity/capture_document_canvas_ink_chromium153.mjs',
    oracle: 'Dedicated Playwright-pinned Chromium 153 headless shell. All requests are blocked; the page uses an inline verified Roboto-Regular.ttf FontFace.',
    browser: {
      name: 'Chromium Headless Shell',
      version: browserVersion,
      executable: basename(executable),
      playwrightVersion: require('playwright-core/package.json').version,
    },
    font: {
      family: FAMILY,
      weight: 400,
      style: 'normal',
      primaryFont: PRIMARY_FONT,
      file: 'apps/android/tool/parity/vendor/canvas-text-fixture-font/Roboto-Regular.ttf',
      byteLength: fontBytes.byteLength,
      sha256: fontSha256,
      license: 'apps/android/tool/parity/vendor/canvas-text-fixture-font/Roboto_LICENSE.txt',
      sourceSdk: {
        name: 'Flutter stable SDK material_fonts',
        frameworkVersion: '3.44.4',
        frameworkRevision: 'ad70ec4617166f1c38e5d2bfd388af71fda14f06',
        engineRevision: 'a10d8ac38de835021c8d2f920dbf50a920ccc030',
        originalPath: 'bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
      },
      coverageRule: 'sameFontOracle is true only when every non-whitespace codepoint is present in the pinned Roboto cmap.',
    },
    metricProperties,
    requestedCases: {
      alignmentText: 'AV',
      textAlign: ['left', 'right', 'center', 'start', 'end'],
      textBaseline: ['top', 'hanging', 'middle', 'alphabetic', 'ideographic', 'bottom'],
      fractionalFontSizes: ['12px', '16.5px', '32px'],
      shapingAndCoverage: corpus.map(item => ({ id: item.id, text: item.text, direction: item.direction ?? 'ltr' })),
      emptyWhitespaceAlignmentBaseline: edgeCases.map(item => ({ id: item.id, text: item.text, direction: item.direction, textAlign: item.textAlign, textBaseline: item.textBaseline })),
    },
    captureNotes: {
      fontFace: 'Pinned regular Roboto loaded from base64; font kerning is set to normal when supported.',
      textMetrics: 'Each case stores width, actual ink bounds, font bounds, em bounds, and hanging/alphabetic/ideographic baselines.',
      browserApiChecks: 'Prototype accessors, readonly assignment behavior, illegal new TextMetrics(), and measureText drawing-state preservation are measured from the browser.',
      unsupportedGlyphs: 'Cases whose cmap check fails are marked sameFontOracle=false; their metrics may include browser fallback glyphs.',
      nativeResult: 'This fixture is a browser reference only; it records no Skia or native Android result.',
    },
    viewports,
  };
  const output = new URL('../../../../packages/pirc_render/test/fixtures/parity/document-canvas-ink-chromium153.json', import.meta.url);
  writeFileSync(output, JSON.stringify(fixture) + '\n');
  console.log(JSON.stringify({
    output: fileURLToPath(output),
    browserVersion,
    fontSha256,
    viewportCount: viewports.length,
    caseCountPerViewport: caseDefinitions.length,
    requestCount: viewports.reduce((sum, item) => sum + item.externalRequests.length, 0),
  }));
} finally {
  await browser?.close();
}
