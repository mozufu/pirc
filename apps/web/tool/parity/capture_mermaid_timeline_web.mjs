import { requireTestBrowserExecutable } from '../../../../scripts/e2e/test_browser.mjs';
// node apps/web/tool/parity/capture_mermaid_timeline_web.mjs
// Captures actual pinned Markdown-rendered Mermaid timeline SVGs.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdir, readFile, realpath, writeFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { resolve } from 'node:path';
import { createServer } from '../../node_modules/vite/dist/node/index.js';
import { format as formatWithPrettier, resolveConfig as resolvePrettierConfig } from 'prettier';

const root = resolve(import.meta.dirname, '../../../..');
const fixturePath = resolve(root, 'fixtures/mobile-parity/mermaid-timeline.json');
const fixture = JSON.parse(await readFile(fixturePath, 'utf8'));
const revision = fixture.webRevision;
assert.equal(revision, 'bd3d90981271e1f93cf3d1d1a5bbf9b61136b74c');
assert.equal(fixture.mermaidVersion, '11.17.2');
assert.deepEqual(fixture.widths, [390, 650, 651, 768, 860, 861, 1024]);
assert.deepEqual(fixture.themes, ['light', 'dark']);
assert.deepEqual(fixture.textScales, [1, 2]);
assert.equal(fixture.deviceScaleFactor, 1);
execFileSync('git', ['diff', '--exit-code', revision, '--', 'apps/web', ':!apps/web/tool'], {
  cwd: root,
});

const require = createRequire(resolve(root, 'apps/gateway/package.json'));
const { chromium } = require('playwright-core');
const mermaidPackage = JSON.parse(
  await readFile(resolve(root, 'apps/web/node_modules/mermaid/package.json'), 'utf8'),
);
assert.equal(mermaidPackage.version, fixture.mermaidVersion);

const outputDir = resolve(root, 'apps/web/build/parity/mermaid-timeline-web');
await mkdir(outputDir, { recursive: true });
const fixtureSource = JSON.stringify(fixture).replaceAll('<', '\\u003c');
const server = await createServer({
  cacheDir: resolve(outputDir, 'vite-cache'),
  root: resolve(root, 'apps/web'),
  configFile: resolve(root, 'apps/web/vite.config.ts'),
  server: {
    host: '127.0.0.1',
    port: 18940,
    strictPort: true,
    fs: { allow: [root, await realpath(resolve(root, 'node_modules'))] },
  },
  plugins: [
    {
      name: 'mermaid-timeline-parity-fixture',
      configureServer(vite) {
        vite.middlewares.use('/timeline.html', async (_, res, next) => {
          try {
            const html = `<!doctype html><html><head>
              <link rel="icon" href="data:,">
              <meta name="viewport" content="width=device-width,initial-scale=1">
              <style>
                body{overflow:auto!important}
                #fixture{padding:16px;font-family:Arial;font-size:15px;line-height:1.65;--font-mono:Menlo,monospace}
                .mermaid-case{margin:0}
              </style>
            </head><body><main id="fixture" class="markdown"></main>
              <script type="module">
                import '/src/app.css';
                import '/src/markdown.css';
                import { preloadRenderers, renderMarkdown, enhanceMarkdown } from '/src/lib/markdown.ts';
                import mermaid from 'mermaid';

                const fixture = ${fixtureSource};
                const root = document.querySelector('#fixture');
                let action;
                const waitForDiagram = async (block) => {
                  for (let i = 0; i < 300; i++) {
                    if (block.dataset.rendered === 'ok' || block.dataset.rendered === 'error') return;
                    await new Promise((resolve) => setTimeout(resolve, 10));
                  }
                  throw new Error('Timed out waiting for Mermaid: ' + block.textContent.slice(0, 120));
                };
                const box = (element, svg = false) => {
                  if (!element) return null;
                  let b;
                  try { b = svg ? element.getBBox() : element.getBoundingClientRect(); }
                  catch { return null; }
                  return { x: b.x, y: b.y, width: b.width, height: b.height };
                };
                const attrs = (element, names) => Object.fromEntries(
                  names.flatMap((name) => {
                    const value = element.getAttribute(name);
                    return value === null ? [] : [[name, value]];
                  }),
                );
                const svgNode = (element) => {
                  const style = getComputedStyle(element);
                  const isText = element.matches('text,tspan');
                  const tag = element.tagName.toLowerCase();
                  const fieldsByTag = {
                    text: ['x', 'y', 'dx', 'dy', 'transform', 'fill', 'stroke', 'font-size', 'font-family', 'font-weight', 'text-anchor', 'dominant-baseline'],
                    tspan: ['x', 'y', 'dx', 'dy', 'transform', 'fill', 'stroke', 'font-size', 'font-family', 'font-weight', 'text-anchor', 'dominant-baseline'],
                    rect: ['x', 'y', 'width', 'height', 'rx', 'ry', 'transform', 'fill', 'stroke', 'stroke-width'],
                    circle: ['cx', 'cy', 'r', 'transform', 'fill', 'stroke', 'stroke-width'],
                    line: ['x1', 'x2', 'y1', 'y2', 'transform', 'stroke', 'stroke-width', 'marker-end', 'stroke-dasharray'],
                    path: ['d', 'transform', 'fill', 'stroke', 'stroke-width'],
                    polygon: ['points', 'transform', 'fill', 'stroke', 'stroke-width'],
                    polyline: ['points', 'transform', 'fill', 'stroke', 'stroke-width'],
                    ellipse: ['cx', 'cy', 'rx', 'ry', 'transform', 'fill', 'stroke', 'stroke-width'],
                  };
                  const fields = fieldsByTag[tag] ?? ['transform', 'fill', 'stroke', 'stroke-width'];
                  const computed = isText ? {
                    fill: style.fill,
                    stroke: style.stroke,
                    strokeWidth: style.strokeWidth,
                    fontFamily: style.fontFamily,
                    fontSize: style.fontSize,
                    fontWeight: style.fontWeight,
                    lineHeight: style.lineHeight,
                    letterSpacing: style.letterSpacing,
                    textAnchor: style.textAnchor,
                    dominantBaseline: style.dominantBaseline,
                  } : {
                    fill: style.fill,
                    stroke: style.stroke,
                    strokeWidth: style.strokeWidth,
                    opacity: style.opacity,
                    fillOpacity: style.fillOpacity,
                    strokeOpacity: style.strokeOpacity,
                  };
                  const result = {
                    tag,
                    ...(element.getAttribute('class') ? { class: element.getAttribute('class') } : {}),
                    ...(element.getAttribute('id') ? { id: element.getAttribute('id') } : {}),
                    ...(isText ? { text: element.textContent } : {}),
                    attrs: attrs(element, fields),
                    computed,
                    bbox: box(element, true),
                    box: box(element),
                  };
                  if (isText) {
                    try { result.computedTextLength = element.getComputedTextLength(); }
                    catch { result.computedTextLength = null; }
                  }
                  return result;
                };
                const serializable = (value) => JSON.parse(JSON.stringify(value, (_key, item) =>
                  typeof item === 'number' && !Number.isFinite(item) ? String(item) : item));
                const applyHtmlTextScale = (scale) => {
                  if (scale === 1) return;
                  const svgDefaults = [...document.querySelectorAll('#fixture svg')]
                    .map((svg) => {
                      const style = getComputedStyle(svg);
                      return [svg, style.fontSize, style.lineHeight];
                    });
                  const svgTextDefaults = [...document.querySelectorAll('#fixture svg text, #fixture svg tspan')]
                    .map((node) => {
                      const style = getComputedStyle(node);
                      return [node, style.fontSize, style.lineHeight];
                    });
                  const entries = [...document.querySelectorAll('#fixture, #fixture *')]
                    .filter((node) => node instanceof HTMLElement && !node.closest('svg'))
                    .map((node) => {
                      const style = getComputedStyle(node);
                      return [node, parseFloat(style.fontSize), style.lineHeight];
                    });
                  for (const [node, size, line] of entries) {
                    node.style.setProperty('font-size', size * scale + 'px', 'important');
                    if (line !== 'normal') {
                      node.style.setProperty('line-height', parseFloat(line) * scale + 'px', 'important');
                    }
                  }
                  for (const [svg, fontSize, lineHeight] of svgDefaults) {
                    svg.style.setProperty('font-size', fontSize, 'important');
                    if (lineHeight !== 'normal') svg.style.setProperty('line-height', lineHeight, 'important');
                  }
                  for (const [node, fontSize, lineHeight] of svgTextDefaults) {
                    node.style.setProperty('font-size', fontSize, 'important');
                    if (lineHeight !== 'normal') node.style.setProperty('line-height', lineHeight, 'important');
                  }
                };
                window.captureTimelineCase = async (id, textScale) => {
                  const item = fixture.cases.find((candidate) => candidate.id === id);
                  if (!item) throw new Error('Unknown timeline case: ' + id);
                  root.style.removeProperty('font-size');
                  root.style.removeProperty('line-height');
                  const html = renderMarkdown(item.source);
                  root.innerHTML = html;
                  const block = root.querySelector('.mermaid-block');
                  if (!block) throw new Error('Markdown did not create a Mermaid block for ' + id);
                  if (!action) action = enhanceMarkdown(root, { html, ready: true });
                  else action.update({ html, ready: true });
                  await waitForDiagram(block);
                  applyHtmlTextScale(textScale);
                  await document.fonts.ready;

                  const source = block.querySelector('.mermaid-source code')?.textContent ?? null;
                  const figure = block.querySelector('.mermaid-figure');
                  const svg = figure?.querySelector('svg');
                  const blockStyle = getComputedStyle(block);
                  const figureStyle = figure ? getComputedStyle(figure) : null;
                  const svgStyle = svg ? getComputedStyle(svg) : null;
                  const textElements = svg ? [...svg.querySelectorAll('text,tspan')] : [];
                  const shapeElements = svg ? [...svg.querySelectorAll('rect,circle,line,path,polygon,polyline,ellipse')] : [];
                  const textIndices = new Map(textElements.map((node, index) => [node, index]));
                  const shapeIndices = new Map(shapeElements.map((node, index) => [node, index]));
                  const result = {
                    id,
                    kind: item.kind,
                    textScale,
                    status: block.dataset.rendered ?? 'missing',
                    source,
                    errorText: block.querySelector('.mermaid-error')?.textContent ?? null,
                    accessibility: svg ? {
                      ariaLabel: svg.getAttribute('aria-label'),
                      role: svg.getAttribute('role'),
                      title: svg.querySelector(':scope > title')?.textContent ?? null,
                      desc: svg.querySelector(':scope > desc')?.textContent ?? null,
                    } : null,
                    html: {
                      block: {
                        box: box(block),
                        fontFamily: blockStyle.fontFamily,
                        fontSize: blockStyle.fontSize,
                        lineHeight: blockStyle.lineHeight,
                        color: blockStyle.color,
                        backgroundColor: blockStyle.backgroundColor,
                      },
                      figure: figure ? {
                        box: box(figure),
                        fontFamily: figureStyle.fontFamily,
                        fontSize: figureStyle.fontSize,
                        lineHeight: figureStyle.lineHeight,
                        color: figureStyle.color,
                        backgroundColor: figureStyle.backgroundColor,
                      } : null,
                    },
                    svg: svg ? {
                      attrs: attrs(svg, ['width', 'height', 'viewBox', 'preserveAspectRatio', 'role', 'aria-label']),
                      box: box(svg),
                      bbox: box(svg, true),
                      computed: {
                        fontFamily: svgStyle.fontFamily,
                        fontSize: svgStyle.fontSize,
                        lineHeight: svgStyle.lineHeight,
                        width: svgStyle.width,
                        height: svgStyle.height,
                        maxWidth: svgStyle.maxWidth,
                      },
                      timelineNodes: [...svg.querySelectorAll('g.timeline-node')].map((node) => ({
                        class: node.getAttribute('class'),
                        transform: node.getAttribute('transform'),
                        bbox: box(node, true),
                        box: box(node),
                        textIndices: [...node.querySelectorAll('text,tspan')].map((element) => textIndices.get(element)),
                        shapeIndices: [...node.querySelectorAll('rect,circle,path,polygon,polyline,ellipse')].map((element) => shapeIndices.get(element)),
                      })),
                      wrappers: [...svg.querySelectorAll('g.taskWrapper,g.eventWrapper')].map((node) => ({
                        class: node.getAttribute('class'),
                        transform: node.getAttribute('transform'),
                        bbox: box(node, true),
                        box: box(node),
                      })),
                      texts: textElements.map(svgNode),
                      shapes: shapeElements.map(svgNode),
                    } : null,
                    api: null,
                    apiError: null,
                  };
                  if (result.status === 'ok') {
                    try {
                      const diagram = await mermaid.mermaidAPI.getDiagramFromText(source);
                      const common = diagram.db.getCommonDb?.();
                      const config = mermaid.mermaidAPI.getConfig();
                      const timelineConfig = config.timeline ?? {};
                      const themeVariables = config.themeVariables ?? {};
                      const colorKeys = Object.keys(themeVariables).filter((key) =>
                        /^(cScale|git|lineColor|primary|secondary|tertiary|mainBkg|nodeBorder|textColor)/i.test(key),
                      );
                      result.api = serializable({
                        diagramType: diagram.type,
                        direction: diagram.db.getDirection?.() ?? null,
                        title: common?.getDiagramTitle?.() ?? null,
                        accTitle: common?.getAccTitle?.() ?? null,
                        accDescription: common?.getAccDescription?.() ?? null,
                        sections: diagram.db.getSections?.() ?? [],
                        // This is one getTasks call on a fresh getDiagramFromText DB.
                        tasks: diagram.db.getTasks?.() ?? [],
                        config: {
                          theme: config.theme,
                          fontSize: config.fontSize,
                          fontFamily: config.fontFamily,
                          taskFontSize: timelineConfig.taskFontSize,
                          taskFontFamily: timelineConfig.taskFontFamily,
                          timeline: {
                            leftMargin: timelineConfig.leftMargin,
                            width: timelineConfig.width,
                            height: timelineConfig.height,
                            padding: timelineConfig.padding,
                            useMaxWidth: timelineConfig.useMaxWidth,
                          },
                          themeVariables: Object.fromEntries(
                            colorKeys.map((key) => [key, themeVariables[key]]),
                          ),
                        },
                      });
                    } catch (error) {
                      result.apiError = error.stack || error.message;
                    }
                  }
                  return serializable(result);
                };
                await preloadRenderers();
                window.destroyMarkdownEnhancer = () => action?.destroy();
                window.fixtureReady = true;
              </script>
            </body></html>`;
            res.setHeader('Content-Type', 'text/html');
            res.end(await vite.transformIndexHtml('/timeline.html', html));
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
  const themes = {};
  const parsedCases = {};
  const geometryCatalog = {};
  const geometryIntern = new Map();
  const geometryVariantCounts = new Map();
  for (const colorScheme of fixture.themes) {
    const widthRows = [];
    for (const width of fixture.widths) {
      const scaleRows = [];
      for (const textScale of fixture.textScales) {
        const page = await browser.newPage({
          viewport: { width, height: fixture.height },
          deviceScaleFactor: fixture.deviceScaleFactor,
          isMobile: true,
          hasTouch: true,
          locale: 'en-US',
          timezoneId: 'UTC',
          colorScheme,
        });
        const pageErrors = [];
        const consoleErrors = [];
        const badResponses = [];
        page.on('pageerror', (error) => pageErrors.push(error.stack || error.message));
        page.on('console', (message) => {
          if (message.type() === 'error') consoleErrors.push(message.text());
        });
        page.on('response', (response) => {
          if (response.status() >= 400) badResponses.push(`${response.status()} ${response.url()}`);
        });
        try {
          await page.goto('http://127.0.0.1:18940/timeline.html');
          await page.waitForFunction(() => window.fixtureReady);
          const cdp = await page.context().newCDPSession(page);
          await cdp.send('DOM.enable');
          await cdp.send('CSS.enable');
          const caseRows = [];
          for (const item of fixture.cases) {
            const errorsBefore = consoleErrors.length;
            const result = await page.evaluate(
              ({ id, scale }) => window.captureTimelineCase(id, scale),
              { id: item.id, scale: textScale },
            );
            result.consoleErrors = consoleErrors.slice(errorsBefore);
            result.pageErrors = [...pageErrors];
            const expectedStatus = item.expectedStatus ?? 'ok';
            assert.equal(
              result.status,
              expectedStatus,
              `Unexpected status for ${item.id} at ${width}/${colorScheme}/${textScale}: ${result.errorText}`,
            );
            if (expectedStatus === 'error') {
              assert.ok(result.errorText, `Expected Mermaid error for ${item.id}`);
            } else {
              assert.ok(result.svg, `Missing SVG for ${item.id}`);
              assert.ok(result.svg.texts.length > 0, `No SVG text for ${item.id}`);
              assert.ok(result.svg.shapes.length > 0, `No SVG shapes for ${item.id}`);
              assert.equal(
                result.pageErrors.length,
                0,
                `Page error for ${item.id}: ${result.pageErrors.join('\n')}`,
              );
              assert.equal(
                result.consoleErrors.length,
                0,
                `Console error for ${item.id}: ${result.consoleErrors.join('\n')}`,
              );

              assert.ok(
                result.api,
                `No Mermaid timeline API data for ${item.id}: ${result.apiError}`,
              );
              assert.equal(
                result.api.diagramType,
                'timeline',
                `Unexpected diagram type for ${item.id}`,
              );
              assert.equal(
                result.api.direction,
                item.source.includes('timeline TD') ? 'TD' : 'LR',
                `Unexpected direction for ${item.id}`,
              );
              const root = await cdp.send('DOM.getDocument', { depth: -1, pierce: true });
              const svgQuery = await cdp.send('DOM.querySelector', {
                nodeId: root.root.nodeId,
                selector: '#fixture svg',
              });
              if (svgQuery.nodeId) {
                const textQuery = await cdp.send('DOM.querySelector', {
                  nodeId: svgQuery.nodeId,
                  selector: 'g.timeline-node text',
                });
                if (textQuery.nodeId) {
                  const fontInfo = await cdp.send('CSS.getPlatformFontsForNode', {
                    nodeId: textQuery.nodeId,
                  });
                  const firstNodeTextIndex = result.svg.timelineNodes[0]?.textIndices[0];
                  result.typefaceSource = {
                    selector: 'svg g.timeline-node text',
                    text: result.svg.texts[firstNodeTextIndex]?.text ?? null,
                    actualPlatformFonts: fontInfo.fonts,
                  };
                } else {
                  result.typefaceSource = {
                    selector: 'svg g.timeline-node text',
                    actualPlatformFonts: [],
                  };
                }
              }
              assert.equal(badResponses.length, 0, badResponses.join('\n'));
            }
            if (width === 390 && textScale === 1) {
              parsedCases[item.id] ??= {};
              parsedCases[item.id][colorScheme] = {
                status: result.status,
                errorText: result.errorText,
                api: result.api,
                apiError: result.apiError,
                consoleErrors: result.consoleErrors,
                pageErrors: result.pageErrors,
              };
            }
            if (result.svg) {
              const viewportSvg = result.svg;
              const sharedGeometry = {
                attrs: Object.fromEntries(
                  Object.entries(viewportSvg.attrs).filter(
                    ([name]) => !['role', 'aria-label'].includes(name),
                  ),
                ),
                bbox: viewportSvg.bbox,
                computed: {
                  fontFamily: viewportSvg.computed.fontFamily,
                  fontSize: viewportSvg.computed.fontSize,
                  lineHeight: viewportSvg.computed.lineHeight,
                  maxWidth: viewportSvg.computed.maxWidth,
                },
                timelineNodes: viewportSvg.timelineNodes.map(({ box: _box, ...node }) => node),
                wrappers: viewportSvg.wrappers.map(({ box: _box, ...node }) => node),
                texts: viewportSvg.texts.map(({ box: _box, ...node }) => node),
                shapes: viewportSvg.shapes.map(({ box: _box, ...node }) => node),
              };
              const canonicalGeometry = JSON.stringify(sharedGeometry);
              const baseId = `${item.id}-${colorScheme}`;
              const internKey = `${baseId}\\u0000${canonicalGeometry}`;
              let geometryId = geometryIntern.get(internKey);
              if (!geometryId) {
                const variant = (geometryVariantCounts.get(baseId) ?? 0) + 1;
                geometryVariantCounts.set(baseId, variant);
                geometryId = variant === 1 ? baseId : `${baseId}-variant-${variant}`;
                geometryIntern.set(internKey, geometryId);
                geometryCatalog[geometryId] = {
                  caseId: item.id,
                  theme: colorScheme,
                  firstObservedAt: { width, textScale },
                  shared: sharedGeometry,
                  otherObservations: [],
                };
              } else {
                geometryCatalog[geometryId].otherObservations.push({ width, textScale });
              }
              result.svg = {
                geometryId,
                box: viewportSvg.box,
                computed: viewportSvg.computed,
                textBoxes: viewportSvg.texts.map((node) => node.box),
                timelineNodeBoxes: viewportSvg.timelineNodes.map((node) => node.box),
                wrapperBoxes: viewportSvg.wrappers.map((node) => node.box),
                shapeBoxes: viewportSvg.shapes.map((node) => node.box),
              };
            }
            delete result.source;
            delete result.errorText;
            delete result.apiError;
            delete result.consoleErrors;
            delete result.pageErrors;
            delete result.api;
            caseRows.push(result);
            await page.screenshot({
              path: resolve(outputDir, `${item.id}-${width}-${colorScheme}-scale${textScale}.png`),
              fullPage: true,
            });
          }
          await page.evaluate(() => window.destroyMarkdownEnhancer?.());
          await cdp.detach();
          scaleRows.push({ textScale, cases: caseRows });
        } finally {
          await page.close();
        }
      }
      widthRows.push({ width, scales: scaleRows });
    }
    themes[colorScheme] = { widths: widthRows };
  }
  const resultDocument = {
    fixture: fixture.id,
    reference: revision,
    mermaidVersion: mermaidPackage.version,
    deviceScaleFactor: fixture.deviceScaleFactor,
    bodyFixture: fixture.body,
    scalePolicy:
      'At each textScale, snapshot all HTML element computed font sizes before changing any ancestor/child styles; multiply HTML text and line-height only. SVG root and SVG text/tspan font styles remain pinned to Mermaid-rendered baseline. CSS pixels, deviceScaleFactor 1.',
    sourceNotes: {
      rendererSwitch:
        'Pinned Mermaid timeline-definition dispatches DB direction TD to timelineRendererVertical; LR/default uses timelineRenderer.',
      orientationTokens:
        'Actual parser maps `timeline` and `timeline LR` to LR, `timeline TD` to TD.',
      layoutConfig:
        'The pinned API reports timeline.leftMargin=150, width=150, height=50, useMaxWidth=true; timeline.padding is unset, so setupGraphViewbox uses its 50px fallback.',
      viewBox:
        'Both renderers call setupGraphViewbox(svg, timeline.padding ?? 50, timeline.useMaxWidth ?? false) after drawing content.',
      nodeText:
        'Timeline node labels are SVG text. The API config reports fontSize=16 and taskFontSize=14, while Chrome measures the rendered SVG text at 13px. The source draw helper wraps by computed SVG text width; getComputedTextLength and each text/tspan getBBox are captured.',
      geometryMeasurements:
        'Final SVG viewBox attributes, post-draw SVG getBBox, drawn shape path/getBBox, and text/tspan getBBox are retained separately. Post-draw glyph bounds are not used to infer pre-sizing virtual node heights.',
      colors:
        'Section and task/event fills/strokes are Mermaid theme-derived class styles; exact rendered computed styles are stored with each SVG node.',
      typefaceSource:
        'CSS.getPlatformFontsForNode records the actual Chrome platform face used by a representative timeline-node SVG text label in each valid capture.',
    },
    matrix: {
      widths: fixture.widths,
      themes: fixture.themes,
      textScales: fixture.textScales,
      height: fixture.height,
    },
    cases: fixture.cases.map(({ id, kind, description, expectedStatus }) => ({
      id,
      kind,
      description,
      expectedStatus: expectedStatus ?? 'ok',
    })),
    parsedCases,
    geometryCatalog,
    themes,
  };
  const expectedPath = resolve(root, 'fixtures/mobile-parity/mermaid-timeline-expected.json');
  const prettierConfig = await resolvePrettierConfig(expectedPath);
  const json = await formatWithPrettier(JSON.stringify(resultDocument, null, 2), {
    ...prettierConfig,
    filepath: expectedPath,
    parser: 'json',
  });
  await writeFile(expectedPath, json);
  await writeFile(resolve(outputDir, 'mermaid-timeline-web.json'), json);
  console.log(outputDir);
} finally {
  await browser?.close();
  await server.close();
}
