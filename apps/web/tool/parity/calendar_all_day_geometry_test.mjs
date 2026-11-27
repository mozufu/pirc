import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdir, readFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { requireTestBrowserExecutable } from '../../../../scripts/e2e/test_browser.mjs';
import { createServer } from 'vite';

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(scriptDirectory, '../../../..');
const webRoot = resolve(repositoryRoot, 'apps/web');
const fixture = JSON.parse(
  await readFile(resolve(repositoryRoot, 'fixtures/mobile-parity/calendar.json'), 'utf8'),
);
const captureDirectory = process.env.PIRC_CALENDAR_CAPTURE_DIR;
if (captureDirectory) await mkdir(captureDirectory, { recursive: true });
const server = await createServer({
  root: webRoot,
  configFile: resolve(webRoot, 'vite.config.ts'),
  server: { host: '127.0.0.1', port: 18992, strictPort: true, fs: { allow: [repositoryRoot] } },
  plugins: [
    {
      name: 'calendar-geometry-test',
      configureServer(vite) {
        vite.middlewares.use('/calendar-geometry-test.html', async (_request, response, next) => {
          try {
            const html = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>html,body,#root{height:100%;margin:0}body{overflow:hidden}</style></head><body><div id="root"></div><script type="module">
import '/src/app.css';
import { mount } from 'svelte';
import SchedulesPage from '/src/lib/components/SchedulesPage.svelte';
import { app } from '/src/lib/app.svelte.ts';
import { i18n } from '/src/lib/i18n.svelte.ts';
const fixture = ${JSON.stringify(fixture)};
const originalFetch = window.fetch.bind(window);
window.fetch = async (input, init = {}) => {
  const url = new URL(typeof input === 'string' ? input : input.url, location.href);
  if (url.pathname === '/api/calendar/context') return new Response(JSON.stringify({accountKey:'calendar-geometry-test',reminderDeliveryAvailable:true}), {headers:{'Content-Type':'application/json'}});
  if (url.pathname === '/api/calendar') return new Response(JSON.stringify({...fixture,accountKey:'calendar-geometry-test'}), {headers:{'Content-Type':'application/json'}});
  if (url.pathname === '/api/calendar/permissions') return new Response(JSON.stringify({allowRead:false,allowPropose:false}), {headers:{'Content-Type':'application/json'}});
  return originalFetch(input, init);
};
localStorage.setItem('pirc.calendar.preferences.v1:calendar-geometry-test', JSON.stringify({view:'month',timezone:'Asia/Taipei',weekStart:'monday'}));
app.loading = false; app.demo = undefined; app.connection = 'connected'; app.scheduleRevision = 0; app.view = 'schedules';
i18n.setLanguage('en');
window.calendarUnmount = mount(SchedulesPage, {target:document.querySelector('#root'),props:{onopenchat:()=>{}}});
</script></body></html>`;
            response.setHeader('Content-Type', 'text/html; charset=utf-8');
            response.end(await vite.transformIndexHtml('/calendar-geometry-test.html', html));
          } catch (error) {
            next(error);
          }
        });
      },
    },
  ],
});

const require = createRequire(resolve(webRoot, 'package.json'));
const { chromium } = require('playwright-core');
let browser;

function assertFullSpan(geometry, view) {
  assert.ok(geometry, `${view} all-day span and date columns render`);
  assert.ok(
    Math.abs(geometry.bar.left - geometry.start.left - 4) <= 1,
    `${view} span begins inside Oct 20: ${JSON.stringify(geometry)}`,
  );
  assert.ok(
    Math.abs(geometry.bar.right - geometry.end.right + 4) <= 1,
    `${view} span ends at the exclusive Oct 23 boundary: ${JSON.stringify(geometry)}`,
  );
}

try {
  await server.listen();
  browser = await chromium.launch({
    executablePath: requireTestBrowserExecutable(),
    headless: true,
  });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.stack || error.message));
  page.on('console', (message) => {
    if (message.type() === 'error') errors.push(message.text());
  });

  await page.goto(
    'http://127.0.0.1:18992/calendar-geometry-test.html?open=calendar&view=month&date=2026-10-21',
  );
  await page.locator('.calendar-page').waitFor({ timeout: 15000 });
  await page.waitForFunction(() =>
    document.querySelector('.sync-state')?.textContent?.includes('Synced'),
  );
  const monthGeometry = await page.evaluate(() => {
    const bar = [...document.querySelectorAll('.month-span')].find(
      (element) => element.textContent?.trim() === 'Team retreat',
    );
    const start = document.querySelector('.month-day[data-date="2026-10-20"]');
    const end = document.querySelector('.month-day[data-date="2026-10-22"]');
    if (!bar || !start || !end) return null;
    const bounds = (element) => {
      const rect = element.getBoundingClientRect();
      return { left: rect.left, right: rect.right };
    };
    return { bar: bounds(bar), start: bounds(start), end: bounds(end) };
  });
  assertFullSpan(monthGeometry, 'month');
  if (captureDirectory)
    await page.screenshot({
      path: resolve(captureDirectory, 'calendar-month-light.png'),
      fullPage: true,
    });

  await page.locator('.view-tabs button').filter({ hasText: 'Week' }).click();
  await page.locator('.time-scroll').waitFor();
  const weekGeometry = await page.evaluate(() => {
    const bar = [...document.querySelectorAll('.all-day-span')].find((element) =>
      element.textContent?.includes('Team retreat'),
    );
    const start = document.querySelector('.all-day-cell[data-date="2026-10-20"]');
    const end = document.querySelector('.all-day-cell[data-date="2026-10-22"]');
    if (!bar || !start || !end) return null;
    const bounds = (element) => {
      const rect = element.getBoundingClientRect();
      return { left: rect.left, right: rect.right };
    };
    return { bar: bounds(bar), start: bounds(start), end: bounds(end) };
  });
  assertFullSpan(weekGeometry, 'week');
  if (captureDirectory)
    await page.screenshot({
      path: resolve(captureDirectory, 'calendar-week-light.png'),
      fullPage: true,
    });

  await page.locator('.view-tabs button').filter({ hasText: 'Day' }).click();
  await page.locator('.time-scroll').waitFor();
  await page.waitForFunction(() =>
    document.querySelector('.sync-state')?.textContent?.includes('Synced'),
  );
  const dayGeometry = await page.evaluate(() => {
    const bar = [...document.querySelectorAll('.all-day-span')].find((element) =>
      element.textContent?.includes('Team retreat'),
    );
    const cell = document.querySelector('.all-day-cell[data-date="2026-10-21"]');
    if (!bar || !cell) return null;
    const bounds = (element) => {
      const rect = element.getBoundingClientRect();
      return { left: rect.left, right: rect.right };
    };
    return { bar: bounds(bar), cell: bounds(cell) };
  });
  assert.ok(dayGeometry, 'day view shows an all-day item that started earlier in its week');
  assert.ok(
    Math.abs(dayGeometry.bar.left - dayGeometry.cell.left - 4) <= 1,
    `day span starts inside the selected day: ${JSON.stringify(dayGeometry)}`,
  );
  assert.ok(
    Math.abs(dayGeometry.bar.right - dayGeometry.cell.right + 4) <= 1,
    `day span ends at the selected day boundary: ${JSON.stringify(dayGeometry)}`,
  );
  if (captureDirectory)
    await page.screenshot({
      path: resolve(captureDirectory, 'calendar-day-light.png'),
      fullPage: true,
    });

  await page.locator('.view-tabs button').filter({ hasText: 'Week' }).click();
  const agentEntry = page.locator('.time-entry.agent-entry').first();
  assert.equal(await agentEntry.locator('strong').innerText(), '11:00 · Daily summary');
  const agentGeometry = await agentEntry.evaluate((element) => {
    const button = element.getBoundingClientRect();
    const text = element.querySelector('strong').getBoundingClientRect();
    return {
      textBottom: text.bottom,
      buttonBottom: button.bottom,
      smallCount: element.querySelectorAll('small').length,
    };
  });
  assert.equal(agentGeometry.smallCount, 0, 'agent timeline point has one text line');
  assert.ok(
    agentGeometry.textBottom <= agentGeometry.buttonBottom,
    `agent title fits its point: ${JSON.stringify(agentGeometry)}`,
  );
  assert.deepEqual(errors, [], 'calendar renders without browser errors');
  console.log(JSON.stringify({ monthGeometry, weekGeometry, dayGeometry, agentGeometry }, null, 2));
  await page.close();
} finally {
  if (browser) await browser.close();
  await server.close();
}
