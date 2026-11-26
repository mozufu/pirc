import {createHash} from 'node:crypto';
import {createRequire} from 'node:module';
import {readFileSync, writeFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {basename} from 'node:path';
import {requireTestBrowserExecutable} from './test_browser.mjs';

const require = createRequire(new URL('../../../../package.json', import.meta.url));
const {chromium} = require('playwright-core');
const fontPath = new URL('./vendor/canvas-text-fixture-font/Roboto-Regular.ttf', import.meta.url);
const fontBytes = readFileSync(fontPath);
const fontSha256 = createHash('sha256').update(fontBytes).digest('hex');
const expectedFontSha256 = '79e851404657dac2106b3d22ad256d47824a9a5765458edb72c9102a45816d95';
if (fontSha256 !== expectedFontSha256) throw new Error(`Unexpected Roboto fixture SHA-256: ${fontSha256}`);

const FAMILY = 'PircParityRoboto';
const FONT = `16px "${FAMILY}"`;
const corpus = [
  {id: 'empty', text: ''},
  {id: 'spaces-only', text: '   '},
  {id: 'leading-space', text: ' AV'},
  {id: 'trailing-space', text: 'AV '},
  {id: 'trailing-two-spaces', text: 'AV  '},
  {id: 'trailing-tab', text: 'AV\t'},
  {id: 'trailing-newline', text: 'AV\n'},
  {id: 'trailing-form-feed', text: 'AV\f'},
  {id: 'trailing-carriage-return', text: 'AV\r'},
  {id: 'trailing-crlf', text: 'AV\r\n'},
  {id: 'trailing-vertical-tab', text: 'AV\v'},
  {id: 'nonbreaking-space', text: 'AV\u00a0'},
  {id: 'latin-av-kern', text: 'AV'},
  {id: 'latin-a-space-v', text: 'A V'},
  {id: 'latin-to-kern', text: 'To'},
  {id: 'latin-wa-kern', text: 'WA'},
  {id: 'latin-kerning-sequence', text: 'AVATAR To WA'},
  {id: 'latin-office-ligature-candidate', text: 'office'},
  {id: 'latin-ffi-ligature-candidate', text: 'ffi'},
  {id: 'latin-fi-fl-ligature-candidates', text: 'fi fl'},
  {id: 'numbers-digits', text: '0123456789'},
  {id: 'numbers-formatted', text: '1,234.50'},
  {id: 'numbers-time', text: '10:01 PM'},
  {id: 'numbers-date', text: '2026-10-18'},
  {id: 'greek', text: 'Καλημέρα κόσμε'},
  {id: 'cyrillic', text: 'Привет, мир'},
  {id: 'hebrew-missing-from-fixture-font', text: 'שלום עולם'},
  {id: 'arabic-missing-from-fixture-font', text: 'مرحبا بالعالم'},
  {id: 'combining-composed-e-acute', text: 'café'},
  {id: 'combining-decomposed-e-acute', text: 'cafe\u0301'},
  {id: 'combining-a-acute', text: 'A\u0301'},
  {id: 'mixed-bidi-ltr-missing-hebrew', text: 'abc שלום 123', direction: 'ltr'},
  {id: 'mixed-bidi-rtl-missing-hebrew', text: 'abc שלום 123', direction: 'rtl'},
];

// The fixture hash pins this font's cmap. These metadata ranges are the
// UTF-16-independent codepoint coverage reported by fontconfig for that file.
// Every input is still checked against the real cmap parser below.
function cmapTable(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const tableCount = view.getUint16(4, false);
  for (let index = 0; index < tableCount; index++) {
    const record = 12 + index * 16;
    if (String.fromCharCode(...bytes.subarray(record, record + 4)) === 'cmap') {
      return view.getUint32(record + 8, false);
    }
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
    subtables.push({format: view.getUint16(offset, false), offset});
  }
  subtables.sort((left, right) => (right.format === 12) - (left.format === 12));
  for (const {format, offset} of subtables) {
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
  return {allNonWhitespaceCodepointsPresent: missingCodepoints.length === 0,
    missingCodepoints: missingCodepoints.map(codepoint => `U+${codepoint.toString(16).toUpperCase().padStart(4, '0')}`)};
}

const conversionInputs = [
  {id: 'no-argument', inputKind: 'omitted'},
  {id: 'undefined', inputKind: 'undefined'},
  {id: 'number', inputKind: 'number'},
  {id: 'null', inputKind: 'null'},
  {id: 'boolean', inputKind: 'boolean'},
  {id: 'array', inputKind: 'array'},
  {id: 'bigint', inputKind: 'bigint'},
  {id: 'string-object', inputKind: 'string-object'},
  {id: 'to-string-before-value-of', inputKind: 'string-valueof-object'},
  {id: 'symbol-to-primitive', inputKind: 'symbol-to-primitive-object'},
  {id: 'symbol-throws', inputKind: 'symbol'},
];

let browser;
try {
  const executable = requireTestBrowserExecutable();
  browser = await chromium.launch({executablePath: executable, headless: true});
  const viewports = [];
  for (const viewport of [
    {id: 'phone-390', width: 390, height: 844, isMobile: true, hasTouch: true},
    {id: 'tablet-768', width: 768, height: 1024, isMobile: true, hasTouch: true},
  ]) {
    const context = await browser.newContext({
      viewport: {width: viewport.width, height: viewport.height},
      deviceScaleFactor: 1,
      isMobile: viewport.isMobile,
      hasTouch: viewport.hasTouch,
    });
    const requests = [];
    await context.route('**/*', async route => {
      requests.push(route.request().url());
      await route.abort();
    });
    const page = await context.newPage();
    await page.setContent('<!doctype html><html><head><meta charset="utf-8"></head><body></body></html>');
    const observed = await page.evaluate(async ({base64Font, family, font, cases, conversionInputs}) => {
      const binary = atob(base64Font);
      const bytes = new Uint8Array(binary.length);
      for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
      const face = await new FontFace(family, bytes.buffer, {style: 'normal', weight: '400'}).load();
      document.fonts.add(face);
      await document.fonts.ready;

      const canvas = document.createElement('canvas');
      const context = canvas.getContext('2d');
      context.font = font;
      if ('fontKerning' in context) context.fontKerning = 'normal';
      context.direction = 'ltr';
      const fontLoaded = document.fonts.check(context.font, 'Hamburgefontsiv');

      const measurements = cases.map(item => {
        const previousDirection = context.direction;
        context.direction = item.direction || 'ltr';
        const metric = context.measureText(item.text);
        const result = {id: item.id, text: item.text, direction: context.direction, width: metric.width};
        context.direction = previousDirection;
        return result;
      });

      const conversions = conversionInputs.map(item => {
        const events = [];
        let value;
        switch (item.inputKind) {
          case 'omitted': value = undefined; break;
          case 'undefined': value = undefined; break;
          case 'number': value = 42; break;
          case 'null': value = null; break;
          case 'boolean': value = false; break;
          case 'array': value = ['AV', 'To']; break;
          case 'bigint': value = 123n; break;
          case 'string-object': value = new String('AV'); break;
          case 'string-valueof-object': value = {
            toString() { events.push('toString'); return 'AV'; },
            valueOf() { events.push('valueOf'); return 123; },
          }; break;
          case 'symbol-to-primitive-object': value = {
            [Symbol.toPrimitive](hint) { events.push(hint); return 'To'; },
          }; break;
          case 'symbol': value = Symbol('not-a-DOMString'); break;
        }
        try {
          const metric = item.inputKind === 'omitted' ? context.measureText() : context.measureText(value);
          return {id: item.id, inputKind: item.inputKind, width: metric.width, conversionEvents: events};
        } catch (error) {
          return {id: item.id, inputKind: item.inputKind, error: {name: error.name, message: error.message}, conversionEvents: events};
        }
      });

      const readonlyMetric = context.measureText('AV');
      const originalWidth = readonlyMetric.width;
      const widthDescriptor = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(readonlyMetric), 'width');
      const reflectSetResult = Reflect.set(readonlyMetric, 'width', originalWidth + 100);
      let strictAssignmentError = null;
      try {
        (function () { 'use strict'; readonlyMetric.width = originalWidth + 200; })();
      } catch (error) {
        strictAssignmentError = error.name;
      }
      const readonly = {
        widthBefore: originalWidth,
        widthAfter: readonlyMetric.width,
        reflectSetResult,
        strictAssignmentError,
        ownWidthAfterAssignment: Object.hasOwn(readonlyMetric, 'width'),
        extensible: Object.isExtensible(readonlyMetric),
        prototypeWidthDescriptor: widthDescriptor ? {
          configurable: widthDescriptor.configurable,
          enumerable: widthDescriptor.enumerable,
          getter: typeof widthDescriptor.get === 'function',
          setter: typeof widthDescriptor.set === 'function',
        } : null,
      };

      const drawOptionalWidths = [];
      for (const operation of ['fillText','strokeText']) {
        for (const inputKind of ['omitted','undefined','positive-infinity','nan','negative-infinity','zero','negative','null']) {
          context.clearRect(0,0,canvas.width,canvas.height);
          const values = {undefined:undefined,'positive-infinity':Infinity,nan:NaN,'negative-infinity':-Infinity,zero:0,negative:-1,null:null};
          const args = ['AV',10,30];
          if (inputKind !== 'omitted') args.push(values[inputKind]);
          try {
            context[operation](...args);
            const pixels = context.getImageData(0,0,canvas.width,canvas.height).data;
            const hasInk = pixels.some((value,index) => index%4 === 3 && value !== 0);
            drawOptionalWidths.push({operation,inputKind,hasInk});
          } catch (error) { drawOptionalWidths.push({operation,inputKind,error:error.name}); }
        }
      }

      const stateBefore = {font: context.font, direction: context.direction, textAlign: context.textAlign, textBaseline: context.textBaseline};
      context.measureText('A V');
      const stateAfter = {font: context.font, direction: context.direction, textAlign: context.textAlign, textBaseline: context.textBaseline};
      return {
        fontLoaded,
        resolvedFont: context.font,
        fontKerning: 'fontKerning' in context ? context.fontKerning : null,
        measurements,
        conversions,
        drawOptionalWidths,
        readonly,
        stateBefore,
        stateAfter,
      };
    }, {
      base64Font: fontBytes.toString('base64'),
      family: FAMILY,
      font: FONT,
      cases: corpus,
      conversionInputs,
    });
    if (!observed.fontLoaded) throw new Error(`Roboto did not load in viewport ${viewport.id}.`);
    if (requests.length) throw new Error(`Unexpected request while measuring text: ${requests.join(', ')}`);
    if (JSON.stringify(observed.stateBefore) !== JSON.stringify(observed.stateAfter)) {
      throw new Error(`measureText changed canvas state in viewport ${viewport.id}.`);
    }

    const coverage = new Map(corpus.map(item => [item.id, fontCoverage(item.text)]));
    viewports.push({
      id: viewport.id,
      viewportCssPixels: {width: viewport.width, height: viewport.height, deviceScaleFactor: 1, isMobile: viewport.isMobile, hasTouch: viewport.hasTouch},
      fontLoaded: observed.fontLoaded,
      resolvedFont: observed.resolvedFont,
      fontKerning: observed.fontKerning,
      cases: observed.measurements.map(item => ({...item, fontCoverage: coverage.get(item.id)})),
      conversions: observed.conversions,
      drawOptionalWidths: observed.drawOptionalWidths,
      readonly: observed.readonly,
      contextState: {before: observed.stateBefore, after: observed.stateAfter},
      externalRequests: requests,
    });
    await context.close();
  }

  const fixture = {
    schemaVersion: 1,
    capturedBy: 'apps/android/tool/parity/capture_document_canvas_text_web.mjs',
    browser: {name: 'Chromium', version: browser.version(), executable: basename(requireTestBrowserExecutable())},
    font: {
      family: FAMILY,
      font: FONT,
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
      coverageNote: 'Coverage is checked from the pinned font cmap. This file contains Latin, Greek, and Cyrillic inputs used below; Hebrew and Arabic are recorded as missing-fixture-font cases. Chromium fallback widths are captured as observations, not as portable same-font expectations.',
    },
    corpus: corpus.map(item => ({id: item.id, text: item.text, direction: item.direction || 'ltr'})),
    viewports,
  };
  const output = new URL('../../../../packages/pirc_render/test/fixtures/parity/document-canvas-text-chromium153.json', import.meta.url);
  writeFileSync(output, JSON.stringify(fixture) + '\n');
  console.log(JSON.stringify({output: fileURLToPath(output), browserVersion: fixture.browser.version, fontSha256, viewportCount: viewports.length, caseCount: corpus.length, requestCount: viewports.reduce((sum, item) => sum + item.externalRequests.length, 0)}));
} finally {
  await browser?.close();
}
