import { svelte } from '@sveltejs/vite-plugin-svelte';
import { readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { defineConfig, type Plugin } from 'vite';
import { injectContentSecurityPolicy } from './csp-policy';
import { buildId, stampServiceWorker } from './sw-build-id';

/** The CSP goes into index.html of a build only (the dev server needs inline scripts). */
const contentSecurityPolicy = (): Plugin => ({
  name: 'pirc-content-security-policy',
  apply: 'build',
  transformIndexHtml: { order: 'post', handler: injectContentSecurityPolicy },
});

/** Gives every build its own sw.js bytes, so open pages are offered the update. */
const serviceWorkerBuildId = (): Plugin => {
  let outDir = '';
  let id = '';
  return {
    name: 'pirc-service-worker-build-id',
    apply: 'build',
    configResolved(config) {
      outDir = resolve(config.root, config.build.outDir);
    },
    generateBundle(_options, bundle) {
      // File names carry content hashes; the page itself is included by content.
      id = buildId(
        Object.values(bundle)
          .map((file) =>
            file.type === 'asset' && file.fileName === 'index.html'
              ? `${file.fileName}:${file.source}`
              : file.fileName,
          )
          .sort(),
      );
    },
    async closeBundle() {
      const file = resolve(outDir, 'sw.js');
      await writeFile(file, stampServiceWorker(await readFile(file, 'utf8'), id));
    },
  };
};

export default defineConfig({
  plugins: [svelte(), contentSecurityPolicy(), serviceWorkerBuildId()],
  // Component tests mount into jsdom rather than rendering on the server.
  resolve: process.env.VITEST ? { conditions: ['browser'] } : undefined,
  build: {
    manifest: true,
    // No source maps in the shipped bundle: the gateway would serve them to
    // anyone who can load the app (security audit L15).
    sourcemap: false,
    // Only lazily loaded renderers (mermaid diagrams, KaTeX) exceed the default
    // 500 kB; the entry chunk stays well below this.
    chunkSizeWarningLimit: 750,
  },
  server: {
    proxy: {
      '/api': {
        target: 'http://localhost:8787',
        changeOrigin: true,
        ws: true,
      },
    },
  },
  test: {
    include: ['src/**/*.test.ts', '*.test.ts'],
  },
});
