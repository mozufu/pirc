import { readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';

const manifests = ['package.json', 'apps/web/package.json'];
const mobile = 'apps/app/pubspec.yaml';
const appVersion = 'apps/app/lib/src/settings/settings_widgets.dart';
function mobileVersion(text: string): { version: string; code: number } {
  const value = field(text, /(?:^|\n)version:\s*([0-9.]+\+[0-9]+)/);
  const [version, build] = value.split('+');
  const code = Number(build);
  parseVersion(version!);
  if (!Number.isInteger(code) || code < 1 || code > 2100000000)
    throw new Error('Invalid Flutter Android versionCode');
  return { version: version!, code };
}
function dartAppVersion(text: string): string {
  return field(text, /(?:^|\n)const appVersion = '([^']+)';/);
}
/** The Rust workspace (docs/development/historical-records.md): every member inherits `[workspace.package]`. */
const cargo = 'Cargo.toml';
const cargoLock = 'Cargo.lock';
/** The line of `version = "…"` in `[workspace.package]`, and its value. */
function cargoVersionLine(lines: string[]): { index: number; version: string } {
  const start = lines.findIndex((line) => line.trim() === '[workspace.package]');
  for (let index = start + 1; start >= 0 && index < lines.length; index++) {
    if (lines[index]!.trimStart().startsWith('[')) break;
    const match = /^version\s*=\s*"([^"]+)"\s*$/.exec(lines[index]!.trim());
    if (match) return { index, version: match[1]! };
  }
  throw new Error('Expected version in [workspace.package] of Cargo.toml');
}
function cargoVersion(text: string): string {
  return cargoVersionLine(text.split('\n')).version;
}
/** Versions of the workspace's own packages (no `source`) in Cargo.lock. */
function cargoLockVersions(text: string): Array<[string, string]> {
  return text
    .split('[[package]]')
    .slice(1)
    .filter((entry) => !/\nsource = /.test(entry))
    .map((entry) => [field(entry, /\nname = "([^"]+)"/), field(entry, /\nversion = "([^"]+)"/)]);
}
export function parseVersion(value: string): number[] {
  if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(value))
    throw new Error('Expected a stable MAJOR.MINOR.PATCH version (without v)');
  const parts = value.split('.').map(Number);
  if (parts.some((n) => !Number.isSafeInteger(n))) throw new Error('Version component too large');
  return parts;
}
function field(text: string, pattern: RegExp): string {
  const matches = [...text.matchAll(new RegExp(pattern.source, 'g'))];
  if (matches.length !== 1) throw new Error('Expected exactly one version field');
  return matches[0]![1]!;
}
export function checkVersions(root: string): string {
  const read = (file: string) => readFileSync(path.join(root, file), 'utf8');
  const version = JSON.parse(read(manifests[0]!)).version as string;
  parseVersion(version);
  for (const file of manifests.slice(1))
    if (JSON.parse(read(file)).version !== version) throw new Error(`Version mismatch: ${file}`);
  if (mobileVersion(read(mobile)).version !== version) throw new Error('Flutter version mismatch');
  if (dartAppVersion(read(appVersion)) !== version) throw new Error('App version mismatch');
  // Bun's lockfile is JSONC; inspect only workspace headers, not dependency versions.
  const lock = read('bun.lock');
  for (const workspace of ['apps/web']) {
    const escaped = workspace.replaceAll('/', '\\/');
    if (
      field(
        lock,
        new RegExp('"' + escaped + '":\\s*\\{\\s*"name":\\s*"[^"]+",\\s*"version":\\s*"([^"]+)"'),
      ) !== version
    )
      throw new Error(`Lockfile mismatch: ${workspace}; run bun install --lockfile-only`);
  }
  if (cargoVersion(read(cargo)) !== version) throw new Error(`Version mismatch: ${cargo}`);
  for (const [name, locked] of cargoLockVersions(read(cargoLock)))
    if (locked !== version)
      throw new Error(`Lockfile mismatch: ${name} in ${cargoLock}; run cargo update --workspace`);
  return version;
}
export function bumpVersion(root: string, next: string): void {
  const current = checkVersions(root);
  const before = parseVersion(current),
    after = parseVersion(next);
  const different = after.findIndex((n, i) => n !== before[i]);
  if (different < 0 || after[different]! < before[different]!)
    throw new Error('Version must increase');
  const read = (file: string) => readFileSync(path.join(root, file), 'utf8');
  const mobileText = read(mobile);
  const mobileCurrent = mobileVersion(mobileText);
  if (mobileCurrent.code >= 2100000000) throw new Error('Flutter Android versionCode exhausted');
  const appVersionText = read(appVersion);
  if (dartAppVersion(appVersionText) !== current) throw new Error('App version mismatch');
  const cargoLines = read(cargo).split('\n');
  const cargoLine = cargoVersionLine(cargoLines);
  // Validate every input before writing anything. No git/network/release side effects.
  const changes = manifests.map((file) => {
    const manifest = JSON.parse(read(file));
    manifest.version = next;
    return [file, JSON.stringify(manifest, null, 2) + '\n'] as const;
  });
  for (const [file, content] of changes) writeFileSync(path.join(root, file), content);
  writeFileSync(
    path.join(root, appVersion),
    appVersionText.replace(/(^|\n)const appVersion = '[^']+';/, `$1const appVersion = '${next}';`),
  );
  writeFileSync(
    path.join(root, mobile),
    mobileText.replace(/(^|\n)version:[^\n]+/, `$1version: ${next}+${mobileCurrent.code + 1}`),
  );
  cargoLines[cargoLine.index] = cargoLines[cargoLine.index]!.replace(
    `"${cargoLine.version}"`,
    `"${next}"`,
  );
  writeFileSync(path.join(root, cargo), cargoLines.join('\n'));
}
if (import.meta.main) {
  const root = path.resolve(import.meta.dir, '..');
  const [command, version, ...extra] = process.argv.slice(2);
  if (command === 'check' && !version) console.log(`Versions synchronized: ${checkVersions(root)}`);
  else if (command === 'bump' && version && !extra.length) {
    bumpVersion(root, version);
    console.log(
      `Bumped to ${version} (Android build ${mobileVersion(readFileSync(path.join(root, mobile), 'utf8')).code}). Run bun install --lockfile-only and cargo update --workspace, then bun run version:check.`,
    );
  } else throw new Error('Usage: bun scripts/version.ts check | bump <version>');
}
