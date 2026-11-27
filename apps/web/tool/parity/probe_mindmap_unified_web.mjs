import { requireTestBrowserExecutable } from '../../../../scripts/e2e/test_browser.mjs';
// Bounded Chrome probe of the actual Markdown -> Mermaid unified mindmap path.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdir, readFile, realpath, writeFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { resolve } from 'node:path';
import { createServer } from '../../node_modules/vite/dist/node/index.js';

const root = resolve(import.meta.dirname, '../../../..');
const revision = 'bd3d90981271e1f93cf3d1d1a5bbf9b61136b74c';
execFileSync('git', ['diff', '--exit-code', revision, '--', 'apps/web', ':!apps/web/tool'], {
  cwd: root,
});
const require = createRequire(resolve(root, 'apps/gateway/package.json'));
const { chromium } = require('playwright-core');
const mermaidPackage = JSON.parse(
  await readFile(resolve(root, 'apps/web/node_modules/mermaid/package.json'), 'utf8'),
);
assert.equal(mermaidPackage.version, '11.17.2');

const cases = [
  {
    id: 'baseline',
    source: 'mindmap\nroot((Root))\n  Account',
  },
  {
    id: 'icon-following-node',
    source: 'mindmap\nroot((Root))\n  Account\n  ::icon(fa fa-user)',
  },
  {
    id: 'label-literal-code',
    source: 'mindmap\nroot((Root))\n  Code `const x = 1`',
  },
  {
    id: 'built-in-disabled-class-line',
    source: 'mindmap\nroot((Root))\n  Account\n  :::disabled',
  },
  {
    id: 'built-in-disabled-circle',
    source: 'mindmap\nroot((Root))\n  Account((Account))\n  :::disabled',
  },
  {
    id: 'custom-class-line',
    source: 'mindmap\nroot((Root))\n  Account\n  :::probe-class',
  },
  {
    id: 'quoted-literal-link',
    source: 'mindmap\nroot((Root))\n  link["[docs](https://example.com)"]',
  },
  {
    id: 'quoted-html-color',
    source: 'mindmap\nroot((Root))\n  color["<span style=\'color:#c00000\'>red word</span>"]',
  },
  {
    id: 'quoted-rich-syntax',
    source: 'mindmap\nroot((Root))\n  rich["**Bold** *italic* ~~deleted~~ `code`"]',
  },
  {
    id: 'labels-with-code-link-html',
    source:
      'mindmap\nroot((Root))\n  Code `const x = 1`\n  Link [docs](https://example.com)\n  HTML <span style="color:#c00000">red word</span>',
  },
];

const outputDir = resolve(root, 'apps/web/build/parity/mindmap-unified-web-probe');
await mkdir(outputDir, { recursive: true });
const server = await createServer({
  cacheDir: resolve(outputDir, 'vite-cache'),
  root: resolve(root, 'apps/web'),
  configFile: resolve(root, 'apps/web/vite.config.ts'),
  server: {
    host: '127.0.0.1',
    port: 18938,
    strictPort: true,
    fs: { allow: [root, await realpath(resolve(root, 'node_modules'))] },
  },
  plugins: [
    {
      name: 'mindmap-unified-browser-probe',
      configureServer(vite) {
        vite.middlewares.use('/mindmap-unified-probe.html', async (_request, response, next) => {
          try {
            const html = `<!doctype html><html><head>
              <meta name="viewport" content="width=device-width,initial-scale=1">
              <link rel="icon" href="data:,">
              <style>
                body { margin: 0; padding: 0; }
                #fixture { padding: 16px; font: 15px/1.65 Arial, sans-serif; color: #222; }
                .probe-text { margin: 0 0 12px; }
                .mermaid-case { margin: 0; }
              </style>
            </head><body><main id="fixture" class="markdown"></main>
              <script type="module">
                import '/src/app.css';
                import '/src/markdown.css';
                import { preloadRenderers, renderMarkdown, enhanceMarkdown } from '/src/lib/markdown.ts';
                import mermaid from 'mermaid';

                const root = document.querySelector('#fixture');
                let action;
                const rectangle = (element, svg = false) => {
                  if (!element) return null;
                  try {
                    const rect = svg ? element.getBBox() : element.getBoundingClientRect();
                    return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
                  } catch { return null; }
                };
                const computed = (element) => {
                  const style = getComputedStyle(element);
                  return {
                    display: style.display, color: style.color, backgroundColor: style.backgroundColor,
                    fill: style.fill, stroke: style.stroke, strokeWidth: style.strokeWidth,
                    fontFamily: style.fontFamily, fontSize: style.fontSize,
                    fontWeight: style.fontWeight, fontStyle: style.fontStyle, lineHeight: style.lineHeight,
                    textDecoration: style.textDecoration, margin: style.margin, padding: style.padding,
                  };
                };
                const serializable = (value) => JSON.parse(JSON.stringify(value, (_key, item) =>
                  typeof item === 'number' && !Number.isFinite(item) ? String(item) : item));
                const waitFor = async (block) => {
                  for (let step = 0; step < 500; step++) {
                    if (block.dataset.rendered === 'ok' || block.dataset.rendered === 'error') return;
                    await new Promise((resolve) => setTimeout(resolve, 10));
                  }
                  throw new Error('Mermaid render timed out');
                };
                const shape = (element) => ({
                  tag: element.tagName.toLowerCase(),
                  attrs: Object.fromEntries([...element.attributes].map(({ name, value }) => [name, value])),
                  box: rectangle(element), userBox: rectangle(element, true), computed: computed(element),
                });
                window.runMindmapProbe = async ({ id, mermaidSource }) => {
                  action?.destroy();
                  const tick = String.fromCharCode(96);
                  const markdown = [
                    'Inline baseline: **bold**, ' + tick + 'const x = 1' + tick + ', [docs](https://example.com), and <span style="color:#c00000">red word</span>.',
                    '',
                    tick.repeat(3) + 'mermaid',
                    mermaidSource,
                    tick.repeat(3),
                  ].join(String.fromCharCode(10));
                  const html = renderMarkdown(markdown);
                  root.innerHTML = html;
                  action = enhanceMarkdown(root, { html, ready: true });
                  const block = root.querySelector('.mermaid-block');
                  if (!block) throw new Error('Markdown did not produce .mermaid-block');
                  await waitFor(block);
                  await document.fonts.ready;

                  const svg = block.querySelector('.mermaid-figure svg');
                  const labels = [...(svg?.querySelectorAll('g.mindmap-node') || [])].map((node) => ({
                    id: node.id,
                    class: node.getAttribute('class'),
                    transform: node.getAttribute('transform'),
                    textContent: node.textContent,
                    box: rectangle(node),
                    userBox: rectangle(node, true),
                    shapes: [...node.querySelectorAll('rect,circle,path,polygon,ellipse')].map(shape),
                    svgText: [...node.querySelectorAll('text,tspan')].map((element) => ({
                      tag: element.tagName.toLowerCase(), text: element.textContent,
                      box: rectangle(element), userBox: rectangle(element, true), computed: computed(element),
                    })),
                    htmlDescendants: [...node.querySelectorAll('foreignObject *')]
                      .filter((element) => element instanceof HTMLElement).map((element) => ({
                        tag: element.tagName.toLowerCase(), class: element.className,
                        text: element.childElementCount === 0 ? element.textContent : null,
                        html: element.innerHTML, box: rectangle(element), computed: computed(element),
                      })),
                  }));
                  const inline = {
                    paragraph: [...root.querySelectorAll('p')].find((element) =>
                      element.textContent.includes('Inline baseline')),
                  };
                  const inlineResult = inline.paragraph ? {
                    html: inline.paragraph.innerHTML,
                    box: rectangle(inline.paragraph), computed: computed(inline.paragraph),
                    elements: [...inline.paragraph.querySelectorAll('strong,code,a,span')].map((element) => ({
                      tag: element.tagName.toLowerCase(), text: element.textContent,
                      href: element.getAttribute('href'), style: element.getAttribute('style'),
                      box: rectangle(element), computed: computed(element),
                    })),
                  } : null;
                  let api = null;
                  let apiError = null;
                  if (block.dataset.rendered === 'ok') {
                    try {
                      const diagram = await mermaid.mermaidAPI.getDiagramFromText(mermaidSource);
                      const data = diagram.db.getData();
                      api = data.nodes.map((node) => ({
                        id: node.id, label: node.label, descr: node.descr, icon: node.icon ?? null,
                        class: node.class ?? null, cssClasses: node.cssClasses ?? null,
                        shape: node.shape, section: node.section,
                        width: node.width, height: node.height,
                      }));
                    } catch (error) { apiError = error.stack || error.message; }
                  }
                  return serializable({
                    id, status: block.dataset.rendered, errorText: block.querySelector('.mermaid-error')?.textContent || null,
                    source: block.querySelector('.mermaid-source code')?.textContent || null,
                    block: { box: rectangle(block), computed: computed(block) },
                    svg: svg ? {
                      attrs: Object.fromEntries([...svg.attributes].map(({ name, value }) => [name, value])),
                      box: rectangle(svg), userBox: rectangle(svg, true), nodes: labels,
                      icons: [...svg.querySelectorAll('i')].map((element) => ({
                        class: element.className, html: element.outerHTML, box: rectangle(element), computed: computed(element),
                      })),
                      html: [...svg.querySelectorAll('foreignObject')].map((element) => ({
                        html: element.innerHTML, box: rectangle(element), computed: computed(element),
                      })),
                    } : null,
                    markdownInline: inlineResult, api, apiError,
                  });
                };
                await preloadRenderers();
                window.probeReady = true;
              </script>
            </body></html>`;
            response.setHeader('Content-Type', 'text/html; charset=utf-8');
            response.end(await vite.transformIndexHtml('/mindmap-unified-probe.html', html));
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
  const page = await browser.newPage({
    viewport: { width: 390, height: 844 },
    deviceScaleFactor: 1,
    isMobile: true,
    hasTouch: true,
    colorScheme: 'light',
    locale: 'en-US',
  });
  const pageErrors = [];
  const consoleErrors = [];
  page.on('pageerror', (error) => pageErrors.push(error.stack || error.message));
  page.on('console', (message) => {
    if (message.type() === 'error') consoleErrors.push(message.text());
  });
  await page.goto('http://127.0.0.1:18938/mindmap-unified-probe.html');
  await page.waitForFunction(() => window.probeReady);

  const results = [];
  for (const item of cases) {
    const result = await page.evaluate(
      (entry) => window.runMindmapProbe({ id: entry.id, mermaidSource: entry.source }),
      item,
    );
    const screenshotPath = resolve(outputDir, `${item.id}.png`);
    await page.screenshot({ path: screenshotPath, fullPage: true });
    results.push({
      ...result,
      screenshotPath,
      pageErrors: [...pageErrors],
      consoleErrors: [...consoleErrors],
    });
  }
  const output = {
    metadata: {
      webRevision: revision,
      mermaidVersion: mermaidPackage.version,
      browser: 'Pinned Google Chrome executable; runtime version collected below',
      viewport: { width: 390, height: 844, deviceScaleFactor: 1, isMobile: true, hasTouch: true },
      colorScheme: 'light',
      method:
        'Actual renderMarkdown + enhanceMarkdown + Mermaid 11.17.2 unified renderer; no hand-built SVG or route interception.',
    },
    browserVersion: browser.version(),
    cases: results,
  };
  await writeFile(
    resolve(outputDir, 'mindmap-unified-web-probe.json'),
    JSON.stringify(output, null, 2) + '\n',
  );
  const portable = {
    ...output.metadata,
    browserVersion: output.browserVersion,
    scope: 'Bounded label/decorations oracle, not a complete geometry or mobile acceptance claim.',
    cases: output.cases
      .filter((item) => item.status === 'ok')
      .map((item) => ({
        id: item.id,
        source: cases.find((input) => input.id === item.id).source,
        iconCount: item.svg.icons.length,
        nodes: item.svg.nodes.map((node) => ({
          text: node.textContent,
          classes: node.class,
          shapes: node.shapes
            .filter((shape) => shape.userBox.width > 0)
            .map((shape) => ({
              tag: shape.tag,
              fill: shape.computed.fill,
            })),
          leaves: node.htmlDescendants
            .filter((element) => element.text !== null)
            .map((element) => ({
              tag: element.tag,
              text: element.text,
              color: element.computed.color,
              fontWeight: element.computed.fontWeight,
              fontStyle: element.computed.fontStyle,
              fontSize: element.computed.fontSize,
            })),
        })),
      })),
  };
  await writeFile(
    resolve(root, 'fixtures/mobile-parity/mermaid-mindmap-labels-expected.json'),
    JSON.stringify(portable, null, 2) + '\n',
  );
  console.log(
    JSON.stringify(
      {
        outputPath: resolve(outputDir, 'mindmap-unified-web-probe.json'),
        cases: results.map(
          ({ id, status, errorText, api, svg, screenshotPath, consoleErrors, pageErrors }) => ({
            id,
            status,
            errorText,
            api,
            icons: svg?.icons,
            nodes: svg?.nodes.map((node) => ({
              id: node.id,
              class: node.class,
              textContent: node.textContent,
              htmlDescendants: node.htmlDescendants,
              shapes: node.shapes.map((shapeRow) => ({
                tag: shapeRow.tag,
                computed: shapeRow.computed,
              })),
            })),
            markdownInline: results.find((row) => row.id === id)?.markdownInline,
            screenshotPath,
            consoleErrors,
            pageErrors,
          }),
        ),
      },
      null,
      2,
    ),
  );
} finally {
  await browser?.close();
  await server.close();
}
