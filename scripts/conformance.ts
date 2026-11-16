/**
 * Run (or, with `--record`, re-record) the black-box conformance suite
 * (`crates/pirc-conformance`) against the release executables.
 *
 * Linux only: the snapshots are recorded on Linux, the platform CI and
 * deployments use. On macOS `/tmp` is `/private/tmp`, Seatbelt lists Unix
 * sockets and the node warns about its temporary directory, so transcripts
 * differ without the contract changing (historical macOS runtime validation notes
 * indexed in docs/development/historical-records.md). Elsewhere the run is skipped and recording
 * refused, so macOS output never replaces the Linux snapshots.
 */
import path from 'node:path';
import { declaredIgnores, problems, tally } from './conformance-accounting.js';

const record = process.argv.includes('--record');

if (process.platform !== 'linux') {
  if (record) {
    console.error(`conformance: snapshots are recorded on Linux only, not on ${process.platform}`);
    process.exit(1);
  }
  console.log(`conformance: skipped on ${process.platform} (snapshots are Linux's; CI runs them)`);
  process.exit(0);
}

const crate = path.join(import.meta.dir, '..', 'crates', 'pirc-conformance');

// Streamed to the log as it arrives and kept for the accounting below. The
// variables are set here, in the environment `cargo test` builds the crate in:
// its build script turns PIRC_CONFORMANCE_BIN_DIR into the cfg that un-ignores
// the tests that need the executables.
const child = Bun.spawn(['cargo', 'test', '--locked', '-p', 'pirc-conformance', '--no-fail-fast'], {
  env: {
    ...process.env,
    PIRC_CONFORMANCE_REQUIRED: '1',
    PIRC_CONFORMANCE_BIN_DIR: 'target/release',
    INSTA_UPDATE: record ? 'always' : 'no',
  },
  stdin: 'inherit',
  stdout: 'pipe',
  stderr: 'inherit',
});
const decoder = new TextDecoder();
let output = '';
for await (const chunk of child.stdout) {
  const text = decoder.decode(chunk, { stream: true });
  output += text;
  process.stdout.write(text);
}
const exitCode = await child.exited;
if (exitCode !== 0) process.exit(exitCode);

// Exit 0 with everything ignored is what a run that never reached the
// executables looks like; a skip must not count as a pass.
const found = tally(output);
const wrong = problems(found, declaredIgnores(crate));
if (wrong.length > 0) {
  console.error(
    `conformance: the run is not accountable (${found.passed} passed, ${found.ignored} ignored):`,
  );
  for (const problem of wrong) console.error(`  - ${problem}`);
  process.exit(1);
}
console.log(`conformance: ${found.passed} passed, ${found.ignored} ignored (all marked #[ignore])`);
