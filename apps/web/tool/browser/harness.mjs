// Shared helpers for the real-browser checks in this folder.
//
// Rules: only the repository's dedicated test browser is ever launched (never an
// everyday Chrome), always with a new temporary profile that is removed again.
import http from 'node:http';
import net from 'node:net';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { chromium } from 'playwright-core';
import { requireTestBrowserExecutable } from '../../../../scripts/e2e/test_browser.mjs';

export const webRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
export const repositoryRoot = path.resolve(webRoot, '../..');

export async function freePort() {
  return new Promise((resolve, reject) => {
    const probe = net.createServer();
    probe.once('error', reject);
    probe.listen(0, '127.0.0.1', () => {
      const { port } = probe.address();
      probe.close(() => resolve(port));
    });
  });
}

/** Launch the dedicated test browser with a fresh profile. */
export async function launchTestBrowser(options = {}) {
  const executablePath = requireTestBrowserExecutable();
  const profile = await mkdtemp(path.join(tmpdir(), 'pirc-web-browser-check-'));
  const context = await chromium.launchPersistentContext(profile, {
    executablePath,
    headless: true,
    viewport: { width: 1280, height: 800 },
    ...options,
  });
  const version = context.browser()?.version() ?? 'unknown';
  return {
    context,
    executablePath,
    version,
    async close() {
      await context.close();
      await rm(profile, { recursive: true, force: true });
    },
  };
}

/**
 * A local server that records every request it receives. Content that tries
 * to load something remote is pointed here, so "no request was made" is
 * observed rather than assumed.
 */
export async function startReceiver() {
  const hits = [];
  const server = http.createServer((request, response) => {
    hits.push({ method: request.method, url: request.url, referer: request.headers.referer });
    const url = new URL(request.url, 'http://receiver.invalid');
    // Tiny valid responses so a loaded image/style/font really "works".
    if (url.pathname.endsWith('.png') || url.pathname.endsWith('.gif')) {
      response.writeHead(200, { 'content-type': 'image/gif' });
      response.end(Buffer.from('R0lGODlhAQABAIAAAP///wAAACwAAAAAAQABAAACAkQBADs=', 'base64'));
    } else if (url.pathname.endsWith('.css')) {
      response.writeHead(200, { 'content-type': 'text/css' });
      response.end('body{outline:3px solid red}');
    } else {
      response.writeHead(200, { 'content-type': 'text/html' });
      response.end('<!doctype html><title>remote</title><p>remote content</p>');
    }
  });
  const port = await freePort();
  await new Promise((resolve) => server.listen(port, '127.0.0.1', resolve));
  return {
    origin: `http://127.0.0.1:${port}`,
    hits,
    reset: () => (hits.length = 0),
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

/** The app's real modules served by Vite, with the content fixture page at /fixture.html. */
export async function startFixtureServer() {
  const { createServer } = await import(
    pathToFileURL(path.join(webRoot, 'node_modules/vite/dist/node/index.js'))
  );
  const port = await freePort();
  const cacheDir = await mkdtemp(path.join(tmpdir(), 'pirc-vite-cache-'));
  const server = await createServer({
    root: webRoot,
    configFile: path.join(webRoot, 'vite.config.ts'),
    cacheDir,
    logLevel: 'error',
    server: { host: '127.0.0.1', port, strictPort: true, proxy: {} },
    optimizeDeps: {
      include: [
        'mermaid',
        'katex',
        'highlight.js/lib/common',
        'dompurify',
        'marked',
        'katex/dist/katex.min.css',
      ],
    },
    plugins: [
      {
        name: 'pirc-content-fixture',
        configureServer(vite) {
          vite.middlewares.use('/fixture.html', async (_request, response, next) => {
            try {
              const html = await readFile(path.join(webRoot, 'tool/browser/fixture.html'), 'utf8');
              response.setHeader('content-type', 'text/html');
              response.end(await vite.transformIndexHtml('/fixture.html', html));
            } catch (error) {
              next(error);
            }
          });
        },
      },
    ],
  });
  await server.listen();
  return {
    origin: `http://127.0.0.1:${port}`,
    async close() {
      await server.close();
      await rm(cacheDir, { recursive: true, force: true });
    },
  };
}

/** Open the fixture page and wait for its renderers. */
export async function openFixture(context, origin, { theme = 'light' } = {}) {
  const page = await context.newPage();
  await page.emulateMedia({ colorScheme: theme });
  await page.goto(`${origin}/fixture.html`);
  await page.waitForFunction(() => window.pirc);
  await page.evaluate(() => window.pirc.ready());
  return page;
}
