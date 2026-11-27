import { requireTestBrowserExecutable } from '../../../../scripts/e2e/test_browser.mjs';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { readFile, mkdir, writeFile, realpath } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { resolve } from 'node:path';
import { createServer } from '../../node_modules/vite/dist/node/index.js';
const root = resolve(import.meta.dirname, '../../../..');
const sha = 'bd3d90981271e1f93cf3d1d1a5bbf9b61136b74c';
execFileSync('git', ['diff', '--quiet', sha, '--', 'apps/web/src', 'apps/web/package.json'], {
  cwd: root,
});
const fixture = async (name) =>
  JSON.parse(await readFile(resolve(root, 'fixtures/mobile-parity/' + name + '.json'), 'utf8'));
const kanban = await fixture('mermaid-kanban'),
  sankey = await fixture('mermaid-sankey'),
  block = await fixture('mermaid-block-beta-reference');
const cases = {
  kanban: kanban.cases.find((c) => c.id === 'multiline-description').source,
  sankey: sankey.cases[0].source,
  block: block.cases[2].source,
};
const output = resolve(root, 'apps/web/build/parity/common-diagrams-web');
await mkdir(output, { recursive: true });
const pkg = JSON.parse(
  await readFile(resolve(root, 'apps/web/node_modules/mermaid/package.json'), 'utf8'),
);
assert.equal(pkg.version, '11.17.2');
const server = await createServer({
  root: resolve(root, 'apps/web'),
  configFile: resolve(root, 'apps/web/vite.config.ts'),
  cacheDir: resolve(output, 'vite-cache'),
  server: {
    host: '127.0.0.1',
    port: 18947,
    strictPort: true,
    fs: { allow: [root, await realpath(resolve(root, 'node_modules'))] },
  },
  plugins: [
    {
      name: 'common-diagrams-reference',
      configureServer(vite) {
        vite.middlewares.use('/common-diagrams.html', async (_, res, next) => {
          try {
            const html = `<!doctype html><html><head><link rel="icon" href="data:,"><style>body{overflow:auto!important}#fixture{padding:16px;font-family:Arial;font-size:15px;line-height:1.65}</style></head><body><main id="fixture" class="markdown"></main><script type="module">
import '/src/app.css';import '/src/markdown.css';import {preloadRenderers,renderMarkdown,enhanceMarkdown} from '/src/lib/markdown.ts';
await preloadRenderers();
let action;window.renderCase=async(id,source)=>{const root=document.querySelector('#fixture');const html=renderMarkdown('# '+id+'\\n\\n'+String.fromCharCode(96,96,96)+'mermaid\\n'+source+'\\n'+String.fromCharCode(96,96,96));root.innerHTML=html;if(action)action.destroy();action=enhanceMarkdown(root,{html,ready:true});const block=root.querySelector('.mermaid-block');for(let i=0;i<300&&!['ok','error'].includes(block.dataset.rendered);i++)await new Promise(r=>setTimeout(r,10));await document.fonts.ready;return {status:block.dataset.rendered,error:block.querySelector('.mermaid-error')?.textContent,svg:block.querySelector('svg')?.getAttribute('viewBox'),paths:[...block.querySelectorAll('svg path')].map(p=>({blend:getComputedStyle(p).mixBlendMode,stroke:getComputedStyle(p).stroke,opacity:getComputedStyle(p).strokeOpacity})),isolation:block.querySelector('svg')?getComputedStyle(block.querySelector('svg')).isolation:null,elements:[...block.querySelectorAll('svg rect,svg foreignObject,svg foreignObject div,svg foreignObject p,svg foreignObject span')].map(e=>{const st=getComputedStyle(e),r=e.getBoundingClientRect();return {tag:e.tagName,cls:e.getAttribute('class'),text:e.textContent?.slice(0,200),attrs:Object.fromEntries(['x','y','width','height','rx','ry','transform'].map(k=>[k,e.getAttribute(k)])),box:{x:r.x,y:r.y,width:r.width,height:r.height},font:st.font,fontSize:st.fontSize,lineHeight:st.lineHeight,marginTop:st.marginTop,marginBottom:st.marginBottom,padding:st.padding};})};};window.ready=true;
</script></body></html>`;
            res.setHeader('Content-Type', 'text/html');
            res.end(await vite.transformIndexHtml('/common-diagrams.html', html));
          } catch (e) {
            next(e);
          }
        });
      },
    },
  ],
});
await server.listen();
const { chromium } = createRequire(resolve(root, 'apps/gateway/package.json'))('playwright-core');
let browser;
try {
  browser = await chromium.launch({
    executablePath: requireTestBrowserExecutable(),
    headless: true,
  });
  const reports = [];
  for (const theme of ['light', 'dark']) {
    const page = await browser.newPage({
      viewport: { width: 768, height: 1000 },
      deviceScaleFactor: 1,
      colorScheme: theme,
    });
    try {
      await page.goto('http://127.0.0.1:18947/common-diagrams.html');
      await page.waitForFunction(() => window.ready);
      for (const [id, source] of Object.entries(cases)) {
        const result = await page.evaluate(({ id, source }) => window.renderCase(id, source), {
          id,
          source,
        });
        assert.equal(result.status, 'ok', JSON.stringify(result));
        await page.screenshot({ path: resolve(output, `${id}-${theme}.png`) });
        reports.push({ id, theme, ...result });
      }
    } finally {
      await page.close();
    }
  }
  await writeFile(
    resolve(output, 'report.json'),
    JSON.stringify(
      { sha, mermaid: pkg.version, viewport: [768, 1000], textScale: 1, cases, reports },
      null,
      2,
    ) + '\n',
  );
  console.log('Captured 6 actual pinned Web diagram renders.');
} finally {
  await browser?.close();
  await server.close();
}
