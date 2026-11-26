import {createHash} from 'node:crypto';
import {readFile, writeFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {requireTestBrowserExecutable} from './test_browser.mjs';

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
const {chromium} = gatewayRequire('playwright-core');
const playwrightPackage = JSON.parse(await readFile(gatewayRequire.resolve('playwright-core/package.json'), 'utf8'));
const browserExecutable = requireTestBrowserExecutable();
const outputPath = path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-chart-responsive-layout-chromium153.json');
const viewportCases = [
  {name: 'phone', width: 390, height: 844},
  {name: 'tablet', width: 768, height: 1024},
];
const layoutModes = [
  {name: 'explicit_css_dimensions', description: 'Canvas CSS width and height are explicit pixel sizes.'},
  {name: 'percent_width_fixed_height', description: 'Canvas CSS width is 100% and height is 240 CSS pixels.'},
  {name: 'container_only', description: 'Canvas has no style attribute or CSS dimensions before Chart.js initialization.'},
  {name: 'percent_width_reset_styles', description: 'Canvas has 100% width and 240px height, with an author CSS reset for display:block and border-box sizing.'},
];
const cases = [];

// Kept independent of the browser-only API wrappers so native can load this exact driver.
function responsiveChartDriver() {
  const canvas = document.getElementById('chart');
  const container = document.getElementById('chart-container');
  const resizeButton = document.getElementById('resize');
  const probeElement = document.getElementById('probe');
  const initialContainerWidth = Number.parseFloat(container.getAttribute('data-base-width'));
  const chartResult = {succeeded: false, error: null};
  const reports = {initial: null, resized: null};
  let chart = null;
  let resolveResize = null;
  let resizeStarted = false;

  const waitTwoFrames = () => new Promise((resolve) => {
    requestAnimationFrame(() => requestAnimationFrame(resolve));
  });
  const errorText = (error) => `${error?.name ?? 'Error'}: ${error?.message ?? String(error)}`;
  const measure = () => {
    const canvasRect = canvas.getBoundingClientRect();
    const containerRect = container.getBoundingClientRect();
    const canvasComputed = getComputedStyle(canvas);
    const containerComputed = getComputedStyle(container);
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
      windowDevicePixelRatio: window.devicePixelRatio,
      container: {
        inlineStyle: {width: container.style.width, height: container.style.height},
        computedStyle: {
          width: containerComputed.width,
          height: containerComputed.height,
          display: containerComputed.display,
          position: containerComputed.position,
        },
        rect: {x: containerRect.x, y: containerRect.y, width: containerRect.width, height: containerRect.height},
        offset: {width: container.offsetWidth, height: container.offsetHeight},
        client: {width: container.clientWidth, height: container.clientHeight},
      },
      canvas: {
        attributes: {width: canvas.getAttribute('width'), height: canvas.getAttribute('height')},
        inlineStyle: {
          display: canvas.style.display,
          boxSizing: canvas.style.boxSizing,
          position: canvas.style.position,
          width: canvas.style.width,
          height: canvas.style.height,
        },
        backing: {width: canvas.width, height: canvas.height},
        computedStyle: {
          width: canvasComputed.width,
          height: canvasComputed.height,
          display: canvasComputed.display,
          boxSizing: canvasComputed.boxSizing,
          position: canvasComputed.position,
        },
        rect: {x: canvasRect.x, y: canvasRect.y, width: canvasRect.width, height: canvasRect.height},
        offset: {width: canvas.offsetWidth, height: canvas.offsetHeight},
        client: {width: canvas.clientWidth, height: canvas.clientHeight},
      },
      chart: {
        width: chart.width,
        height: chart.height,
        currentDevicePixelRatio: chart.currentDevicePixelRatio,
        chartArea: {...chart.chartArea},
      },
      bars,
    };
  };
  const publish = (phase, state, error, timing = null) => {
    const report = {
      phase,
      constructor: {...chartResult},
      state,
      error: error ?? null,
      ...(timing ? {timing} : {}),
    };
    reports[phase] = report;
    probeElement.textContent = JSON.stringify(report);
    return report;
  };

  try {
    chart = new Chart(canvas, {
      type: 'bar',
      data: {
        labels: ['A', 'B'],
        datasets: [{label: 'Data', data: [3, 7], backgroundColor: '#3b82f6'}],
      },
      options: {responsive: true, animation: false, maintainAspectRatio: false},
    });
    chartResult.succeeded = true;
  } catch (error) {
    chartResult.error = errorText(error);
  }

  const initialReady = waitTwoFrames().then(() => {
    if (!chartResult.succeeded) return publish('initial', null, null);
    try {
      return publish('initial', measure(), null);
    } catch (error) {
      return publish('initial', null, errorText(error));
    }
  });
  window.__chartResponsiveReports = reports;
  window.__chartResponsiveReady = initialReady;

  const startResize = () => {
    if (resizeStarted) return;
    resizeStarted = true;
    container.style.width = `${initialContainerWidth + 20}px`;
    waitTwoFrames().then(async () => {
      let afterTwoFrames = null;
      let afterTwoFramesError = null;
      if (chartResult.succeeded) {
        try {
          afterTwoFrames = measure();
        } catch (error) {
          afterTwoFramesError = errorText(error);
        }
      }
      await new Promise((resolve) => setTimeout(resolve, 0));
      await waitTwoFrames();
      let settledState = null;
      let settledError = null;
      if (chartResult.succeeded) {
        try {
          settledState = measure();
        } catch (error) {
          settledError = errorText(error);
        }
      }
      const report = publish('resized', settledState, settledError, {
        afterTwoAnimationFrames: {state: afterTwoFrames, error: afterTwoFramesError},
        settledAfterResizeTaskAndTwoFrames: {state: settledState, error: settledError},
      });
      resolveResize?.(report);
      resolveResize = null;
    });
  };
  resizeButton.addEventListener('click', startResize);
  window.chartResizeContainerBy20 = () => {
    if (reports.resized) return Promise.resolve(reports.resized);
    return new Promise((resolve) => {
      resolveResize = resolve;
      resizeButton.click();
    });
  };
}

const driverSource = `(${responsiveChartDriver.toString()})();`;

function makeHtml({baseWidth, chartHeight, modeName, includeScripts}) {
  const canvasStyle = modeName === 'explicit_css_dimensions'
    ? ` style="width:${baseWidth}px;height:${chartHeight}px"`
    : modeName === 'percent_width_fixed_height' || modeName === 'percent_width_reset_styles'
      ? ` style="width:100%;height:${chartHeight}px"`
      : '';
  const scripts = includeScripts
    ? '<script src="/chart.js"></script><script src="/chart-responsive-driver.js"></script>'
    : '';
  const resetStyle = modeName === 'percent_width_reset_styles' ? 'canvas{display:block;box-sizing:border-box}' : '';
  return `<!doctype html>
<html><head><meta charset="utf-8"><style>html,body{margin:0;padding:0}#chart-container{width:${baseWidth}px;height:${chartHeight}px;margin-left:20px}#probe{white-space:pre-wrap}${resetStyle}</style></head>
<body><div id="chart-container" data-base-width="${baseWidth}"><canvas id="chart"${canvasStyle}></canvas></div><button id="resize" type="button">Resize +20px</button><pre id="probe"></pre>${scripts}</body></html>`;
}

let browser;
try {
  browser = await chromium.launch({executablePath: browserExecutable, headless: true});
  const browserVersion = browser.version();
  if (!browserVersion.startsWith('153.')) {
    throw new Error(`Expected dedicated Chromium 153, got ${browserVersion}`);
  }

  for (const viewport of viewportCases) {
    for (const dpr of [1, 3]) {
      const baseWidth = viewport.width - 40;
      const chartHeight = 240;
      for (const mode of layoutModes) {
        const context = await browser.newContext({viewport, deviceScaleFactor: dpr});
        const page = await context.newPage();
        const blockedRequests = [];
        await page.route('**/*', async (route) => {
          blockedRequests.push(route.request().url());
          await route.abort('blockedbyclient');
        });
        await page.setContent(makeHtml({baseWidth, chartHeight, modeName: mode.name, includeScripts: false}), {waitUntil: 'load'});

        await page.evaluate(() => {
          const canvas = document.getElementById('chart');
          const container = document.getElementById('chart-container');
          const trace = [];
          const installResults = [];
          const traceState = {enabled: false, phase: 'setup'};
          const record = (entry) => {
            if (traceState.enabled) trace.push({seq: trace.length, phase: traceState.phase, ...entry});
          };
          const descriptorInPrototypeChain = (object, property) => {
            let prototype = Object.getPrototypeOf(object);
            while (prototype) {
              const descriptor = Object.getOwnPropertyDescriptor(prototype, property);
              if (descriptor) return descriptor;
              prototype = Object.getPrototypeOf(prototype);
            }
            return null;
          };
          const installAccessor = (target, property, label) => {
            const descriptor = descriptorInPrototypeChain(target, property);
            if (!descriptor?.get || !descriptor?.set) {
              installResults.push({label, property, installed: false, reason: 'native-accessor-unavailable'});
              return;
            }
            try {
              Object.defineProperty(target, property, {
                configurable: true,
                enumerable: descriptor.enumerable,
                get() {
                  const value = descriptor.get.call(this);
                  record({op: `${label}.${property}.read`, value});
                  return value;
                },
                set(value) {
                  const previousValue = descriptor.get.call(this);
                  descriptor.set.call(this, value);
                  const resultingValue = descriptor.get.call(this);
                  record({op: `${label}.${property}.write`, previousValue, requestedValue: value, resultingValue});
                },
              });
              installResults.push({label, property, installed: true});
            } catch (error) {
              installResults.push({label, property, installed: false, reason: `${error.name}: ${error.message}`});
            }
          };
          const installStyleProxy = (element, label) => {
            const descriptor = descriptorInPrototypeChain(element, 'style');
            if (!descriptor?.get) {
              installResults.push({label, property: 'style', installed: false, reason: 'native-getter-unavailable'});
              return;
            }
            try {
              const nativeStyle = descriptor.get.call(element);
              const trackedProperties = new Set(['width', 'height', 'display', 'boxSizing', 'position']);
              const styleProxy = new Proxy(nativeStyle, {
                get(target, property) {
                  if (property === 'setProperty') {
                    return (name, value, priority) => {
                      const key = String(name).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
                      const previousValue = Reflect.apply(target.getPropertyValue, target, [name]);
                      const result = Reflect.apply(target.setProperty, target, [name, value, priority]);
                      const resultingValue = Reflect.apply(target.getPropertyValue, target, [name]);
                      if (trackedProperties.has(key)) record({op: `${label}.style.${key}.write`, previousValue, requestedValue: value, resultingValue, via: 'setProperty'});
                      return result;
                    };
                  }
                  if (property === 'removeProperty') {
                    return (name) => {
                      const key = String(name).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
                      const previousValue = Reflect.apply(target.getPropertyValue, target, [name]);
                      const result = Reflect.apply(target.removeProperty, target, [name]);
                      const resultingValue = Reflect.apply(target.getPropertyValue, target, [name]);
                      if (trackedProperties.has(key)) record({op: `${label}.style.${key}.write`, previousValue, requestedValue: '', resultingValue, via: 'removeProperty'});
                      return result;
                    };
                  }
                  const value = Reflect.get(target, property, target);
                  if (typeof property === 'string' && trackedProperties.has(property)) record({op: `${label}.style.${property}.read`, value});
                  return typeof value === 'function' ? value.bind(target) : value;
                },
                set(target, property, value) {
                  if (typeof property !== 'string' || !trackedProperties.has(property)) {
                    return Reflect.set(target, property, value, target);
                  }
                  const previousValue = Reflect.get(target, property, target);
                  const succeeded = Reflect.set(target, property, value, target);
                  const resultingValue = Reflect.get(target, property, target);
                  record({op: `${label}.style.${property}.write`, previousValue, requestedValue: value, resultingValue});
                  return succeeded;
                },
              });
              Object.defineProperty(element, 'style', {
                configurable: true,
                enumerable: descriptor.enumerable,
                get() { return styleProxy; },
              });
              installResults.push({label, property: 'style', installed: true, trackedProperties: [...trackedProperties]});
            } catch (error) {
              installResults.push({label, property: 'style', installed: false, reason: `${error.name}: ${error.message}`});
            }
          };
          const installElementRead = (element, label, property) => {
            const descriptor = descriptorInPrototypeChain(element, property);
            if (!descriptor?.get) {
              installResults.push({label, property, installed: false, reason: 'native-getter-unavailable'});
              return;
            }
            try {
              Object.defineProperty(element, property, {
                configurable: true,
                enumerable: descriptor.enumerable,
                get() {
                  const value = descriptor.get.call(this);
                  record({op: `${label}.${property}.read`, value});
                  return value;
                },
              });
              installResults.push({label, property, installed: true});
            } catch (error) {
              installResults.push({label, property, installed: false, reason: `${error.name}: ${error.message}`});
            }
          };

          for (const property of ['width', 'height']) installAccessor(canvas, property, 'canvas');
          installStyleProxy(canvas, 'canvas');
          installStyleProxy(container, 'container');
          for (const element of [canvas, container]) {
            const label = element === canvas ? 'canvas' : 'container';
            for (const property of ['offsetWidth', 'offsetHeight', 'clientWidth', 'clientHeight']) {
              installElementRead(element, label, property);
            }
          }
          for (const [element, label] of [[canvas, 'canvas'], [container, 'container']]) {
            const nativeRect = element.getBoundingClientRect;
            try {
              Object.defineProperty(element, 'getBoundingClientRect', {
                configurable: true,
                value(...args) {
                  const rect = Reflect.apply(nativeRect, this, args);
                  record({op: `${label}.getBoundingClientRect.read`, value: {x: rect.x, y: rect.y, width: rect.width, height: rect.height}});
                  return rect;
                },
              });
              installResults.push({label, property: 'getBoundingClientRect', installed: true});
            } catch (error) {
              installResults.push({label, property: 'getBoundingClientRect', installed: false, reason: `${error.name}: ${error.message}`});
            }
          }

          const nativeGetComputedStyle = window.getComputedStyle;
          try {
            window.getComputedStyle = function(element, pseudoElement) {
              const computed = Reflect.apply(nativeGetComputedStyle, this, [element, pseudoElement]);
              if (element === canvas || element === container) {
                record({
                  op: `${element === canvas ? 'canvas' : 'container'}.getComputedStyle.read`,
                  value: {width: computed.width, height: computed.height, display: computed.display, boxSizing: computed.boxSizing, position: computed.position},
                });
              }
              return computed;
            };
            installResults.push({label: 'window', property: 'getComputedStyle', installed: true});
          } catch (error) {
            installResults.push({label: 'window', property: 'getComputedStyle', installed: false, reason: `${error.name}: ${error.message}`});
          }

          const pageErrors = [];
          window.addEventListener('error', (event) => pageErrors.push(`${event.error?.name ?? 'Error'}: ${event.message}`));
          window.addEventListener('unhandledrejection', (event) => {
            const reason = event.reason;
            pageErrors.push(reason instanceof Error ? `${reason.name}: ${reason.message}` : String(reason));
          });
          const initialCanvasStyle = window.getComputedStyle(canvas);
          const initialCanvasRect = canvas.getBoundingClientRect();
          const initialCanvasBeforeChart = {
            attributes: {width: canvas.getAttribute('width'), height: canvas.getAttribute('height')},
            backing: {width: canvas.width, height: canvas.height},
            inlineStyle: {display: canvas.style.display, width: canvas.style.width, height: canvas.style.height},
            computedStyle: {
              width: initialCanvasStyle.width,
              height: initialCanvasStyle.height,
              display: initialCanvasStyle.display,
              boxSizing: initialCanvasStyle.boxSizing,
              position: initialCanvasStyle.position,
            },
            rect: {x: initialCanvasRect.x, y: initialCanvasRect.y, width: initialCanvasRect.width, height: initialCanvasRect.height},
          };
          window.__chartApiTrace = {trace, installResults, pageErrors, traceState, initialCanvasBeforeChart};
        });

        await page.evaluate(() => {
          const {traceState} = window.__chartApiTrace;
          traceState.phase = 'initialization';
          traceState.enabled = true;
        });
        await page.addScriptTag({content: chartSource});
        await page.addScriptTag({content: driverSource});
        await page.evaluate(() => window.__chartResponsiveReady);
        const initialPageState = await page.evaluate(() => ({
          report: JSON.parse(document.getElementById('probe').textContent || 'null'),
          trace: window.__chartApiTrace.trace.map((entry) => ({...entry})),
        }));
        await page.evaluate(() => {
          const {trace, traceState} = window.__chartApiTrace;
          trace.length = 0;
          traceState.phase = 'container_width_plus_20px';
          traceState.enabled = true;
        });
        await page.locator('#resize').click();
        await page.waitForFunction(() => window.__chartResponsiveReports.resized !== null);
        const resizedPageState = await page.evaluate(() => ({
          report: JSON.parse(document.getElementById('probe').textContent || 'null'),
          trace: window.__chartApiTrace.trace.map((entry) => ({...entry})),
        }));
        const probeMetadata = await page.evaluate(() => ({
          initialCanvasBeforeChart: window.__chartApiTrace.initialCanvasBeforeChart,
          instrumented: window.__chartApiTrace.installResults,
          pageErrors: [...window.__chartApiTrace.pageErrors],
        }));

        const chartVersion = await page.evaluate(() => globalThis.Chart?.version ?? null);
        const requestsObserved = blockedRequests.length;
        await context.close();
        if (requestsObserved !== 0) {
          throw new Error(`The browser attempted ${requestsObserved} network request(s): ${blockedRequests.join(', ')}`);
        }

        cases.push({
          caseId: `${mode.name}_${viewport.name}_${viewport.width}x${viewport.height}_dpr${dpr}`,
          mode: mode.name,
          viewport,
          dpr,
          requestedLayout: {
            containerCssWidth: `${baseWidth}px`,
            containerCssHeight: `${chartHeight}px`,
            resizedContainerCssWidth: `${baseWidth + 20}px`,
            canvasInitialCss: mode.name === 'explicit_css_dimensions'
              ? {width: `${baseWidth}px`, height: `${chartHeight}px`}
              : mode.name === 'percent_width_fixed_height' || mode.name === 'percent_width_reset_styles'
                ? {width: '100%', height: `${chartHeight}px`}
                : {width: 'omitted', height: 'omitted'},
            authorCssReset: mode.name === 'percent_width_reset_styles' ? 'canvas{display:block;box-sizing:border-box}' : null,
            canvasWidthAttribute: 'omitted',
            canvasHeightAttribute: 'omitted',
          },
          authoredHtml: makeHtml({baseWidth, chartHeight, modeName: mode.name, includeScripts: true}),
          initialCanvasBeforeChart: probeMetadata.initialCanvasBeforeChart,
          instrumented: probeMetadata.instrumented,
          constructor: initialPageState.report?.constructor ?? {succeeded: false, error: 'driver did not publish initial report'},
          initialProbe: initialPageState.report,
          resizeProbe: resizedPageState.report,
          initializationTrace: initialPageState.trace,
          resizeTrace: resizedPageState.trace,
          pageErrors: probeMetadata.pageErrors,
          chartVersion,
          networkRequests: requestsObserved,
        });
      }
    }
  }

  const fixture = {
    schemaVersion: 1,
    oracle: 'Dedicated Playwright test-browser Chromium 153 headless shell; all requests are blocked; the pinned Chart.js 4.5.1 UMD is loaded inline in capture runs.',
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
      data: [3, 7],
      backgroundColor: '#3b82f6',
      options: {responsive: true, animation: false, maintainAspectRatio: false},
    },
    driverSource,
    captureNotes: {
      html: 'Each case includes complete authored HTML with omitted canvas width/height attributes, its requested CSS sizing, and script tags for /chart.js and /chart-responsive-driver.js. The driver source is stored separately for a local route.',
      driver: 'The shared driver constructs the stock Chart.js bar chart and publishes an initial JSON report into #probe after two animation frames. The Resize +20px button changes only the container width; the report includes an after-two-frame state plus a settled state after Chart.js resize debounce and two more frames.',
      apiTrace: 'Browser-only property and API wrappers forward directly to native descriptors and methods. The traces record the actual initialization and button-resize sequences, including canvas bitmap/style writes and computed-style, bounding-rect, offset-size, and client-size reads. Wrapper code is not in the shared driver or Chart.js.',
      probe: 'The stock driver reports constructor failures separately from initial or resized measurement errors. Browser probes are captured from #probe; resizeProbe.state is settled and resizeProbe.timing.afterTwoAnimationFrames.state records the first two-frame snapshot. Probe API reads may appear in trace order.',
      nativeComparison: 'This fixture records browser behavior only and makes no claim about Android native rendering or parity.',
    },
    cases,
  };
  if (cases.length !== 16 || cases.some((item) => item.networkRequests !== 0)) {
    throw new Error(`Expected 16 network-isolated cases; got ${cases.length}`);
  }
  const outputPath = path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-chart-responsive-layout-chromium153.json');
  await writeFile(outputPath, `${JSON.stringify(fixture)}\n`);
  console.log(JSON.stringify({outputPath, browserVersion, playwrightVersion: playwrightPackage.version, chartSha256, cases: cases.length}));
} finally {
  if (browser) await browser.close();
}
