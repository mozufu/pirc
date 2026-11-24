/**
 * The model catalog the Rust gateway embeds (crates/pirc-providers/catalog.json),
 * generated from the pinned pi-ai package's catalog (docs/development/historical-records.md).
 *
 * Only providers whose every model uses a wire API the gateway implements are
 * kept (the others could be neither presets nor OAuth catalogs). `cost` (US
 * dollars per million tokens) is kept for the usage ledger; the pinned pi-ai
 * version is the pricing revision. OpenCode uses a separate pinned
 * live-catalog snapshot; --refresh-opencode explicitly refreshes it. Base URLs
 * moved since the pinned release are rewritten through BASE_URL_MOVES.
 *
 *   bun scripts/model-catalog.ts          write the snapshot
 *   bun scripts/model-catalog.ts --check  fail when the snapshot is stale
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { refreshOpenCodeCatalog } from './opencode-catalog.ts';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const piAi = path.join(root, 'node_modules/@mariozechner/pi-ai');
const output = path.join(root, 'crates/pirc-providers/catalog.json');
const openCodePath = path.join(root, 'scripts/catalog/opencode.json');

export const SUPPORTED_APIS: ReadonlySet<string> = new Set([
  'anthropic-messages',
  'openai-completions',
  'openai-responses',
  'openai-codex-responses',
]);

type CatalogModel = Record<string, unknown> & { api: string };

/** `provider -> api -> [old, new]` base URL moves applied to the snapshot. */
export const BASE_URL_MOVES: Readonly<
  Record<string, Readonly<Record<string, readonly [string, string]>>>
> = {
  // OpenCode moved Zen/Go from `/zen/...` to per-API `/inference/...` paths.
  'opencode-go': {
    'openai-completions': [
      'https://opencode.ai/zen/go/v1',
      'https://opencode.ai/inference/go/openai/v1',
    ],
    'anthropic-messages': [
      'https://opencode.ai/zen/go',
      'https://opencode.ai/inference/go/anthropic',
    ],
  },
};

function moveBaseUrl(provider: string, model: Record<string, unknown>): Record<string, unknown> {
  const move = BASE_URL_MOVES[provider]?.[String(model.api)];
  return move && model.baseUrl === move[0] ? { ...model, baseUrl: move[1] } : model;
}

/** A catalog price, or nothing when the source has none. */
function price(cost: unknown): { cost: Record<string, number> } | undefined {
  if (!cost || typeof cost !== 'object') return undefined;
  const value = cost as Record<string, unknown>;
  const keys = ['input', 'output', 'cacheRead', 'cacheWrite'];
  if (!keys.every((key) => typeof value[key] === 'number' && value[key] >= 0)) return undefined;
  return { cost: Object.fromEntries(keys.map((key) => [key, value[key] as number])) };
}

export function snapshot(
  version: string,
  providers: readonly string[],
  models: (provider: string) => CatalogModel[],
  openCode: Record<string, CatalogModel[]> = JSON.parse(readFileSync(openCodePath, 'utf8'))
    .providers,
): string {
  const kept: Record<string, Record<string, unknown>[]> = {};
  for (const provider of new Set([...providers, ...Object.keys(openCode)])) {
    const entries = openCode[provider] ?? models(provider);
    const legacy = new Map(models(provider).map((model) => [String(model.id), model]));
    if (!entries.length || !entries.every((model) => SUPPORTED_APIS.has(model.api))) continue;
    kept[provider] = entries.map(({ cost, ...rest }) => {
      const model: Record<string, unknown> = { ...rest, ...(price(cost) ?? {}) };
      const old = legacy.get(String(model.id));
      if (openCode[provider] && old?.api === model.api) {
        // Retain pi-ai's tested wire compatibility, without retaining stale limits.
        for (const key of ['compat', 'headers', 'thinkingLevelMap']) {
          if (old[key])
            model[key] =
              key === 'compat' ? { ...(old[key] as object), ...(model[key] as object) } : old[key];
        }
      }
      return moveBaseUrl(provider, model);
    });
  }
  return `${JSON.stringify({ piAi: version, providers: kept })}\n`;
}

if (import.meta.main) {
  if (process.argv.includes('--refresh-opencode')) {
    if (process.argv.includes('--check'))
      throw new Error('Refresh and --check are mutually exclusive');
    const { format, resolveConfig } = await import('prettier');
    const pin = await refreshOpenCodeCatalog();
    const formatted = await format(JSON.stringify(pin, null, 2), {
      ...(await resolveConfig(openCodePath)),
      filepath: openCodePath,
    });
    writeFileSync(openCodePath, formatted);
  }
  if (process.argv.includes('--refresh-providers')) {
    if (process.argv.includes('--check'))
      throw new Error('Refresh and --check are mutually exclusive');
    execFileSync('python3', [path.join(root, 'scripts/refresh-provider-catalog.py')], {
      stdio: 'inherit',
    });
  }
  const providerPin = JSON.parse(
    readFileSync(path.join(root, 'scripts/catalog/providers.json'), 'utf8'),
  );
  const { version: _legacyVersion } = JSON.parse(
    readFileSync(path.join(piAi, 'package.json'), 'utf8'),
  ) as {
    version: string;
  };
  const { getModels, getProviders } = (await import(path.join(piAi, 'dist/models.js'))) as {
    getProviders(): string[];
    getModels(provider: string): CatalogModel[];
  };
  const version = providerPin.version as string;
  const text = snapshot(
    version,
    getProviders(),
    (provider) => providerPin.providers[provider] ?? getModels(provider),
  );
  if (process.argv.includes('--check')) {
    let current = '';
    try {
      current = readFileSync(output, 'utf8');
    } catch {
      /* reported below */
    }
    if (current !== text) {
      console.error(
        `${path.relative(root, output)} is stale; run bun scripts/model-catalog.ts (pi-ai ${version})`,
      );
      process.exit(1);
    }
  } else {
    writeFileSync(output, text);
    console.log(`${path.relative(root, output)}: pi-ai ${version}, ${text.length} bytes`);
  }
}
