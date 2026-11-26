import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { requireTestBrowserExecutable } from './test_browser.mjs';

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const vendorDirectory = path.join(scriptDirectory, 'vendor/chart.js-4.5.1');
const chartPath = path.join(vendorDirectory, 'chart.umd.js');
const provenance = JSON.parse(await readFile(path.join(vendorDirectory, 'provenance.json'), 'utf8'));
const chartSource = await readFile(chartPath, 'utf8');
const chartSha256 = createHash('sha256').update(chartSource).digest('hex');
if (chartSha256 !== provenance.assetSha256) {
  throw new Error(`Chart.js checksum mismatch: expected ${provenance.assetSha256}, got ${chartSha256}`);
}

const gatewayRequire = createRequire(new URL('../../../../package.json', import.meta.url));
const { chromium } = gatewayRequire('playwright-core');
const playwrightPackage = JSON.parse(await readFile(gatewayRequire.resolve('playwright-core/package.json'), 'utf8'));
const browserExecutable = requireTestBrowserExecutable();
const outputPath = path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-chart-chromium153.json');
const cases = [];
const viewports = [
  { name: 'phone', width: 390, height: 844 },
  { name: 'tablet', width: 768, height: 1024 },
];

let browser;
try {
  browser = await chromium.launch({ executablePath: browserExecutable, headless: true });
  const browserVersion = browser.version();
  if (!browserVersion.startsWith('153.')) {
    throw new Error(`Expected dedicated Chromium 153, got ${browserVersion}`);
  }

  for (const viewport of viewports) {
    for (const devicePixelRatio of [1, 3]) {
      const containerWidth = viewport.width - 40;
      const chartHeight = 240;
      const context = await browser.newContext({ viewport, deviceScaleFactor: devicePixelRatio });
      const page = await context.newPage();
      const blockedRequests = [];
      await page.route('**/*', async (route) => {
        blockedRequests.push(route.request().url());
        await route.abort('blockedbyclient');
      });

      const html = `<!doctype html>
<html><head><meta charset="utf-8"><style>html,body{margin:0;padding:0}#chart-container{position:relative;margin-left:20px;width:${containerWidth}px;height:${chartHeight}px}#chart{display:block;box-sizing:border-box;width:${containerWidth}px;height:${chartHeight}px}</style></head>
<body><div id="chart-container"><canvas id="chart" width="${containerWidth * devicePixelRatio}" height="${chartHeight * devicePixelRatio}" style="display:block;box-sizing:border-box;width:${containerWidth}px;height:${chartHeight}px"></canvas></div></body></html>`;
      await page.setContent(html, { waitUntil: 'load' });
      await page.addScriptTag({ content: chartSource });
      const result = await page.evaluate(async ({ viewport, devicePixelRatio, containerWidth, chartHeight }) => {
        const container = document.getElementById('chart-container');
        const canvas = document.getElementById('chart');
        const context = canvas.getContext('2d');
        context.fillStyle = '#ff00ff';
        context.fillRect(0, 0, 2, 2);
        const beforeNoopWrites = {
          width: canvas.width,
          height: canvas.height,
          pixelAlpha: context.getImageData(0, 0, 1, 1).data[3],
          fillStyle: context.fillStyle,
        };
        canvas.width = canvas.width;
        canvas.height = canvas.height;
        const afterNoopWrites = {
          width: canvas.width,
          height: canvas.height,
          pixelAlpha: context.getImageData(0, 0, 1, 1).data[3],
          fillStyle: context.fillStyle,
        };

        const constructor = { succeeded: false, error: null };
        let chart;
        try {
          chart = new Chart(canvas, {
            type: 'bar',
            data: {
              labels: ['A', 'B'],
              datasets: [{ label: 'Data', data: [3, 7], backgroundColor: '#3b82f6' }],
            },
            options: {
              responsive: true,
              animation: false,
              maintainAspectRatio: false,
              devicePixelRatio,
            },
          });
          constructor.succeeded = true;
        } catch (error) {
          constructor.error = `${error.name}: ${error.message}`;
        }

        const waitForLayout = async () => {
          await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
          await new Promise((resolve) => setTimeout(resolve, 100));
        };
        const measure = () => {
          const rect = canvas.getBoundingClientRect();
          const bars = chart.getDatasetMeta(0).data.map((element, index) => {
            const geometry = element.getProps(['x', 'y', 'base', 'width', 'height'], true);
            return {
              index,
              label: chart.data.labels[index],
              value: chart.data.datasets[0].data[index],
              x: geometry.x,
              y: geometry.y,
              base: geometry.base,
              width: geometry.width,
              height: geometry.height,
            };
          });
          return {
            chart: {
              width: chart.width,
              height: chart.height,
              currentDevicePixelRatio: chart.currentDevicePixelRatio,
            },
            windowDevicePixelRatio: window.devicePixelRatio,
            canvas: {
              widthAttribute: canvas.width,
              heightAttribute: canvas.height,
              css: {
                display: getComputedStyle(canvas).display,
                boxSizing: getComputedStyle(canvas).boxSizing,
                width: getComputedStyle(canvas).width,
                height: getComputedStyle(canvas).height,
              },
              rect: {
                x: rect.x,
                y: rect.y,
                width: rect.width,
                height: rect.height,
              },
            },
            bars,
            labels: [...chart.data.labels],
            defaultFont: {
              chart: { ...Chart.defaults.font },
              canvas: context.font,
            },
          };
        };

        let initial = null;
        let afterDataUpdate = null;
        let responsiveWidthChange = null;
        let measurementError = null;
        if (constructor.succeeded) {
          try {
            await waitForLayout();
            initial = measure();
            chart.data.datasets[0].data = [6, 2];
            chart.update('none');
            await waitForLayout();
            afterDataUpdate = measure();

            const changedWidth = containerWidth + 20;
            container.style.width = `${changedWidth}px`;
            canvas.style.width = `${changedWidth}px`;
            await waitForLayout();
            responsiveWidthChange = {
              containerCssWidth: getComputedStyle(container).width,
              canvasCssWidth: getComputedStyle(canvas).width,
              measurement: measure(),
            };
          } catch (error) {
            measurementError = `${error.name}: ${error.message}`;
          }
        }
        return {
          viewport,
          devicePixelRatio,
          requestedLayout: {
            containerCssWidth: `${containerWidth}px`,
            containerCssHeight: `${chartHeight}px`,
            canvasCssWidth: `${containerWidth}px`,
            canvasCssHeight: `${chartHeight}px`,
            canvasWidthAttribute: containerWidth * devicePixelRatio,
            canvasHeightAttribute: chartHeight * devicePixelRatio,
          },
          sameValueAttributeWrites: {
            before: beforeNoopWrites,
            after: afterNoopWrites,
            clearedBitmap: beforeNoopWrites.pixelAlpha > 0 && afterNoopWrites.pixelAlpha === 0,
            resetContextState: beforeNoopWrites.fillStyle !== afterNoopWrites.fillStyle,
          },
          constructor,
          initial,
          afterDataUpdate,
          responsiveWidthChange,
          measurementError,
          chartVersion: globalThis.Chart?.version ?? null,
        };
      }, { viewport, devicePixelRatio, containerWidth, chartHeight });

      const requestsObserved = blockedRequests.length;
      await context.close();
      if (requestsObserved !== 0) {
        throw new Error(`The browser attempted ${requestsObserved} network request(s): ${blockedRequests.join(', ')}`);
      }
      if (!result.constructor.succeeded || result.chartVersion !== provenance.version || result.measurementError) {
        throw new Error(`Chart.js capture failed for ${viewport.name} DPR ${devicePixelRatio}: ${JSON.stringify(result)}`);
      }
      const caseId = `${viewport.name}_${viewport.width}x${viewport.height}_dpr${devicePixelRatio}`;
      const { viewport: capturedViewport, devicePixelRatio: capturedDpr, afterDataUpdate: updated, ...caseDetails } = result;
      cases.push({
        caseId,
        viewport: capturedViewport,
        dpr: capturedDpr,
        ...caseDetails,
        updated,
        networkRequests: requestsObserved,
      });
    }
  }

  const fixture = {
    schemaVersion: 1,
      oracle: 'Dedicated Playwright-pinned Chromium 153 headless shell. All browser requests are blocked; the page uses setContent and the pinned inline Chart.js UMD source.',
    browser: {
      product: 'Chromium Headless Shell',
      version: browserVersion,
      executable: path.basename(browserExecutable),
      playwrightVersion: playwrightPackage.version,
    },
    chartJs: {
      package: provenance.package,
      version: provenance.version,
      license: provenance.license,
      sha256: chartSha256,
      vendorPath: 'apps/android/tool/parity/vendor/chart.js-4.5.1/chart.umd.js',
    },
    chart: {
      type: 'bar',
      labels: ['A', 'B'],
      initialData: [3, 7],
      updateData: [6, 2],
      backgroundColor: '#3b82f6',
      options: {
        responsive: true,
        animation: false,
        maintainAspectRatio: false,
        devicePixelRatio: 'per case',
      },
    },
    captureNotes: {
      canvasCommandRecorder: false,
      sameValueAttributeWrites: 'Canvas width and height are assigned their existing values before Chart.js construction; bitmap and 2D context reset behavior are recorded.',
      interaction: 'Chart data update is captured; native canvas click interaction is outside this browser reference.',
      nativeFontComparison: 'Chromium font metadata is recorded, but native system fonts may differ; compare geometry with explicit font tolerance rather than requiring exact text metrics.',
    },
    cases,
  };
  await writeFile(outputPath, `${JSON.stringify(fixture)}\n`);
  console.log(JSON.stringify({ outputPath, browserVersion, playwrightVersion: playwrightPackage.version, chartSha256, cases: cases.length }));
} finally {
  if (browser) await browser.close();
}
