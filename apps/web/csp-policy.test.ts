import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  contentSecurityPolicy,
  injectContentSecurityPolicy,
  staticSecurityHeaders,
} from './csp-policy';

const html = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <title>pirc</title>
    <script type="module" src="/assets/index.js"></script>
  </head>
  <body></body>
</html>`;

describe('content security policy', () => {
  const directives = Object.fromEntries(
    contentSecurityPolicy.split('; ').map((part) => {
      const [name, ...values] = part.split(' ');
      return [name, values];
    }),
  );

  it('allows the page only what it needs', () => {
    expect(directives['default-src']).toEqual(["'self'"]);
    expect(directives['script-src']).toEqual(["'self'"]);
    expect(directives['img-src']).toEqual(["'self'", 'data:', 'blob:']);
    expect(directives['connect-src']).toEqual(["'self'"]);
    expect(directives['object-src']).toEqual(["'none'"]);
    expect(directives['base-uri']).toEqual(["'none'"]);
    // Remote images load by the user's click in a new tab, so no remote origin is allowed.
    expect(contentSecurityPolicy).not.toMatch(/https?:|\*/);
    // Forms in messages may submit to other sites; frame-ancestors is a header-only directive.
    expect(directives['form-action']).toBeUndefined();
    expect(directives['frame-ancestors']).toBeUndefined();
  });

  it('is written into the page right after the character set, before any script', () => {
    const out = injectContentSecurityPolicy(html);
    const meta = out.indexOf('http-equiv="Content-Security-Policy"');
    expect(out.indexOf('<meta charset')).toBeLessThan(meta);
    expect(meta).toBeLessThan(out.indexOf('<script'));
    expect(out).toContain(`content="${contentSecurityPolicy}"`);
    expect(injectContentSecurityPolicy('<head><title>x</title></head>')).toContain(
      '<head>\n    <meta http-equiv',
    );
  });

  it('is part of a build only, never of the dev server or the source page', () => {
    expect(readFileSync(resolve(process.cwd(), 'index.html'), 'utf8')).not.toContain(
      'Content-Security-Policy',
    );
    const config = readFileSync(resolve(process.cwd(), 'vite.config.ts'), 'utf8');
    expect(config).toMatch(/name: 'pirc-content-security-policy',\s*apply: 'build'/);
  });
});

describe('static security headers', () => {
  it('are the ones the NixOS module and the documented proxy examples send', () => {
    const module = readFileSync(resolve(process.cwd(), '../../nix/module.nix'), 'utf8');
    const docs = readFileSync(resolve(process.cwd(), '../../docs/deploy/reverse-proxy.md'), 'utf8');
    for (const [name, value] of Object.entries(staticSecurityHeaders)) {
      expect(module, name).toContain(`add_header ${name} "${value}" always;`);
      expect(docs, name).toContain(`add_header ${name} "${value}" always;`);
      expect(docs, name).toContain(`${name}: ${value}`); // Traefik
      expect(docs, name).toContain(`${name} "${value}"`); // Caddy
    }
  });
});
