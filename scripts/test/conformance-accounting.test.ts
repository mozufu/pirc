import { afterEach, expect, it } from 'bun:test';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { tmpdir } from 'node:os';
import { MIN_PASSED, declaredIgnores, problems, tally } from '../conformance-accounting.js';

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

const suite = (passed: number, ignored: number, failed = 0) =>
  `test result: ${failed ? 'FAILED' : 'ok'}. ${passed} passed; ${failed} failed; ${ignored} ignored; 0 measured; 0 filtered out; finished in 0.10s`;

it('adds up every suite of a cargo test output', () => {
  const output = [
    '     Running tests/a.rs (target/debug/deps/a-1)',
    suite(4, 1),
    '   Doc-tests pirc_conformance',
    suite(0, 0),
    'running 1 test',
  ].join('\n');
  expect(tally(output)).toEqual({ passed: 4, failed: 0, ignored: 1, suites: 2 });
});

it('accepts a run that executed the suite and ignored only what is marked', () => {
  expect(problems({ passed: 280, failed: 0, ignored: 5, suites: 80 }, 5)).toEqual([]);
});

it('rejects a run where the gated tests were ignored (the executables never reached the build)', () => {
  const list = problems(tally(suite(15, 270)), 5);
  expect(list).toHaveLength(2);
  expect(list[0]).toContain('270 tests were ignored');
  expect(list[1]).toContain('only 15 tests passed');
});

it('rejects output without results and runs below the lower bound', () => {
  expect(problems(tally('nothing'), 0)[0]).toContain('no `test result:`');
  expect(problems({ passed: MIN_PASSED - 1, failed: 0, ignored: 0, suites: 3 }, 0)).toHaveLength(1);
});

it('counts only deliberate #[ignore] attributes in the crate', () => {
  const crate = mkdtempSync(path.join(tmpdir(), 'pirc-conformance-'));
  dirs.push(crate);
  mkdirSync(path.join(crate, 'tests/support'), { recursive: true });
  mkdirSync(path.join(crate, 'src'), { recursive: true });
  writeFileSync(
    path.join(crate, 'tests/a.rs'),
    '#[ignore = "live"]\n#[cfg_attr(not(conformance_enabled), ignore = "gated")]\n#[test]\nfn a() {}\n',
  );
  writeFileSync(path.join(crate, 'tests/support/mod.rs'), '    #[ignore]\n#[test]\nfn b() {}\n');
  writeFileSync(path.join(crate, 'src/lib.rs'), '// #[ignore] in a comment\n');
  expect(declaredIgnores(crate)).toBe(2);
});
