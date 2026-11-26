/**
 * The conformance run's own bookkeeping: what libtest reports for
 * `pirc-conformance`, checked so that a run which silently executed nothing
 * cannot look green.
 *
 * Tests that need the built executables are `ignore`d unless the crate's build
 * script saw `PIRC_CONFORMANCE_BIN_DIR` (crates/pirc-conformance/build.rs).
 * `scripts/conformance.ts` sets the variable, so every such test must have run.
 * If the variable stopped reaching the build they would all be ignored and
 * `cargo test` would still exit 0; these checks turn that into a failure.
 */
import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';

export type Tally = { passed: number; failed: number; ignored: number; suites: number };

/**
 * Fewer passes than this means the suite did not run. Lower it only when tests are
 * removed on purpose. M4.10 removed the assistant chat mode, chat projects,
 * delegations and assistant-memory tests, so the first-send rewrite (M4.11) runs
 * the remaining suite. The declared ignores are the live Web/native-client
 * acceptance runs and terminal scenarios that need an isolated-terminal backend.
 */
export const MIN_PASSED = 232;

/** The sum of every `test result:` line of a `cargo test` output. */
export function tally(output: string): Tally {
  const total: Tally = { passed: 0, failed: 0, ignored: 0, suites: 0 };
  for (const line of output.split('\n')) {
    const found = /^test result: \w+\. (\d+) passed; (\d+) failed; (\d+) ignored;/.exec(line);
    if (!found) continue;
    total.passed += Number(found[1]);
    total.failed += Number(found[2]);
    total.ignored += Number(found[3]);
    total.suites += 1;
  }
  return total;
}

function rustFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) return rustFiles(file);
    return entry.name.endsWith('.rs') ? [file] : [];
  });
}

/**
 * Tests the crate ignores on purpose (`#[ignore = "..."]`: the live browser and
 * native-client acceptance runs). The environment-gated `cfg_attr` ignore is
 * not one of them: with the executables present it must not apply.
 */
export function declaredIgnores(crate: string): number {
  let count = 0;
  for (const dir of ['tests', 'src']) {
    for (const file of rustFiles(path.join(crate, dir))) {
      for (const line of readFileSync(file, 'utf8').split('\n')) {
        if (/^\s*#\[ignore\b/.test(line)) count += 1;
      }
    }
  }
  return count;
}

/** What is wrong with the run's totals; empty when it is accountable. */
export function problems(found: Tally, intentionallyIgnored: number, minPassed = MIN_PASSED) {
  const list: string[] = [];
  if (found.suites === 0) list.push('no `test result:` line was found in the cargo output');
  if (found.ignored !== intentionallyIgnored) {
    list.push(
      `${found.ignored} tests were ignored, expected only the ${intentionallyIgnored} marked ` +
        `#[ignore] (the environment-gated ones must have run: is PIRC_CONFORMANCE_BIN_DIR ` +
        `set when the crate is built?)`,
    );
  }
  if (found.passed < minPassed) {
    list.push(`only ${found.passed} tests passed, at least ${minPassed} are expected`);
  }
  return list;
}
