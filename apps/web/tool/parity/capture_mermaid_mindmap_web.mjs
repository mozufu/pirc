import { requireTestBrowserExecutable } from '../../../../scripts/e2e/test_browser.mjs';
// node apps/web/tool/parity/capture_mermaid_mindmap_web.mjs
// Captures actual pinned Markdown-rendered Mermaid mindmap SVG and COSE positions.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdir, readFile, realpath, writeFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { resolve } from 'node:path';
import { createServer } from '../../node_modules/vite/dist/node/index.js';
import { format as formatWithPrettier, resolveConfig as resolvePrettierConfig } from 'prettier';

const root = resolve(import.meta.dirname, '../../../..');
const fixturePath = resolve(root, 'fixtures/mobile-parity/mermaid-mindmap.json');
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

const outputDir = resolve(root, 'apps/web/build/parity/mermaid-mindmap-web');
await mkdir(outputDir, { recursive: true });
const server = await createServer({
  cacheDir: resolve(outputDir, 'vite-cache'),
  root: resolve(root, 'apps/web'),
  configFile: resolve(root, 'apps/web/vite.config.ts'),
  server: {
    host: '127.0.0.1',
    port: 18937,
    strictPort: true,
    fs: { allow: [root, await realpath(resolve(root, 'node_modules'))] },
  },
  plugins: [
    {
      name: 'mermaid-mindmap-parity-fixture',
      configureServer(vite) {
        vite.middlewares.use('/mindmap-fixture.json', (_, res) => {
          res.setHeader('Content-Type', 'application/json');
          res.end(JSON.stringify(fixture));
        });
        vite.middlewares.use('/mindmap.html', async (_, res, next) => {
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

              const fixture = await (await fetch('/mindmap-fixture.json')).json();
              const root = document.querySelector('#fixture');
              let action;
              const box = (element, svg) => {
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
              const serializable = (value) => JSON.parse(JSON.stringify(value, (_key, item) =>
                typeof item === 'number' && !Number.isFinite(item) ? String(item) : item));
              const fields = {
                svg: ['width', 'height', 'viewBox', 'preserveAspectRatio', 'role', 'aria-label'],
                g: ['id', 'class', 'transform', 'fill', 'stroke', 'stroke-width'],
                text: ['x', 'y', 'dx', 'dy', 'transform', 'fill', 'stroke', 'font-size', 'font-family', 'font-weight', 'text-anchor', 'dominant-baseline'],
                tspan: ['x', 'y', 'dx', 'dy', 'transform', 'fill', 'stroke', 'font-size', 'font-family', 'font-weight', 'text-anchor', 'dominant-baseline'],
                rect: ['x', 'y', 'width', 'height', 'rx', 'ry', 'transform', 'fill', 'stroke', 'stroke-width'],
                circle: ['cx', 'cy', 'r', 'transform', 'fill', 'stroke', 'stroke-width'],
                line: ['x1', 'x2', 'y1', 'y2', 'transform', 'stroke', 'stroke-width'],
                path: ['d', 'transform', 'fill', 'stroke', 'stroke-width'],
                polygon: ['points', 'transform', 'fill', 'stroke', 'stroke-width'],
                polyline: ['points', 'transform', 'fill', 'stroke', 'stroke-width'],
                ellipse: ['cx', 'cy', 'rx', 'ry', 'transform', 'fill', 'stroke', 'stroke-width'],
              };
              const svgElement = (element) => {
                const style = getComputedStyle(element);
                const tag = element.tagName.toLowerCase();
                const isText = tag === 'text' || tag === 'tspan';
                const computed = {
                  fill: style.fill, stroke: style.stroke, strokeWidth: style.strokeWidth,
                  opacity: style.opacity, fillOpacity: style.fillOpacity, strokeOpacity: style.strokeOpacity,
                };
                if (isText) Object.assign(computed, {
                  fontFamily: style.fontFamily, fontSize: style.fontSize, fontWeight: style.fontWeight,
                  lineHeight: style.lineHeight, textAnchor: style.textAnchor,
                  dominantBaseline: style.dominantBaseline,
                });
                const row = {
                  tag,
                  id: element.getAttribute('id')?.replace(/.*-(node_[0-9]+)$/, '$1') || null,
                  class: element.getAttribute('class'),
                  ...(isText ? { text: element.textContent } : {}),
                  attrs: attrs(element, fields[tag] || ['transform', 'fill', 'stroke', 'stroke-width']),
                  computed, userBBox: box(element, true), box: box(element, false),
                };
                if (isText) {
                  try { row.computedTextLength = element.getComputedTextLength(); }
                  catch { row.computedTextLength = null; }
                }
                return row;
              };
              const applyHtmlTextScale = (scale) => {
                if (scale === 1) return;
                const svgDefaults = [...document.querySelectorAll('#fixture svg')]
                  .map((node) => [node, getComputedStyle(node).fontSize, getComputedStyle(node).lineHeight]);
                const svgTextDefaults = [...document.querySelectorAll('#fixture svg text, #fixture svg tspan')]
                  .map((node) => [node, getComputedStyle(node).fontSize, getComputedStyle(node).lineHeight]);
                // Snapshot every HTML font before writing; otherwise inherited children get scaled twice.
                const htmlDefaults = [...document.querySelectorAll('#fixture, #fixture *')]
                  .filter((node) => node instanceof HTMLElement && !node.closest('svg'))
                  .map((node) => [node, parseFloat(getComputedStyle(node).fontSize), getComputedStyle(node).lineHeight]);
                for (const [node, size, line] of htmlDefaults) {
                  node.style.setProperty('font-size', size * scale + 'px', 'important');
                  if (line !== 'normal') node.style.setProperty('line-height', parseFloat(line) * scale + 'px', 'important');
                }
                for (const [node, size, line] of svgDefaults.concat(svgTextDefaults)) {
                  node.style.setProperty('font-size', size, 'important');
                  if (line !== 'normal') node.style.setProperty('line-height', line, 'important');
                }
              };
              const treeNode = (node) => ({
                id: node.id, nodeId: node.nodeId, descr: node.descr, level: node.level,
                type: node.type, shape: node.shape, width: node.width, height: node.height,
                padding: node.padding, section: node.section, isRoot: node.isRoot,
                children: (node.children || []).map(treeNode),
              });
              const waitForDiagram = async (block) => {
                for (let i = 0; i < 600; i++) {
                  if (block.dataset.rendered === 'ok' || block.dataset.rendered === 'error') return;
                  await new Promise((resolve) => setTimeout(resolve, 10));
                }
                throw new Error('Timed out waiting for Mermaid: ' + block.textContent.slice(0, 100));
              };
              window.captureMindmapCase = async (id, textScale) => {
                const item = fixture.cases.find((candidate) => candidate.id === id);
                if (!item) throw new Error('Unknown mindmap case: ' + id);
                root.style.removeProperty('font-size');
                root.style.removeProperty('line-height');
                const html = renderMarkdown(item.source);
                root.innerHTML = html;
                const block = root.querySelector('.mermaid-block');
                if (!block) throw new Error('Markdown did not create Mermaid block for ' + id);
                if (!action) action = enhanceMarkdown(root, { html, ready: true });
                else action.update({ html, ready: true });
                await waitForDiagram(block);
                applyHtmlTextScale(textScale);
                await document.fonts.ready;

                const source = block.querySelector('.mermaid-source code')?.textContent || null;
                const figure = block.querySelector('.mermaid-figure');
                const svg = figure?.querySelector('svg');
                const blockStyle = getComputedStyle(block);
                const figureStyle = figure ? getComputedStyle(figure) : null;
                const svgStyle = svg ? getComputedStyle(svg) : null;
                const result = {
                  id, textScale, status: block.dataset.rendered || 'missing', source,
                  errorText: block.querySelector('.mermaid-error')?.textContent || null,
                  html: {
                    block: { box: box(block, false), fontFamily: blockStyle.fontFamily,
                      fontSize: blockStyle.fontSize, lineHeight: blockStyle.lineHeight,
                      color: blockStyle.color, backgroundColor: blockStyle.backgroundColor },
                    figure: figure ? { box: box(figure, false), fontFamily: figureStyle.fontFamily,
                      fontSize: figureStyle.fontSize, lineHeight: figureStyle.lineHeight,
                      color: figureStyle.color, backgroundColor: figureStyle.backgroundColor } : null,
                  },
                  svg: svg ? {
                    attrs: attrs(svg, fields.svg), box: box(svg, false), userBBox: box(svg, true),
                    computed: { fontFamily: svgStyle.fontFamily, fontSize: svgStyle.fontSize,
                      lineHeight: svgStyle.lineHeight, width: svgStyle.width, height: svgStyle.height,
                      maxWidth: svgStyle.maxWidth, color: svgStyle.color,
                      backgroundColor: svgStyle.backgroundColor },
                    nodes: [...svg.querySelectorAll('g.mindmap-node')].map((node) => {
                      const nodeBox = box(node, false);
                      return {
                      id: node.id.slice(node.id.lastIndexOf('-') + 1),
                      class: node.getAttribute('class'), transform: node.getAttribute('transform'),
                      label: node.querySelector('.mindmap-node-label')?.textContent
                        || node.querySelector('text')?.textContent || node.textContent,
                      box: nodeBox, userBBox: box(node, true),
                      shapes: [...node.querySelectorAll('rect,circle,path,polygon,ellipse')].map(svgElement),
                      texts: [...node.querySelectorAll('text,tspan')].map(svgElement),
                      htmlLabels: [...node.querySelectorAll('foreignObject *')]
                        .filter((element) => element instanceof HTMLElement).map((element) => {
                          const style = getComputedStyle(element);
                          return { tag: element.tagName.toLowerCase(),
                            text: element.childElementCount === 0 ? element.textContent : null,
                            class: element.getAttribute('class'),
                            box: box(element, false),
                            relativeBox: (() => {
                              const labelBox = box(element, false);
                              const inverse = node.getScreenCTM()?.inverse();
                              if (!labelBox || !inverse) return null;
                              const topLeft = new DOMPoint(labelBox.x, labelBox.y).matrixTransform(inverse);
                              const bottomRight = new DOMPoint(
                                labelBox.x + labelBox.width, labelBox.y + labelBox.height,
                              ).matrixTransform(inverse);
                              return {
                                x: topLeft.x, y: topLeft.y,
                                width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y,
                              };
                            })(),
                            computed: { fontFamily: style.fontFamily, fontSize: style.fontSize,
                              fontWeight: style.fontWeight, lineHeight: style.lineHeight,
                              color: style.color, backgroundColor: style.backgroundColor,
                              margin: style.margin, padding: style.padding } };
                        }),
                      };
                    }),
                    edges: [...svg.querySelectorAll('g.edgePaths path, g.edgePath path, path.edge')].map(svgElement),
                    texts: [...svg.querySelectorAll('text,tspan')].map(svgElement),
                    shapes: [...svg.querySelectorAll('rect,circle,line,path,polygon,polyline,ellipse')].map(svgElement),
                  } : null,
                  api: null, apiError: null,
                };
                if (result.status === 'ok' && svg) {
                  try {
                    const diagram = await mermaid.mermaidAPI.getDiagramFromText(source);
                    const data = diagram.db.getData();
                    const config = data.config || {};
                    result.api = serializable({
                      diagramType: diagram.type,
                      config: { layout: config.layout, mindmap: config.mindmap, look: config.look,
                        theme: config.theme, fontFamily: config.fontFamily, fontSize: config.fontSize,
                        themeVariables: Object.fromEntries(Object.entries(config.themeVariables || {})
                          .filter(([key]) => /^(git(?:BranchLabel)?|cScale|cScaleLabel|cScaleInv)[0-9]+$/.test(key))) },
                      direction: data.direction, nodeSpacing: data.nodeSpacing, rankSpacing: data.rankSpacing,
                      nodes: data.nodes.map((node) => ({
                        id: node.id, domId: node.domId, label: node.label, shape: node.shape,
                        level: node.level, width: node.width, height: node.height, padding: node.padding,
                        cssClasses: node.cssClasses, section: node.section, isRoot: node.isRoot,
                      })),
                      edges: data.edges.map((edge) => ({
                        id: edge.id, start: edge.start, end: edge.end,
                        depth: edge.depth, section: edge.section, classes: edge.classes,
                      })),
                      tree: treeNode(diagram.db.getMindmap()),
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
            res.end(await vite.transformIndexHtml('/mindmap.html', html));
          } catch (error) {
            next(error);
          }
        });
      },
    },
  ],
});

const themes = {};
const parsedCases = {};
const geometryCatalog = {};
const geometryIntern = new Map();
const geometryVariantCounts = new Map();
let browser;
try {
  await server.listen();
  browser = await chromium.launch({
    executablePath: requireTestBrowserExecutable(),
    headless: true,
  });
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
          if (response.status() >= 400)
            badResponses.push(String(response.status()) + ' ' + response.url());
        });
        try {
          await page.goto('http://127.0.0.1:18937/mindmap.html');
          await page.waitForFunction(() => window.fixtureReady);
          const caseRows = [];
          for (const item of fixture.cases) {
            const errorsBefore = consoleErrors.length;
            const result = await page.evaluate(
              ({ id, scale }) => window.captureMindmapCase(id, scale),
              {
                id: item.id,
                scale: textScale,
              },
            );
            result.consoleErrors = consoleErrors.slice(errorsBefore);
            result.pageErrors = [...pageErrors];
            const expectedStatus = item.expectedStatus || 'ok';
            assert.equal(
              result.status,
              expectedStatus,
              'Unexpected status for ' +
                item.id +
                ' at ' +
                width +
                '/' +
                colorScheme +
                '/' +
                textScale +
                ': ' +
                result.errorText,
            );
            if (expectedStatus === 'error') {
              assert.ok(result.errorText, 'Expected actual Mermaid error for ' + item.id);
            } else {
              assert.ok(result.svg, 'Missing SVG for ' + item.id);
              assert.ok(result.svg.nodes.length, 'No rendered mindmap nodes for ' + item.id);
              assert.ok(
                result.svg.nodes.some(
                  (node) => node.label || node.htmlLabels.length || node.texts.length,
                ),
                'No rendered labels for ' + item.id,
              );
              assert.ok(
                result.api,
                'Missing Mermaid parser/DB data for ' + item.id + ': ' + result.apiError,
              );
              assert.equal(result.api.diagramType, 'mindmap');
              assert.equal(result.apiError, null);
              assert.equal(
                result.pageErrors.length,
                0,
                'Page error for ' + item.id + ': ' + result.pageErrors.join('\n'),
              );
              assert.equal(
                result.consoleErrors.length,
                0,
                'Console error for ' + item.id + ': ' + result.consoleErrors.join('\n'),
              );
            }
            assert.equal(badResponses.length, 0, badResponses.join('\n'));

            if (width === 390 && textScale === 1) {
              parsedCases[item.id] ||= {};
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
              const observed = result.svg;
              const omitViewportBox = ({ box: _box, ...node }) => node;
              const sharedGeometry = {
                attrs: observed.attrs,
                userBBox: observed.userBBox,
                computed: {
                  fontFamily: observed.computed.fontFamily,
                  fontSize: observed.computed.fontSize,
                  lineHeight: observed.computed.lineHeight,
                  color: observed.computed.color,
                  backgroundColor: observed.computed.backgroundColor,
                },
                nodes: observed.nodes.map(({ box: _box, htmlLabels, shapes, texts, ...node }) => ({
                  ...node,
                  shapes: shapes.map(omitViewportBox),
                  texts: texts.map(omitViewportBox),
                  htmlLabels: htmlLabels.map(omitViewportBox),
                })),
                edges: observed.edges.map(omitViewportBox),
                texts: observed.texts.map(omitViewportBox),
                shapes: observed.shapes.map(omitViewportBox),
              };
              const canonicalGeometry = JSON.stringify(sharedGeometry);
              const baseId = item.id + '-' + colorScheme;
              const internKey = baseId + '\u0000' + canonicalGeometry;
              let geometryId = geometryIntern.get(internKey);
              if (!geometryId) {
                const variant = (geometryVariantCounts.get(baseId) || 0) + 1;
                geometryVariantCounts.set(baseId, variant);
                geometryId = variant === 1 ? baseId : baseId + '-variant-' + variant;
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
                attrs: observed.attrs,
                box: observed.box,
                userBBox: observed.userBBox,
                computed: observed.computed,
                nodeBoxes: observed.nodes.map((node) => ({
                  id: node.id,
                  box: node.box,
                  userBBox: node.userBBox,
                })),
                labelBoxes: observed.nodes.map((node) => ({
                  id: node.id,
                  labels: node.htmlLabels.map((label) => label.box),
                })),
                edgeBoxes: observed.edges.map((node) => node.box),
                textBoxes: observed.texts.map((node) => node.box),
                shapeBoxes: observed.shapes.map((node) => node.box),
              };
            }
            delete result.source;
            delete result.errorText;
            delete result.api;
            delete result.apiError;
            delete result.consoleErrors;
            delete result.pageErrors;
            caseRows.push(result);
            await page.screenshot({
              path: resolve(
                outputDir,
                item.id + '-' + width + '-' + colorScheme + '-scale' + textScale + '.png',
              ),
              fullPage: true,
            });
          }
          await page.evaluate(() => window.destroyMarkdownEnhancer?.());
          scaleRows.push({ textScale, cases: caseRows });
        } finally {
          await page.close();
        }
      }
      widthRows.push({ width, scales: scaleRows });
    }
    themes[colorScheme] = { widths: widthRows };
  }

  // Repeat the real renderer and enhancer three times at one fixed configuration.
  const repeatPage = await browser.newPage({
    viewport: { width: 390, height: fixture.height },
    deviceScaleFactor: fixture.deviceScaleFactor,
    isMobile: true,
    hasTouch: true,
    colorScheme: 'light',
  });
  await repeatPage.goto('http://127.0.0.1:18937/mindmap.html');
  await repeatPage.waitForFunction(() => window.fixtureReady);
  const repeated = [];
  for (let run = 0; run < 3; run++) {
    const capture = await repeatPage.evaluate(() =>
      window.captureMindmapCase('mindmap-basic-tree', 1),
    );
    assert.equal(capture.status, 'ok');
    repeated.push({
      run: run + 1,
      positions: capture.svg.nodes.map((node) => ({
        id: node.id,
        label: node.label,
        center: { x: node.box.x + node.box.width / 2, y: node.box.y + node.box.height / 2 },
        box: node.box,
        transform: node.transform,
      })),
      dbNodeIds: capture.api.nodes.map((node) => node.id),
    });
  }
  await repeatPage.close();
  const firstPositions = new Map(repeated[0].positions.map((node) => [node.id, node.center]));
  let maxCenterDelta = 0;
  for (const run of repeated.slice(1)) {
    for (const node of run.positions) {
      const first = firstPositions.get(node.id);
      if (!first) continue;
      maxCenterDelta = Math.max(
        maxCenterDelta,
        Math.hypot(node.center.x - first.x, node.center.y - first.y),
      );
    }
  }

  const resultDocument = {
    fixture: fixture.id,
    reference: revision,
    mermaidVersion: mermaidPackage.version,
    browser: {
      executable: requireTestBrowserExecutable(),
      launch: { headless: true },
      pointer:
        'Playwright mobile emulation with hasTouch=true and isMobile=true; deviceScaleFactor=1.',
    },
    scalePolicy:
      'Each textScale snapshots all HTML computed font sizes before changing any ancestor/child styles, then multiplies HTML text and line height. Mermaid SVG root and SVG text/tspan styles remain fixed at rendered baseline.',
    layoutPolicy:
      'Actual pinned Mermaid renderer and registered cose-bilkent plugin; no seed or positions injected. The basic tree is enhanced three times in one page to observe repeatability.',
    pinnedLayoutDefaults: {
      name: 'cose-bilkent',
      quality: 'proof',
      styleEnabled: false,
      animate: false,
      source: 'apps/web/node_modules/mermaid/dist/chunks/mermaid.core/cose-bilkent-JH36ORCC.mjs',
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
      expectedStatus: expectedStatus || 'ok',
    })),
    parsedCases,
    repeatability: {
      caseId: 'mindmap-basic-tree',
      configuration: {
        width: 390,
        height: fixture.height,
        theme: 'light',
        textScale: 1,
        runs: repeated.length,
      },
      maxNodeCenterDeltaCssPx: maxCenterDelta,
      stableWithin001CssPx: maxCenterDelta <= 0.01,
      runs: repeated,
      note: 'Three sequential Markdown renderer/enhancer runs in one page; this does not assert a fixed seed or guarantee identical output across processes, browsers, or future versions.',
    },
    geometryCatalog,
    themes,
  };
  const expectedPath = resolve(root, 'fixtures/mobile-parity/mermaid-mindmap-expected.json');
  const prettierConfig = await resolvePrettierConfig(expectedPath);
  const json = await formatWithPrettier(JSON.stringify(resultDocument, null, 2), {
    ...prettierConfig,
    filepath: expectedPath,
    parser: 'json',
  });
  await writeFile(resolve(outputDir, 'mermaid-mindmap-web.json'), json);
  await writeFile(expectedPath, json);
  console.log(outputDir);
} finally {
  await browser?.close();
  await server.close();
}
