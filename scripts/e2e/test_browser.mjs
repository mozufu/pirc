// Automation must never launch the user's everyday browser executable/profile.
import {
  accessSync,
  constants,
  existsSync,
  readFileSync,
  readdirSync,
  realpathSync,
} from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const require = createRequire(import.meta.url);
const packageRoot = path.dirname(
  require.resolve('playwright-core/package.json', { paths: [repositoryRoot] }),
);
export const testBrowserCache = path.join(repositoryRoot, '.pirc/test-browsers');
export const playwrightCli = path.join(packageRoot, 'cli.js');
const manifest = JSON.parse(readFileSync(path.join(packageRoot, 'browsers.json'), 'utf8'));
const shell = manifest.browsers.find((browser) => browser.name === 'chromium-headless-shell');
const executableNames = new Set([
  'chrome-headless-shell',
  'headless_shell',
  'headless_shell.exe',
  'Google Chrome for Testing',
  'chrome.exe',
]);
function findShell(directory, depth = 0) {
  if (depth > 4 || !existsSync(directory)) return null;
  const entries = readdirSync(directory, { withFileTypes: true });
  for (const entry of entries)
    if (entry.isFile() && executableNames.has(entry.name)) return path.join(directory, entry.name);
  for (const entry of entries)
    if (entry.isDirectory()) {
      const found = findShell(path.join(directory, entry.name), depth + 1);
      if (found) return found;
    }
  return null;
}

export function validateTestBrowserExecutable(candidate) {
  const resolved = realpathSync(candidate);
  const name = path.basename(resolved);
  const isShell = ['chrome-headless-shell', 'headless_shell', 'headless_shell.exe'].includes(name);
  const isTestingApp =
    name === 'Google Chrome for Testing' &&
    resolved.includes('Google Chrome for Testing.app' + path.sep);
  const isWindowsTesting =
    name === 'chrome.exe' &&
    resolved.includes(path.sep + 'chrome-win64' + path.sep) &&
    !resolved.toLowerCase().includes('program files');
  if (!isShell && !isTestingApp && !isWindowsTesting) {
    throw new Error(
      'Refusing an everyday browser executable. Use a dedicated Headless Shell or Chrome for Testing; never Google Chrome.app or your normal profile.',
    );
  }
  accessSync(resolved, constants.X_OK);
  return resolved;
}

export function requireTestBrowserExecutable(override = process.env.PIRC_TEST_BROWSER) {
  const candidate =
    override || findShell(path.join(testBrowserCache, 'chromium_headless_shell-' + shell.revision));
  if (!candidate)
    throw new Error(
      'Dedicated test browser is missing. Run: node scripts/e2e/install_test_browser.mjs. No fallback to your everyday Chrome is allowed.',
    );
  return validateTestBrowserExecutable(candidate);
}
