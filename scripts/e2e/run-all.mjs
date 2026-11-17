/** Run the cross-layer checks (V1, V2, V3): `node scripts/e2e/run-all.mjs`.
 *
 *   --only v1,v2,v3     run a subset
 *   --web-tree <path>   serve this checkout's apps/web in V1 (e.g. a clean
 *                       worktree of HEAD, to test the committed sanitiser)
 *   --old-sanitiser     also run V1 against the web app of commit 645b262f, whose
 *                       sanitiser keeps same-origin form actions, so the previewed
 *                       forms really reach the Gateway (temporary worktree, removed)
 *
 * Builds the current Gateway and Node once (cargo build --locked), runs each
 * script as a child process, prints a summary and exits non-zero if any failed.
 * Every run uses fresh temporary directories and stops every process it starts.
 */
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import { buildCurrent, coverage, git } from './lib.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const value = (flag) => (args.includes(flag) ? args[args.indexOf(flag) + 1] : undefined);
const only = (value('--only') ?? 'v1,v2,v3').split(',');
const steps = [
  ['v1', 'v1-hostile-forms.mjs'],
  ['v2', 'v2-proxy.mjs'],
  ['v2', 'v2-proxy-config.mjs'],
  ['v3', 'v3-compat.mjs'],
].filter(([group]) => only.includes(group));

console.log('coverage:', JSON.stringify(coverage(), null, 1));
buildCurrent();
const env = { ...process.env, PIRC_E2E_SKIP_BUILD: '1' };
if (value('--web-tree')) env.PIRC_E2E_WEB_TREE = path.resolve(value('--web-tree'));
const summary = [];
for (const [, script] of steps) {
  console.log(`\n=== ${script} ===`);
  const started = Date.now();
  const result = spawnSync(process.execPath, [path.join(here, script)], { stdio: 'inherit', env });
  summary.push([
    script,
    result.status === 0 ? 'passed' : `FAILED (exit ${result.status})`,
    ((Date.now() - started) / 1000).toFixed(0) + 's',
  ]);
}
if (args.includes('--old-sanitiser') && only.includes('v1')) {
  const tree = path.join(os.tmpdir(), `pe-oldweb-${process.pid}`);
  git('worktree', 'add', '--detach', tree, '645b262f');
  try {
    console.log('\n=== v1-hostile-forms.mjs (web app of 645b262f) ===');
    const started = Date.now();
    const result = spawnSync(process.execPath, [path.join(here, 'v1-hostile-forms.mjs')], {
      stdio: 'inherit',
      env: { ...env, PIRC_E2E_WEB_TREE: tree },
    });
    summary.push([
      'v1-hostile-forms.mjs (old sanitiser)',
      result.status === 0 ? 'passed' : `FAILED (exit ${result.status})`,
      ((Date.now() - started) / 1000).toFixed(0) + 's',
    ]);
  } finally {
    git('worktree', 'remove', '--force', tree);
  }
}
console.log('\n=== summary ===');
for (const [script, outcome, took] of summary)
  console.log(`${outcome.padEnd(18)} ${script} (${took})`);
process.exit(summary.some(([, outcome]) => outcome !== 'passed') ? 1 : 0);
