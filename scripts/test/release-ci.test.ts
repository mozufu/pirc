import { afterEach, expect, it } from 'bun:test';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import {
  assetNames,
  checksumAssets,
  releaseNotes,
  releaseTag,
  requireGreenCheck,
  requiredWorkflows,
} from '../release-ci.js';

const dirs: string[] = [];
afterEach(() => dirs.splice(0).forEach((dir) => rmSync(dir, { recursive: true, force: true })));

it('requires an exact stable version tag and its reviewed dated changelog entry', () => {
  expect(releaseTag('v0.7.0', '0.7.0')).toBe('v0.7.0');
  for (const tag of ['main', 'v0.7.1', 'v0.7.0-beta', 'v0.7.0\nmalicious'])
    expect(() => releaseTag(tag, '0.7.0')).toThrow();
  const text =
    '## [Unreleased]\n\nFuture\n\n## [0.7.0] - 2026-10-18\n\nReviewed notes.\n\n## [0.6.1] - 2026-10-17\n\nOld.';
  expect(releaseNotes(text, '0.7.0')).toBe('Reviewed notes.\n');
  expect(() => releaseNotes(text, '0.7.1')).toThrow('Missing');
  expect(() => releaseNotes('## [0.7.0] - 2026-10-18\n\n## [0.6.1]', '0.7.0')).toThrow('empty');
});

it('does not accept a green PR, other commit, branch or incomplete main check', () => {
  const green = { head_sha: 'abc', head_branch: 'main', event: 'push', conclusion: 'success' };
  expect(() => requireGreenCheck([green], 'abc', 'check.yml')).not.toThrow();
  for (const wrong of [
    { ...green, head_sha: 'old' },
    { ...green, head_branch: 'feature' },
    { ...green, event: 'pull_request' },
    { ...green, conclusion: 'failure' },
    { ...green, conclusion: null },
  ])
    expect(() => requireGreenCheck([wrong], 'abc', 'check.yml')).toThrow('must pass');
  expect(() => requireGreenCheck([], 'abc', 'check.yml')).toThrow();
  expect(() =>
    requireGreenCheck([{ ...green, conclusion: 'failure' }, green], 'abc', 'check.yml'),
  ).toThrow();
});

it('requires the pirc 2 client workflow instead of the old Android workflow', () => {
  expect(requiredWorkflows(true)).toEqual(['check.yml', 'client.yml']);
  expect(requiredWorkflows(false)).toEqual(['check.yml']);
});

it('checks the exact asset set and hashes the actual bytes, including optional APK', () => {
  for (const android of [false, true]) {
    const dir = mkdtempSync(path.join(tmpdir(), 'pirc-release-ci-'));
    dirs.push(dir);
    const names = assetNames('0.7.0', android);
    for (const name of names) writeFileSync(path.join(dir, name), 'abc');
    checksumAssets(dir, '0.7.0', android);
    const sum = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
    expect(readFileSync(path.join(dir, 'SHA256SUMS'), 'utf8')).toBe(
      names
        .sort()
        .map((n) => `${sum}  ${n}\n`)
        .join(''),
    );
    rmSync(path.join(dir, 'SHA256SUMS'));
    writeFileSync(path.join(dir, names[0]!), '');
    expect(() => checksumAssets(dir, '0.7.0', android)).toThrow('Empty');
    writeFileSync(path.join(dir, 'local-secret.env'), 'never release');
    expect(() => checksumAssets(dir, '0.7.0', android)).toThrow('Unexpected/missing');
    rmSync(path.join(dir, 'local-secret.env'));
    rmSync(path.join(dir, names[0]!));
    expect(() => checksumAssets(dir, '0.7.0', android)).toThrow('Unexpected/missing');
  }
});
