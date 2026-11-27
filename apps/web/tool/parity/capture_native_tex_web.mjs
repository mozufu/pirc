// Run from the repository root with Node.js:
// node apps/web/tool/parity/capture_native_tex_web.mjs
// Uses production markdown.ts + markdown.css and pinned Chrome 154 to capture
// the shared TeX corpus at UI text scales 1× and 2×. Outputs go to the ignored
// apps/web/build/parity/native-tex-web directory.
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createServer } from '../../node_modules/vite/dist/node/index.js';

const root = resolve(import.meta.dirname, '../../../..');
const fixturePath = resolve(root, 'fixtures/mobile-parity/native-tex.json');
const fixture = JSON.parse(await readFile(fixturePath, 'utf8'));
const pinnedRevision = 'bd3d90981271e1f93cf3d1d1a5bbf9b61136b74c';
if (fixture.webRevision !== pinnedRevision)
  throw new Error('TeX corpus must match the pinned web revision');

execFileSync('git', ['diff', '--exit-code', pinnedRevision, '--', 'apps/web', ':!apps/web/tool'], {
  cwd: root,
  stdio: 'inherit',
});

const require = createRequire(resolve(root, 'apps/gateway/package.json'));
const webRequire = createRequire(resolve(root, 'apps/web/package.json'));
const { chromium } = require('playwright-core');
const { JSDOM } = webRequire('jsdom');
const dom = new JSDOM('<!doctype html><html><body></body></html>');
globalThis.window = dom.window;
globalThis.document = dom.window.document;
const vite = await createServer({
  configFile: resolve(root, 'apps/web/vite.config.ts'),
  root: resolve(root, 'apps/web'),
  server: { middlewareMode: true },
  appType: 'custom',
});
const markdown = await vite.ssrLoadModule('/src/lib/markdown.ts');
await markdown.preloadRenderers();

const katexCssPath = resolve(root, 'apps/web/node_modules/katex/dist/katex.min.css');
const katexFontDirectory = pathToFileURL(
  resolve(root, 'apps/web/node_modules/katex/dist/fonts'),
).href;
const katexCss = (await readFile(katexCssPath, 'utf8')).replaceAll(
  'url(fonts/',
  `url(${katexFontDirectory}/`,
);
const markdownCss = await readFile(resolve(root, 'apps/web/src/markdown.css'), 'utf8');
const outputDir = resolve(root, 'apps/web/build/parity/native-tex-web');
await mkdir(outputDir, { recursive: true });

const browser = await chromium.launch({
  executablePath: fixture.capture.browserExecutable,
  headless: true,
  args: ['--allow-file-access-from-files'],
});
const browserVersion = await browser.version();
if (!browserVersion.startsWith('154.')) {
  await browser.close();
  await vite.close();
  dom.window.close();
  throw new Error(`Expected pinned Chrome 154, got ${browserVersion}`);
}

const captures = [];
try {
  for (const textScale of fixture.capture.textScales) {
    const renderedCases = fixture.cases.map((item) => {
      const source =
        item.mode === 'display' ? `$$\n${item.source}\n$$` : `Before $${item.source}$ after`;
      const rendered = markdown.renderMarkdown(source);
      const followingParagraph =
        item.mode === 'display' ? '<p class="math-following-probe">Following paragraph</p>' : '';
      return (
        '<section class="tex-case" id="' +
        item.id +
        '" data-mode="' +
        item.mode +
        '">' +
        rendered +
        followingParagraph +
        '</section>'
      );
    });
    const renderedComparisons = fixture.cases
      .filter((item) => item.comparisonSource)
      .map((item) => {
        const mode = item.comparisonMode ?? 'inline';
        const source =
          mode === 'display'
            ? `$$\n${item.comparisonSource}\n$$`
            : `Before $${item.comparisonSource}$ after`;
        return `<section class="tex-comparison" id="${item.id}-comparison" data-mode="${mode}">${markdown.renderMarkdown(source)}</section>`;
      });
    const bodyFontSize = fixture.capture.paragraphFontSize * textScale;
    const html = `<!doctype html><html><head><meta charset="utf-8"><style>${katexCss}</style><style>${markdownCss}</style><style>
      * { box-sizing: border-box; }
      body { margin: 16px; font-family: Arial, sans-serif; font-size: ${bodyFontSize}px; line-height: 1.65; color: #17191c; }
      .markdown { font-family: Arial, sans-serif; font-size: ${bodyFontSize}px; line-height: 1.65; --ink: #17191c; --font-mono: Menlo, monospace; }
      .tex-case, .tex-comparison { margin: 0; padding: 0; }
    </style></head><body><main class="markdown">${renderedCases.join('\n')}${renderedComparisons.join('\n')}</main></body></html>`;
    const htmlPath = resolve(outputDir, `scale-${textScale}.html`);
    await writeFile(htmlPath, html);

    const page = await browser.newPage({
      viewport: {
        width: fixture.capture.width,
        height: fixture.capture.height,
      },
      deviceScaleFactor: fixture.capture.deviceScaleFactor,
    });
    await page.goto(pathToFileURL(htmlPath).href, { waitUntil: 'load' });
    await page.evaluate(async () => {
      await document.fonts.ready;
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    });
    const measured = await page.evaluate(() => {
      const box = (element) => {
        if (!element) return null;
        const rect = element.getBoundingClientRect();
        return {
          x: rect.x,
          y: rect.y,
          width: rect.width,
          height: rect.height,
        };
      };
      const measure = (container) => {
        const mathBlock = container.querySelector('.math-block');
        const display = container.querySelector('.katex-display');
        const katexNode = container.querySelector('.katex');
        const base = katexNode?.querySelector('.katex-html > .base');
        const strut = base?.querySelector('.strut');
        const followingParagraph = container.querySelector('.math-following-probe');
        const strutVerticalAlign = strut ? getComputedStyle(strut).verticalAlign : '0px';
        const strutBaselineShift = strutVerticalAlign.endsWith('em')
          ? parseFloat(strutVerticalAlign) * parseFloat(getComputedStyle(strut).fontSize)
          : parseFloat(strutVerticalAlign) || 0;
        const rows = [...container.querySelectorAll('.mtable .vlist > span[style]')]
          .filter((element) => element.style.top)
          .map((element) => ({
            text: element.textContent.trim(),
            topStyle: element.style.top,
            box: box(element),
          }));
        const tags = [...container.querySelectorAll('.eqn-num')].map((element) => ({
          text: element.textContent.trim(),
          box: box(element),
        }));
        const redUnsupported = [...container.querySelectorAll('[style]')].some(
          (element) => getComputedStyle(element).color === 'rgb(204, 0, 0)',
        );
        const mathErrors = [...container.querySelectorAll('.katex-error')].map(
          (element) => element.textContent,
        );
        return {
          id: container.id,
          mode: mathBlock ? 'display' : 'inline',
          mathBlockBox: box(mathBlock),
          displayBox: box(display),
          katexBox: box(katexNode),
          baseBox: box(base),
          strutBox: box(strut),
          strutBaselineY: strut ? box(strut).y + box(strut).height + strutBaselineShift : null,
          strutBaselineFromBaseTop:
            strut && base
              ? box(strut).y + box(strut).height + strutBaselineShift - box(base).y
              : null,
          strutComputedVerticalAlign: strutVerticalAlign,
          displayComputed: display
            ? {
                fontSize: getComputedStyle(display).fontSize,
                lineHeight: getComputedStyle(display).lineHeight,
                marginTop: getComputedStyle(display).marginTop,
                marginBottom: getComputedStyle(display).marginBottom,
              }
            : null,
          mathBlockComputed: mathBlock
            ? {
                fontSize: getComputedStyle(mathBlock).fontSize,
                paddingTop: getComputedStyle(mathBlock).paddingTop,
                paddingBottom: getComputedStyle(mathBlock).paddingBottom,
                overflowX: getComputedStyle(mathBlock).overflowX,
                overflowY: getComputedStyle(mathBlock).overflowY,
              }
            : null,
          katexComputed: katexNode
            ? {
                fontSize: getComputedStyle(katexNode).fontSize,
                lineHeight: getComputedStyle(katexNode).lineHeight,
              }
            : null,
          followingParagraphBox: box(followingParagraph),
          strutHeight: strut?.style.height ?? null,
          strutVerticalAlign: strut?.style.verticalAlign ?? null,
          rows,
          tags,
          redUnsupported,
          mathErrors,
          computedFontSize: katexNode ? getComputedStyle(katexNode).fontSize : null,
          hasLoadedKatexFont: document.fonts.check('16px KaTeX_Main'),
        };
      };
      return {
        cases: [...document.querySelectorAll('.tex-case')].map(measure),
        comparisons: [...document.querySelectorAll('.tex-comparison')].map(measure),
      };
    });
    const screenshotPath = resolve(outputDir, `scale-${textScale}.png`);
    await page.screenshot({ path: screenshotPath, fullPage: true });
    await page.close();
    captures.push({
      textScale,
      bodyFontSize,
      cases: measured.cases.map((capture) => ({
        ...capture,
        browserExpected: fixture.cases.find((item) => item.id === capture.id)?.browserExpected,
        limitation: fixture.cases.find((item) => item.id === capture.id)?.limitation,
      })),
      comparisons: measured.comparisons,
      screenshot: screenshotPath,
    });
  }
} finally {
  await browser.close();
  await vite.close();
  dom.window.close();
}

const outputPath = resolve(outputDir, 'native-tex-web.json');
await writeFile(
  outputPath,
  `${JSON.stringify(
    {
      webRevision: pinnedRevision,
      browserVersion,
      renderer: 'production markdown.ts renderMarkdown + markdown.css and KaTeX 0.16.47',
      fixture: 'fixtures/mobile-parity/native-tex.json',
      captures,
    },
    null,
    2,
  )}\n`,
);
console.log(outputPath);
