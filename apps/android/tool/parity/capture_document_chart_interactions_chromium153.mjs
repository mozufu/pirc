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
const outputPath = path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-chart-interactions-chromium153.json');
const cases = [];
const viewports = [
  { name: 'phone', width: 390, height: 844 },
  { name: 'tablet', width: 768, height: 1024 },
];
const chartHeight = 240;

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
      const context = await browser.newContext({
        viewport: { width: viewport.width, height: viewport.height },
        deviceScaleFactor: devicePixelRatio,
        hasTouch: true,
      });
      const page = await context.newPage();
      const blockedRequests = [];
      await page.route('**/*', async (route) => {
        blockedRequests.push(route.request().url());
        await route.abort('blockedbyclient');
      });

      const html = `<!doctype html>
<html><head><meta charset="utf-8"><style>html,body{margin:0;padding:0}#chart-container{position:relative;margin-left:20px;width:${containerWidth}px;height:${chartHeight}px}#chart{display:block;box-sizing:border-box;width:${containerWidth}px;height:${chartHeight}px;touch-action:auto}</style></head>
<body><div id="chart-container"><canvas id="chart" width="${containerWidth * devicePixelRatio}" height="${chartHeight * devicePixelRatio}" style="display:block;box-sizing:border-box;width:${containerWidth}px;height:${chartHeight}px;touch-action:auto"></canvas></div></body></html>`;
      await page.setContent(html, { waitUntil: 'load' });
      await page.addScriptTag({ content: chartSource });
      const initialization = await page.evaluate(({ devicePixelRatio }) => {
        const canvas = document.getElementById('chart');
        const chartClicks = [];
        const nativeCanvasEvents = [];
        const chart = new Chart(canvas, {
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
            onClick(event, activeElements) {
              chartClicks.push({
                kind: event.type,
                nativeType: event.native?.type ?? null,
                x: event.x,
                y: event.y,
                inChartArea: event.inChartArea,
                active: activeElements.map(({ datasetIndex, index }) => ({ datasetIndex, index })),
              });
            },
          },
        });
        const observedTypes = ['pointerdown', 'pointerup', 'touchstart', 'touchmove', 'touchend', 'click', 'mousemove', 'mouseout'];
        for (const type of observedTypes) {
          canvas.addEventListener(type, (event) => {
            const touch = event.changedTouches?.[0] ?? event.touches?.[0] ?? null;
            nativeCanvasEvents.push({
              type: event.type,
              pointerType: event.pointerType ?? null,
              clientX: event.clientX ?? touch?.clientX ?? null,
              clientY: event.clientY ?? touch?.clientY ?? null,
              isTrusted: event.isTrusted,
            });
          }, true);
        }
        window.__chartInteractions = {
          chart,
          chartClicks,
          nativeCanvasEvents,
          clearEvents() {
            chartClicks.length = 0;
            nativeCanvasEvents.length = 0;
          },
          snapshot() {
            const rect = canvas.getBoundingClientRect();
            const tooltip = chart.tooltip;
            const tooltipOptions = tooltip.options;
            const tooltipTitleFont = tooltipOptions.titleFont;
            const tooltipBodyFont = tooltipOptions.bodyFont;
            const tooltipFooterFont = tooltipOptions.footerFont;
            const legend = chart.legend;
            const legendHitBoxes = (legend?.legendHitBoxes ?? []).map((box, index) => {
              const item = legend.legendItems[index] ?? {};
              return {
                text: item.text ?? null,
                datasetIndex: item.datasetIndex ?? null,
                hidden: item.hidden ?? null,
                left: box.left,
                top: box.top,
                width: box.width,
                height: box.height,
                centerPageX: rect.x + box.left + box.width / 2,
                centerPageY: rect.y + box.top + box.height / 2,
              };
            });
            const active = (elements) => elements.map(({ datasetIndex, index }) => ({ datasetIndex, index }));
            const tooltipBounds = {
              x: tooltip.x ?? null,
              y: tooltip.y ?? null,
              width: tooltip.width ?? null,
              height: tooltip.height ?? null,
            };
            const backgroundSample = tooltip.opacity > 0 ? (() => {
              const localX = tooltip.x + 8;
              const localY = tooltip.y + 3;
              const pixelX = Math.floor(localX * chart.currentDevicePixelRatio);
              const pixelY = Math.floor(localY * chart.currentDevicePixelRatio);
              return {
                localX,
                localY,
                pixelX,
                pixelY,
                rgba: Array.from(canvas.getContext('2d').getImageData(pixelX, pixelY, 1, 1).data),
              };
            })() : null;
            const bars = chart.getDatasetMeta(0).data.map((element, index) => {
              const geometry = element.getProps(['x', 'y', 'base', 'width', 'height'], true);
              return {
                index,
                label: chart.data.labels[index],
                value: chart.data.datasets[0].data[index],
                visible: chart.isDatasetVisible(0) && element.hidden !== true,
                color: element.options.backgroundColor,
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
                chartArea: { ...chart.chartArea },
              },
              canvas: {
                rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
                widthAttribute: canvas.width,
                heightAttribute: canvas.height,
              },
              chartActive: active(chart.getActiveElements()),
              tooltip: {
                opacity: tooltip.opacity,
                title: [...(tooltip.title ?? [])],
                body: (tooltip.body ?? []).map((item) => ({
                  before: [...item.before],
                  lines: [...item.lines],
                  after: [...item.after],
                })),
                active: active(tooltip.getActiveElements()),
                caret: { x: tooltip.caretX, y: tooltip.caretY },
                bounds: tooltipBounds,
                backgroundSample,
                resolvedStyle: {
                  enabled: tooltipOptions.enabled,
                  position: tooltipOptions.position,
                  mode: tooltipOptions.mode,
                  intersect: tooltipOptions.intersect,
                  backgroundColor: tooltipOptions.backgroundColor,
                  borderColor: tooltipOptions.borderColor,
                  borderWidth: tooltipOptions.borderWidth,
                  caretPadding: tooltipOptions.caretPadding,
                  caretSize: tooltipOptions.caretSize,
                  cornerRadius: tooltipOptions.cornerRadius,
                  padding: tooltipOptions.padding,
                  displayColors: tooltipOptions.displayColors,
                  titleColor: tooltipOptions.titleColor,
                  titleFont: {
                    family: tooltipTitleFont.family,
                    size: tooltipTitleFont.size,
                    style: tooltipTitleFont.style,
                    weight: tooltipTitleFont.weight,
                    lineHeight: tooltipTitleFont.lineHeight,
                  },
                  bodyColor: tooltipOptions.bodyColor,
                  bodyFont: {
                    family: tooltipBodyFont.family,
                    size: tooltipBodyFont.size,
                    style: tooltipBodyFont.style,
                    weight: tooltipBodyFont.weight,
                    lineHeight: tooltipBodyFont.lineHeight,
                  },
                  footerColor: tooltipOptions.footerColor,
                  footerFont: {
                    family: tooltipFooterFont.family,
                    size: tooltipFooterFont.size,
                    style: tooltipFooterFont.style,
                    weight: tooltipFooterFont.weight,
                    lineHeight: tooltipFooterFont.lineHeight,
                  },
                },
                methods: {
                  getActiveElements: typeof tooltip.getActiveElements,
                  setActiveElements: typeof tooltip.setActiveElements,
                  getTitle: typeof tooltip.getTitle,
                  getBody: typeof tooltip.getBody,
                  handleEvent: typeof tooltip.handleEvent,
                  draw: typeof tooltip.draw,
                },
              },
              legend: {
                position: legend?.options.position ?? null,
                left: legend?.left ?? null,
                top: legend?.top ?? null,
                right: legend?.right ?? null,
                bottom: legend?.bottom ?? null,
                hitBoxes: legendHitBoxes,
              },
              datasetVisible: chart.isDatasetVisible(0),
              bars,
              chartClicks: [...chartClicks],
              nativeCanvasEvents: [...nativeCanvasEvents],
            };
          },
        };
        return {
          chartVersion: Chart.version,
          devicePixelRatio: window.devicePixelRatio,
          requestedEvents: [...chart.options.events],
        };
      }, { devicePixelRatio });

      const waitForLayout = async () => {
        await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
        await page.waitForTimeout(250);
      };
      const snapshot = async () => page.evaluate(() => window.__chartInteractions.snapshot());
      const clearEvents = async () => page.evaluate(() => window.__chartInteractions.clearEvents());
      await waitForLayout();
      const initial = await snapshot();
      if (initial.legend.hitBoxes.length !== 1) {
        throw new Error(`Expected one default legend hit box, got ${JSON.stringify(initial.legend.hitBoxes)}`);
      }

      const recordGesture = async ({ name, kind, target, x, y, localX = null, localY = null, expectedOpacity, expectedVisible }) => {
        await clearEvents();
        if (kind === 'touchscreen.tap') {
          await page.touchscreen.tap(x, y);
        } else if (kind === 'mouse.click') {
          await page.mouse.click(x, y);
        } else {
          throw new Error(`Unknown browser gesture: ${kind}`);
        }
        await waitForLayout();
        const state = await snapshot();
        if (expectedOpacity !== undefined && Math.abs(state.tooltip.opacity - expectedOpacity) > 0.001) {
          throw new Error(`${name}: expected tooltip opacity ${expectedOpacity}, got ${state.tooltip.opacity}`);
        }
        if (expectedVisible !== undefined && state.datasetVisible !== expectedVisible) {
          throw new Error(`${name}: expected dataset visibility ${expectedVisible}, got ${state.datasetVisible}`);
        }
        return {
          gesture: {
            kind,
            target,
            pageCssPixels: { x, y },
            ...(localX === null ? {} : { chartCssPixels: { x: localX, y: localY } }),
          },
          state,
        };
      };

      const firstBar = initial.bars[0];
      const secondBar = initial.bars[1];
      const canvasRect = initial.canvas.rect;
      const firstBarPoint = {
        x: canvasRect.x + firstBar.x,
        y: canvasRect.y + (firstBar.y + firstBar.base) / 2,
      };
      const secondBarPoint = {
        x: canvasRect.x + secondBar.x,
        y: canvasRect.y + (secondBar.y + secondBar.base) / 2,
      };
      const outsideCanvasPoint = { x: viewport.width - 5, y: canvasRect.y + chartHeight / 2 };
      const blankChartPoint = {
        x: canvasRect.x + initial.chart.chartArea.right - 3,
        y: canvasRect.y + initial.chart.chartArea.top + 3,
      };
      const legendHitBox = initial.legend.hitBoxes[0];
      const steps = {};
      steps.touchFirstBar = await recordGesture({
        name: 'touchFirstBar', kind: 'touchscreen.tap', target: 'bar A',
        x: firstBarPoint.x, y: firstBarPoint.y,
        localX: firstBar.x, localY: (firstBar.y + firstBar.base) / 2,
        expectedOpacity: 1,
      });
      steps.touchSecondBar = await recordGesture({
        name: 'touchSecondBar', kind: 'touchscreen.tap', target: 'bar B',
        x: secondBarPoint.x, y: secondBarPoint.y,
        localX: secondBar.x, localY: (secondBar.y + secondBar.base) / 2,
        expectedOpacity: 1,
      });
      steps.touchOutsideCanvas = await recordGesture({
        name: 'touchOutsideCanvas', kind: 'touchscreen.tap', target: 'outside canvas',
        x: outsideCanvasPoint.x, y: outsideCanvasPoint.y,
        expectedOpacity: 0,
      });
      steps.touchBlankChart = await recordGesture({
        name: 'touchBlankChart', kind: 'touchscreen.tap', target: 'blank plot area',
        x: blankChartPoint.x, y: blankChartPoint.y,
        localX: initial.chart.chartArea.right - 3,
        localY: initial.chart.chartArea.top + 3,
        expectedOpacity: 0,
      });
      steps.legendHide = await recordGesture({
        name: 'legendHide', kind: 'touchscreen.tap', target: 'default Data legend item',
        x: legendHitBox.centerPageX, y: legendHitBox.centerPageY,
        localX: legendHitBox.left + legendHitBox.width / 2,
        localY: legendHitBox.top + legendHitBox.height / 2,
        expectedOpacity: 0,
        expectedVisible: false,
      });
      steps.legendShow = await recordGesture({
        name: 'legendShow', kind: 'touchscreen.tap', target: 'default Data legend item',
        x: legendHitBox.centerPageX, y: legendHitBox.centerPageY,
        localX: legendHitBox.left + legendHitBox.width / 2,
        localY: legendHitBox.top + legendHitBox.height / 2,
        expectedOpacity: 0,
        expectedVisible: true,
      });

      const requestsObserved = blockedRequests.length;
      await context.close();
      if (requestsObserved !== 0) {
        throw new Error(`The browser attempted ${requestsObserved} network request(s): ${blockedRequests.join(', ')}`);
      }
      if (initial.chart.width !== containerWidth || initial.chart.height !== chartHeight ||
          initialization.chartVersion !== provenance.version || initialization.devicePixelRatio !== devicePixelRatio) {
        throw new Error(`Unexpected layout or Chart.js configuration for ${viewport.name} DPR ${devicePixelRatio}`);
      }
      for (const name of ['touchFirstBar', 'touchSecondBar']) {
        const state = steps[name].state;
        if (state.tooltip.title.length !== 1 || state.tooltip.body.length !== 1 || state.chartClicks.length === 0) {
          throw new Error(`${name}: missing tooltip content or actual Chart.js click callback: ${JSON.stringify(state)}`);
        }
      }
      if (steps.touchFirstBar.state.tooltip.title[0] !== 'A' || steps.touchSecondBar.state.tooltip.title[0] !== 'B') {
        throw new Error(`Bar taps resolved to unexpected labels: ${steps.touchFirstBar.state.tooltip.title} / ${steps.touchSecondBar.state.tooltip.title}`);
      }
      const caseId = `${viewport.name}_${viewport.width}x${viewport.height}_dpr${devicePixelRatio}`;
      cases.push({
        caseId,
        viewport,
        dpr: devicePixelRatio,
        requestedLayout: {
          canvasCssWidth: `${containerWidth}px`,
          canvasCssHeight: `${chartHeight}px`,
          canvasWidthAttribute: containerWidth * devicePixelRatio,
          canvasHeightAttribute: chartHeight * devicePixelRatio,
        },
        browserConfiguration: {
          hasTouch: true,
          chartEvents: initialization.requestedEvents,
        },
        initial,
        steps,
        networkRequests: requestsObserved,
      });
    }
  }

  const fixture = {
    schemaVersion: 1,
    oracle: 'Dedicated Playwright-pinned Chromium 153 headless shell. All browser requests are blocked; setContent and the verified pinned inline Chart.js UMD source are used.',
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
      backgroundColor: '#3b82f6',
      options: {
        responsive: true,
        animation: false,
        maintainAspectRatio: false,
        devicePixelRatio: 'per case',
      },
      tooltipConfiguration: 'No tooltip or legend options are supplied; resolved defaults are captured from the live Chart.js instance.',
    },
    captureNotes: {
      scope: 'Browser interaction oracle only. This fixture reports no native Android success or result.',
      gestures: 'Bar, blank/outside, and legend gestures use Playwright touchscreen.tap. Coordinates are CSS pixels computed from live Chart.js geometry and legend hit boxes.',
      eventRecording: 'Chart.js options.onClick records its real callback arguments. Canvas event listeners observe trusted browser events without preventing or changing them.',
      tooltip: 'The default Chart.js tooltip plugin is enabled with its stock options and callbacks; no mock plugin or programmatic active-element mutation is used.',
      comparison: 'Compare semantic states and event kind/indices. Native platform font metrics and raw touch event sequences can differ.',
    },
    cases,
  };
  await writeFile(outputPath, `${JSON.stringify(fixture)}\n`);
  console.log(JSON.stringify({ outputPath, browserVersion, playwrightVersion: playwrightPackage.version, chartSha256, cases: cases.length }));
} finally {
  if (browser) await browser.close();
}
