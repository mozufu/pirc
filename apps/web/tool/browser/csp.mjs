// node apps/web/tool/browser/csp.mjs
//
// Builds the web app, serves the BUILT bundle the way the documented reverse proxy
// would (SPA fallback, the static security headers), runs it against a real
// pirc-gateway and pirc-node (fresh temporary state, local fake model) in the dedicated
// test browser, and collects every `securitypolicyviolation` while the main screens
// are used: home, a conversation with Markdown / code / KaTeX / Mermaid / images /
// forms, the Files panel, settings, the terminal and browser panels.
// Normal use must record zero violations. As a control, content that a sanitiser
// miss would leave in the page (a remote image, a CSS url(), a style sheet, a fetch)
// must be refused by the policy and recorded, and never reach the local receiver.
//
// Needs the compiled executables (target/debug/pirc-gateway, pirc-node) and the
// helpers of scripts/e2e/lib.mjs; without them only the build checks run.
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import http from 'node:http';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { freePort, launchTestBrowser, repositoryRoot, startReceiver, webRoot } from './harness.mjs';
import { contentSecurityPolicy, staticSecurityHeaders } from '../../csp-policy.ts';

const { build } = await import(
  pathToFileURL(path.join(webRoot, 'node_modules/vite/dist/node/index.js'))
);
const outDir = await mkdtemp(path.join(tmpdir(), 'pirc-web-dist-'));
await build({ root: webRoot, logLevel: 'error', build: { outDir, emptyOutDir: true } });
const indexHtml = await readFile(path.join(outDir, 'index.html'), 'utf8');
const meta = /<meta http-equiv="Content-Security-Policy" content="([^"]*)"/.exec(indexHtml);
assert.ok(meta, 'the built index.html has no CSP meta element');
assert.equal(meta[1], contentSecurityPolicy);
assert.ok(
  indexHtml.indexOf('Content-Security-Policy') < indexHtml.indexOf('<script'),
  'the policy must come before any script',
);
assert.ok(!/<script(?![^>]*\ssrc=)[^>]*>/i.test(indexHtml), 'the built page has an inline script');
console.log('build: index.html carries the policy:', meta[1]);

const results = [];
const note = (id, status, detail = '') => {
  results.push({ id, status, detail });
  console.log(`  [${status}] ${id}${detail ? ' -- ' + detail : ''}`);
};

/** The built bundle, served like a reverse proxy would. */
let activePolicy = contentSecurityPolicy;
function staticHandler() {
  const types = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript',
    '.css': 'text/css',
    '.json': 'application/json',
    '.webmanifest': 'application/manifest+json',
    '.svg': 'image/svg+xml',
    '.png': 'image/png',
    '.woff2': 'font/woff2',
    '.woff': 'font/woff',
    '.ttf': 'font/ttf',
  };
  return async (req, res) => {
    const url = new URL(req.url, 'http://static.invalid');
    let file = path.join(outDir, decodeURIComponent(url.pathname));
    if (!file.startsWith(outDir) || !existsSync(file) || file === outDir + path.sep) {
      file = path.join(outDir, 'index.html');
    }
    try {
      let body = await readFile(file);
      if (file.endsWith('index.html') && activePolicy !== contentSecurityPolicy) {
        body = Buffer.from(body.toString('utf8').replace(contentSecurityPolicy, activePolicy));
      }
      res.writeHead(200, {
        'content-type': types[path.extname(file)] ?? 'application/octet-stream',
        'cache-control': 'no-cache',
        ...staticSecurityHeaders,
      });
      res.end(body);
    } catch {
      res.writeHead(404);
      res.end();
    }
  };
}

let lib;
try {
  lib = await import(pathToFileURL(path.join(repositoryRoot, 'scripts/e2e/lib.mjs')));
} catch (error) {
  note('live pages', 'not-run', `scripts/e2e/lib.mjs unavailable: ${error.message}`);
}
const bins = lib?.binaries();
if (lib && !(existsSync(bins.gateway) && existsSync(bins.node))) {
  note('live pages', 'not-run', 'target/debug/pirc-gateway or pirc-node is missing');
  lib = undefined;
}

const sample = (recv) => `# Release notes

Plain text with **bold**, a [link](https://example.com/page) and inline math $E = mc^2$.

$$
\\int_0^1 x^2\\,dx = \\tfrac{1}{3}
$$

\`\`\`ts
const answer: number = 42;
console.log(answer);
\`\`\`

| name | value |
| ---- | ----- |
| a    | 1     |

![inline image](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==)

![remote image](${recv}/remote.png)

<div style="color:#b00020;border:1px solid #b00020;padding:4px">styled box with an inline style</div>

<form action="${recv}/submit" method="post"><input name="q" value="x"><button type="submit">Send to another site</button></form>

\`\`\`mermaid
flowchart LR
  A[Start] -->|yes| B(Do thing)
  B --> C{Check?}
\`\`\`
`;

if (lib) {
  const { FakeLlm, makeTempDir, removeDir, startStack, startAdapter, stopAllProcesses, USER } = lib;
  const root = makeTempDir('csp');
  const llm = await new FakeLlm().start();
  const receiver = await startReceiver();
  let stack, adapter, browser;
  const violations = [];
  try {
    stack = await startStack({ root, bins, llm, nodes: [{ id: 'test', kind: 'directory' }] });
    await writeFile(path.join(stack.workspaceDirs.test, 'notes.md'), sample(receiver.origin));
    await writeFile(
      path.join(stack.workspaceDirs.test, 'dot.png'),
      Buffer.from(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
        'base64',
      ),
    );
    const created = await stack.client.call('POST', '/api/sessions', {
      json: { workspaceId: 'test:test' },
    });
    assert.equal(created.status, 201, created.text);
    const sessionId = created.json.session.id;
    const serve = staticHandler();
    adapter = await startAdapter({ gateway: stack.base, fallback: serve });
    browser = await launchTestBrowser();
    console.log(`browser: ${browser.executablePath} (${browser.version})`);
    const page = await browser.context.newPage();
    page.setDefaultTimeout(30000);
    const consoleCsp = [];
    page.on('console', (message) => {
      if (/Content Security Policy/i.test(message.text())) consoleCsp.push(message.text());
    });
    await page.addInitScript(() => {
      window.__violations = [];
      document.addEventListener('securitypolicyviolation', (event) => {
        window.__violations.push({
          directive: event.effectiveDirective,
          blocked: event.blockedURI,
          source: event.sourceFile,
          sample: event.sample,
        });
      });
    });
    const drain = async (label) => {
      const found = await page.evaluate(() => window.__violations.splice(0));
      violations.push(...found.map((v) => ({ page: label, ...v })));
      return found.length;
    };
    const screen = async (label, action) => {
      await action();
      await page.waitForTimeout(800);
      const count = await drain(label);
      note(`screen: ${label}`, count === 0 ? 'pass' : 'FAIL', `${count} violation(s)`);
    };

    await screen('home (new conversation)', async () => {
      await page.goto(`${adapter.url}/`);
      await page.locator('textarea').first().waitFor();
    });

    await screen(
      'conversation with Markdown / code / KaTeX / Mermaid / images / forms',
      async () => {
        await page.goto(`${adapter.url}/?session=${encodeURIComponent(sessionId)}`);
        llm.push({ text: sample(receiver.origin) });
        await page.locator('textarea').first().fill('Show me the release notes');
        await page.getByLabel('Send message').click();
        await page.locator('.mermaid-block[data-rendered]').first().waitFor({ timeout: 40000 });
        await page.waitForFunction(() =>
          [...document.querySelectorAll('.mermaid-block')].every(
            (b) => b.dataset.rendered === 'ok',
          ),
        );
        await page.locator('.katex').first().waitFor();
        await page.locator('.hljs').first().waitFor();
        assert.equal(
          (await page.locator('.remote-media').count()) >= 1,
          true,
          'remote image placeholder',
        );
      },
    );

    const openPanel = async () => {
      const show = page.getByLabel('Show side panel');
      if (await show.count()) await show.click();
    };
    await screen('Files panel: Markdown preview and image preview', async () => {
      await openPanel();
      await page.locator('#panel-tab-files').click();
      await page.getByText('notes.md').click();
      await page.locator('.side-panel .markdown .katex').first().waitFor();
      await page
        .locator('.side-panel .mermaid-block[data-rendered="ok"]')
        .first()
        .waitFor({ timeout: 40000 });
      await page
        .getByLabel('Back')
        .first()
        .click()
        .catch(() => {});
      await page
        .getByText('dot.png')
        .first()
        .click()
        .catch(() => {});
      await page.waitForTimeout(500);
    });

    await screen('settings', async () => {
      await page.getByText('Settings', { exact: true }).first().click();
      await page.waitForTimeout(500);
      await page.keyboard.press('Escape');
    });

    await screen('terminal panel', async () => {
      await openPanel();
      await page.locator('#panel-tab-terminal').click();
      await page.waitForTimeout(1000);
      // Start a terminal when the node offers one.
      const open = page.getByRole('button', { name: 'Open terminal' });
      if ((await open.count()) && (await open.isEnabled())) await open.click();
      await page
        .locator('.xterm')
        .first()
        .waitFor({ timeout: 15000 })
        .catch(() => {});
      await page.waitForTimeout(1000);
    });
    note(
      'terminal panel shows a terminal',
      (await page.locator('.xterm').count()) > 0 ? 'pass' : 'info',
      `${await page.locator('.xterm').count()} xterm element(s); panel: ${JSON.stringify((await page.locator('.side-panel').innerText()).replace(/\s+/g, ' ').slice(0, 160))}`,
    );

    await screen('browser panel', async () => {
      await openPanel();
      await page.locator('#panel-tab-browser').click();
      await page.waitForTimeout(800);
    });

    // How much of `style-src` is needed: the same conversation and preview under a policy
    // without 'unsafe-inline' for styles.
    activePolicy = contentSecurityPolicy.replace(
      "style-src 'self' 'unsafe-inline'",
      "style-src 'self'",
    );
    await drain('before variant');
    await page.goto(`${adapter.url}/?session=${encodeURIComponent(sessionId)}`);
    await page
      .locator('.mermaid-block[data-rendered]')
      .first()
      .waitFor({ timeout: 40000 })
      .catch(() => {});
    await page
      .locator('.katex')
      .first()
      .waitFor()
      .catch(() => {});
    await openPanel();
    await page.locator('#panel-tab-files').click();
    await page.getByText('notes.md').click();
    await page.locator('.side-panel .markdown').first().waitFor();
    await page.waitForTimeout(1500);
    const strict = await page.evaluate(() => window.__violations.splice(0));
    const byDirective = {};
    for (const v of strict) byDirective[v.directive] = (byDirective[v.directive] ?? 0) + 1;
    note(
      "measurement: without 'unsafe-inline' the same screens record violations",
      strict.length > 0 ? 'pass' : 'FAIL',
      JSON.stringify(byDirective),
    );
    console.log(
      "style violations without 'unsafe-inline':",
      JSON.stringify(strict.slice(0, 6).map((v) => [v.directive, v.sample?.slice(0, 60)])),
    );
    activePolicy = contentSecurityPolicy;
    await page.goto(`${adapter.url}/`);
    await page.locator('textarea').first().waitFor();
    await drain('after variant');

    // Nothing but the user's click may fetch the remote image; the policy never blocked it
    // because the sanitiser kept it out of the page.
    note(
      'remote image/form content of the conversation',
      receiver.hits.length === 0 ? 'pass' : 'FAIL',
      `${receiver.hits.length} request(s) reached the external receiver while the pages were shown`,
    );

    // Control: what a sanitiser miss would leave in the page is refused by the policy.
    receiver.reset();
    await drain('before control');
    await page.evaluate((recv) => {
      const host = document.createElement('div');
      host.id = 'control';
      host.innerHTML =
        `<img src="${recv}/control-img.png">` +
        `<div style="width:10px;height:10px;background:url(${recv}/control-bg.png)"></div>`;
      document.body.append(host);
      const sheet = document.createElement('link');
      sheet.rel = 'stylesheet';
      sheet.href = `${recv}/control.css`;
      document.head.append(sheet);
      const style = document.createElement('style');
      style.textContent = `@import url(${recv}/control-import.css);`;
      document.head.append(style);
      void fetch(`${recv}/control-fetch`, { mode: 'no-cors' }).catch(() => {});
      const script = document.createElement('script');
      script.src = `${recv}/control.js`;
      document.head.append(script);
    }, receiver.origin);
    await page.waitForTimeout(1500);
    const control = await page.evaluate(() => window.__violations.splice(0));
    const kinds = new Set(control.map((v) => v.directive));
    console.log(
      'control violations:',
      JSON.stringify(control.map((v) => [v.directive, v.blocked])),
    );
    const expected = ['img-src', 'connect-src', 'script-src-elem', 'style-src-elem'];
    for (const directive of expected) {
      note(
        `control: ${directive} violation recorded`,
        [...kinds].some(
          (k) => k === directive || (directive === 'style-src-elem' && k.startsWith('style-src')),
        )
          ? 'pass'
          : 'FAIL',
      );
    }
    note(
      'control: nothing reached the external receiver',
      receiver.hits.length === 0 ? 'pass' : 'FAIL',
      `${receiver.hits.length} request(s): ${JSON.stringify(receiver.hits.map((h) => h.url))}`,
    );

    // Framing is refused by the headers the static server sends.
    const framer = http.createServer((_req, res) => {
      res.writeHead(200, { 'content-type': 'text/html' });
      res.end(`<!doctype html><iframe id="f" src="${adapter.url}/"></iframe>`);
    });
    const framerPort = await freePort();
    await new Promise((resolve) => framer.listen(framerPort, '127.0.0.1', resolve));
    const framed = await browser.context.newPage();
    await framed.goto(`http://127.0.0.1:${framerPort}/`);
    await framed.waitForTimeout(1500);
    const frameHasApp = await framed.evaluate(() => {
      try {
        return !!document.getElementById('f').contentDocument?.getElementById('app');
      } catch {
        return false;
      }
    });
    const childUrls = framed.frames().map((f) => f.url());
    note(
      'framing the app from another origin is refused',
      !frameHasApp && !childUrls.some((u) => u.startsWith(adapter.url)) ? 'pass' : 'FAIL',
      JSON.stringify(childUrls),
    );
    await framed.close();
    framer.close();

    const normal = violations.filter((v) => v.page !== 'before control');
    console.log(`normal-use violations: ${normal.length}`);
    for (const v of normal) console.log('  ', JSON.stringify(v));
  } finally {
    await browser?.context.close();
    await adapter?.close?.();
    await stack?.stop();
    await stopAllProcesses();
    await receiver.close();
    await llm.stop();
    removeDir(root);
    void USER;
  }
}
await rm(outDir, { recursive: true, force: true });
const failed = results.filter((r) => r.status === 'FAIL');
console.log(`\n${results.length} checks, ${failed.length} failed`);
// Child processes and sockets of the stack may keep the loop alive.
process.exit(failed.length ? 1 : 0);
