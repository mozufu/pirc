/** Release metadata and final asset validation; never publishes by itself. */
import { createHash } from 'node:crypto';
import {
  appendFileSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  writeFileSync,
} from 'node:fs';
import path from 'node:path';
import { checkVersions, parseVersion } from './version.js';

export function releaseNotes(changelog: string, version: string): string {
  parseVersion(version);
  const heading = new RegExp(
    `^## \\[${version.replaceAll('.', '\\.')}\\] - \\d{4}-\\d{2}-\\d{2}$`,
    'm',
  );
  const found = heading.exec(changelog);
  if (!found) throw new Error(`Missing dated changelog entry for ${version}`);
  const rest = changelog.slice(found.index + found[0].length);
  const notes = rest.split(/^## /m)[0]!.trim();
  if (!notes) throw new Error('Release notes are empty');
  return notes + '\n';
}

export function releaseTag(tag: string, version: string): string {
  parseVersion(version);
  if (tag !== `v${version}`) throw new Error(`Tag must be v${version}`);
  return tag;
}

type Run = { head_sha: string; head_branch: string; event: string; conclusion: string | null };
export function requireGreenCheck(runs: Run[], commit: string, workflow: string): void {
  const latest = runs.find(
    (run) => run.head_sha === commit && run.head_branch === 'main' && run.event === 'push',
  );
  if (latest?.conclusion !== 'success')
    throw new Error(
      `${workflow} must pass on main at ${commit}; wait for CI or fix it before releasing`,
    );
}

/** Main-branch workflows that must be green at the exact release commit. */
export function requiredWorkflows(android: boolean): string[] {
  return ['check.yml', ...(android ? ['client.yml'] : [])];
}

export function assetNames(version: string, android: boolean): string[] {
  parseVersion(version);
  return [
    `pirc-v${version}-darwin-arm64.tar.gz`,
    `pirc-web-v${version}.tar.gz`,
    ...(android ? [`pirc-${version}-beta.apk`] : []),
  ];
}

export function checksumAssets(dir: string, version: string, android: boolean): void {
  const expected = assetNames(version, android).sort();
  const actual = readdirSync(dir).sort();
  if (JSON.stringify(actual) !== JSON.stringify(expected))
    throw new Error(`Unexpected/missing release assets: ${actual.join(', ')}`);
  const sums = expected
    .map((file) => {
      if (!lstatSync(path.join(dir, file)).isFile())
        throw new Error(`Not a regular release asset: ${file}`);
      const bytes = readFileSync(path.join(dir, file));
      if (!bytes.length) throw new Error(`Empty release asset: ${file}`);
      return `${createHash('sha256').update(bytes).digest('hex')}  ${file}\n`;
    })
    .join('');
  writeFileSync(path.join(dir, 'SHA256SUMS'), sums);
}

function git(...args: string[]): string {
  const result = Bun.spawnSync(['git', ...args], { stdout: 'pipe', stderr: 'pipe' });
  if (result.exitCode) throw new Error(result.stderr.toString());
  return result.stdout.toString().trim();
}

if (import.meta.main) {
  const root = path.resolve(import.meta.dir, '..');
  const command = process.argv[2];
  const version = checkVersions(root);
  const android = process.env.RELEASE_ANDROID === 'true';
  if (command === 'prepare') {
    const tag = releaseTag(process.env.RELEASE_TAG ?? '', version);
    const commit = git('rev-parse', 'HEAD');
    if (git('cat-file', '-t', `refs/tags/${tag}`) !== 'tag')
      throw new Error('Use an annotated release tag');
    if (git('rev-parse', `refs/tags/${tag}^{commit}`) !== commit)
      throw new Error('Checkout does not match tag');
    git('merge-base', '--is-ancestor', commit, 'origin/main');
    if (git('status', '--porcelain')) throw new Error('Release checkout must be clean');
    for (const workflow of requiredWorkflows(android)) {
      const result = Bun.spawnSync(
        [
          'gh',
          'api',
          '--method',
          'GET',
          `repos/${process.env.GITHUB_REPOSITORY}/actions/workflows/${workflow}/runs`,
          '-f',
          `head_sha=${commit}`,
          '-f',
          'branch=main',
          '-f',
          'event=push',
          '-f',
          'per_page=100',
        ],
        { stdout: 'pipe', stderr: 'pipe' },
      );
      if (result.exitCode) throw new Error(result.stderr.toString());
      requireGreenCheck(JSON.parse(result.stdout.toString()).workflow_runs, commit, workflow);
    }
    let notes = releaseNotes(readFileSync(path.join(root, 'CHANGELOG.md'), 'utf8'), version);
    notes +=
      '\n## Build assets\n\nmacOS ARM64 binaries are not Developer ID signed or notarized. Web static files are included separately.\n';
    notes += android
      ? '\nAndroid APK: standard flavor (`org.mozufu.pirc`), signed with the configured CI identity. This does not certify physical-device or remote-push acceptance.\n'
      : '\nAndroid APK was not requested for this release.\n';
    mkdirSync(path.join(root, 'dist/ci'), { recursive: true });
    writeFileSync(path.join(root, 'dist/ci/RELEASE.md'), notes);
    if (!process.env.GITHUB_OUTPUT) throw new Error('GITHUB_OUTPUT is required');
    appendFileSync(
      process.env.GITHUB_OUTPUT,
      `version=${version}\ntag=${tag}\ncommit=${commit}\nandroid=${android}\n`,
    );
  } else if (command === 'checksums') {
    checksumAssets(path.join(root, 'dist/ci/assets'), version, android);
  } else throw new Error('Expected prepare or checksums');
}
