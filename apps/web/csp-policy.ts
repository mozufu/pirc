/**
 * The Content-Security-Policy of the shipped web app, injected into index.html
 * as a <meta> element at build time (see vite.config.ts), so every deployment
 * has it. The dev server does not get it: Vite's own client needs inline
 * scripts and a WebSocket to the dev host.
 *
 * It is the second line of defence behind the sanitiser: should content from a
 * message or a file ever name a remote image, style sheet, font or script, the
 * browser refuses to load it and reports a `securitypolicyviolation`. Images
 * stay limited to the app's own origin and inline data (`data:` and `blob:`);
 * a remote image is opened in a new tab on the user's click instead.
 *
 * - `style-src 'unsafe-inline'`: rendered Markdown, KaTeX and Mermaid output
 *   carry `style` attributes and `<style>` elements, and the app sets inline
 *   styles. Styles cannot fetch anything: `img-src`, `font-src` and `default-src`
 *   still apply to every `url()` and `@import` inside them.
 * - No `form-action`: a form in a message may submit to another site.
 * - `frame-ancestors` is ignored in a <meta> element; it is sent as an HTTP
 *   header by the web server (see docs/deploy/reverse-proxy.md).
 */
export const contentSecurityPolicy = [
  "default-src 'self'",
  "script-src 'self'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob:",
  "media-src 'self' blob:",
  "font-src 'self' data:",
  "connect-src 'self'",
  "worker-src 'self'",
  "manifest-src 'self'",
  "object-src 'none'",
  "base-uri 'none'",
].join('; ');

/** Put the policy into the page, right after the character-set declaration. */
export function injectContentSecurityPolicy(html: string): string {
  const meta = `<meta http-equiv="Content-Security-Policy" content="${contentSecurityPolicy}" />`;
  const charset = /<meta\s+charset=[^>]*>/i.exec(html);
  if (charset) {
    const end = charset.index + charset[0].length;
    return `${html.slice(0, end)}\n    ${meta}${html.slice(end)}`;
  }
  return html.replace(/<head[^>]*>/i, (head) => `${head}\n    ${meta}`);
}

/**
 * Response headers the web server sends with the static app (nginx in the
 * NixOS module, the Caddy / Traefik / nginx examples in docs/deploy/reverse-proxy.md).
 * `frame-ancestors` only works as a header, never in a <meta> element.
 */
export const staticSecurityHeaders: Record<string, string> = {
  'Content-Security-Policy': "frame-ancestors 'none'",
  'Referrer-Policy': 'no-referrer',
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
};
