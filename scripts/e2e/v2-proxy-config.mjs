/** V2(b): static review of the reverse-proxy configuration the repository ships.
 *
 * Reads nix/module.nix (the nginx virtual host it generates; Nix is NOT
 * evaluated here) and docs/deploy/reverse-proxy.md (nginx and Traefik
 * examples; Caddy appears only as a static-file server) and looks for
 * anything that would drop, overwrite or limit the X-Pirc-Request request
 * header. A pass here is a reading of text, not a run of nginx: no nginx,
 * Caddy or Traefik is installed, and installing one needs the owner's approval.
 */
import fs from 'node:fs';
import path from 'node:path';
import { Results, repoRoot, coverage } from './lib.mjs';

const results = new Results('V2b');
const read = (rel) => fs.readFileSync(path.join(repoRoot, rel), 'utf8');
const files = {
  'nix/module.nix': read('nix/module.nix'),
  'docs/deploy/reverse-proxy.md': read('docs/deploy/reverse-proxy.md'),
};
console.log('V2b coverage: HEAD', coverage().head);

/** Directives that would drop, overwrite or limit a custom request header. */
const hazards = [
  [
    /proxy_pass_request_headers\s+off/i,
    'nginx: proxy_pass_request_headers off (drops every client header)',
  ],
  [
    /proxy_set_header\s+["']?x-pirc-request/i,
    'nginx: proxy_set_header X-Pirc-Request (overwrites the marker)',
  ],
  [/proxy_set_header\s+["']?x-pirc-\*/i, 'nginx: a wildcard X-Pirc-* header rewrite'],
  [
    /more_(clear|set)_input_headers[^\n]*x-pirc/i,
    'nginx (headers-more): clears or sets X-Pirc-* input headers',
  ],
  [
    /underscores_in_headers/i,
    'nginx: underscores_in_headers (irrelevant to a hyphenated name; reported if present)',
  ],
  [/ignore_invalid_headers\s+off/i, 'nginx: ignore_invalid_headers off'],
  [/large_client_header_buffers/i, 'nginx: large_client_header_buffers (a header size limit)'],
  [/header_up[^\n]*x-pirc-request/i, 'Caddy: header_up on X-Pirc-Request'],
  [/request_header[^\n]*x-pirc-request/i, 'Caddy: request_header on X-Pirc-Request'],
  [
    /customRequestHeaders[\s\S]{0,200}x-pirc-request/i,
    'Traefik: customRequestHeaders touching X-Pirc-Request',
  ],
  [
    /authRequestHeaders/i,
    'Traefik forwardAuth: authRequestHeaders allowlist (limits what the AUTH server sees, not the upstream)',
  ],
];
for (const [name, text] of Object.entries(files)) {
  const found = hazards.filter(([pattern]) => pattern.test(text)).map(([, label]) => label);
  results.check(
    `${name}: nothing drops, overwrites or limits X-Pirc-Request`,
    found.length === 0,
    found.join('; ') || 'no matching directive',
  );
}

// Which headers does each generated/documented location set explicitly?
const setHeaders = (text) =>
  [...text.matchAll(/proxy_set_header\s+(\S+)/g)].map((m) => m[1].replace(/^["']|["']$/g, ''));
const moduleApi = files['nix/module.nix'].slice(
  files['nix/module.nix'].indexOf('locations."/api/"'),
  files['nix/module.nix'].indexOf('locations."= /node/connect"'),
);
const docApi = files['docs/deploy/reverse-proxy.md'].slice(
  files['docs/deploy/reverse-proxy.md'].indexOf('location /api/ {'),
  files['docs/deploy/reverse-proxy.md'].indexOf('# Remote nodes only.'),
);
for (const [label, block] of [
  ['nix/module.nix location "/api/"', moduleApi],
  ['docs nginx location /api/', docApi],
]) {
  const names = [...new Set(setHeaders(block))];
  results.check(
    `${label}: sets only named headers, none of them X-Pirc-Request`,
    names.length > 0 && !names.some((n) => /^x-pirc-request$/i.test(n)),
    names.join(', '),
  );
}
results.check(
  'nix/module.nix: /api/ proxies with proxy_http_version 1.1 semantics of the Nix helper (proxyWebsockets) and no header allowlist',
  /proxyWebsockets\s*=\s*true/.test(moduleApi) && !/proxy_pass_request_headers/.test(moduleApi),
  'proxyWebsockets = true; no proxy_pass_request_headers directive',
);

// Informational findings (never fail the run).
const mentions = /x-pirc-request/i.test(files['docs/deploy/reverse-proxy.md']);
results.add(
  'info: docs/deploy/reverse-proxy.md tells operators to pass X-Pirc-Request through unchanged',
  mentions ? 'pass' : 'not-run',
  mentions
    ? 'mentioned'
    : 'NOT mentioned (nothing there removes it either; recommend one sentence)',
);
const caddyConfig = /^\s*reverse_proxy\b/m.test(files['docs/deploy/reverse-proxy.md']);
results.add(
  'info: a Caddy reverse_proxy example exists',
  caddyConfig ? 'pass' : 'not-run',
  caddyConfig
    ? 'present'
    : 'no Caddyfile is shipped; Caddy is only named as a static-file server, so nothing to review (Caddy reverse_proxy forwards request headers unchanged by default)',
);
const bodyLimit = /client_max_body_size|clientMaxBodySize/.test(
  files['nix/module.nix'] + files['docs/deploy/reverse-proxy.md'],
);
results.add(
  'info: client_max_body_size is configured for uploads',
  bodyLimit ? 'pass' : 'not-run',
  bodyLimit
    ? 'present'
    : 'not set by the module or docs (nginx default 1m applies unless the host sets it; unrelated to the header, but uploads above 1 MiB would get 413 from nginx; Nix not evaluated so the NixOS default of services.nginx.clientMaxBodySize is not confirmed)',
);
results.add(
  'info: a real nginx/Caddy/Traefik run',
  'not-run',
  "not installed here; would need the owner's approval to install",
);

console.log(
  `V2b: ${results.rows.filter((r) => r.status === 'pass').length} passed, ${results.failed.length} failed, ${results.rows.filter((r) => r.status === 'not-run').length} informational/not-run`,
);
process.exit(results.failed.length ? 1 : 0);
