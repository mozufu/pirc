import { spawnSync } from 'node:child_process';
import { playwrightCli, testBrowserCache } from './test_browser.mjs';
const result = spawnSync(process.execPath, [playwrightCli, 'install', 'chromium-headless-shell'], {
  stdio: 'inherit',
  env: { ...process.env, PLAYWRIGHT_BROWSERS_PATH: testBrowserCache },
});
process.exitCode = result.status ?? 1;
