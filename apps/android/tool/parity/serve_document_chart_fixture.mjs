import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const packageDirectory = path.join(scriptDirectory, 'vendor/chart.js-4.5.1');
const libraryPath = path.join(packageDirectory, 'chart.umd.js');
const provenance = JSON.parse(readFileSync(path.join(packageDirectory, 'provenance.json'), 'utf8'));
const library = readFileSync(libraryPath);
const actualSha256 = createHash('sha256').update(library).digest('hex');
if (actualSha256 !== provenance.assetSha256) {
  throw new Error(`Chart.js checksum mismatch: expected ${provenance.assetSha256}, got ${actualSha256}`);
}
const reference = readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-chart-chromium153.json'));
const referenceSha256 = createHash('sha256').update(reference).digest('hex');
const interactions = readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-chart-interactions-chromium153.json'));
const interactionFixture = JSON.parse(interactions.toString('utf8'));
if (interactionFixture.chartJs?.sha256 !== actualSha256 || !Array.isArray(interactionFixture.cases)) {
  throw new Error('Chart interaction fixture does not match the pinned library');
}
const fixture = JSON.parse(reference.toString('utf8'));
if (fixture.chartJs?.sha256 !== actualSha256 || !Array.isArray(fixture.cases)) {
  throw new Error('Chart.js reference fixture does not match the pinned library or has no cases');
}

const responsive = readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-chart-responsive-layout-chromium153.json'));
const responsiveFixture = JSON.parse(responsive.toString('utf8'));
if (responsiveFixture.chartJs?.sha256 !== actualSha256 || typeof responsiveFixture.driverSource !== 'string') {
  throw new Error('Chart responsive fixture does not match the pinned library');
}

function configuredPort() {
  const argument = process.argv.slice(2).find((value) => value === '--port' || value.startsWith('--port='));
  const argumentIndex = process.argv.indexOf(argument);
  const cliValue = argument === '--port'
    ? process.argv[argumentIndex + 1]
    : argument?.slice('--port='.length);
  const value = cliValue ?? process.env.PIRC_DOCUMENT_CHART_PORT ?? '19261';
  const port = Number(value);
  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    throw new Error(`Invalid port: ${value}`);
  }
  return port;
}

const targetState = readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-target-state-chromium153.json'));

const frameSteps = readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-frame-steps-chromium153.json'));

const layoutDependencies = readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-layout-dependencies-chromium153.json'));

const boxStyleProjection = readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-box-style-projection-chromium153.json'));

const canvasSizing = readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-canvas-sizing-chromium153.json'));

const chartTypes = readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-chart-types-chromium153.json'));
const chartTypesFixture = JSON.parse(chartTypes.toString('utf8'));
if (chartTypesFixture.chartJs?.sha256 !== actualSha256 || typeof chartTypesFixture.driverSource !== 'string') {
  throw new Error('Chart types fixture does not match the pinned library');
}

const chartAnimation = readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-chart-animation-chromium153.json'));
const chartAnimationFixture = JSON.parse(chartAnimation.toString('utf8'));
if (chartAnimationFixture.chartJs?.sha256 !== actualSha256 || typeof chartAnimationFixture.driverSource !== 'string') {
  throw new Error('Chart animation fixture does not match the pinned library');
}

const absoluteFixture = readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-absolute-chromium153.json'));
if (JSON.parse(absoluteFixture.toString('utf8')).browserVersion !== '153.0.8010.12') throw new Error('Unexpected absolute layout browser');

const pointerEvents = readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-pointer-events-chromium153.json'));
if (JSON.parse(pointerEvents.toString('utf8')).browserVersion !== '153.0.8010.12') throw new Error('Unexpected pointer-events browser');

const textStyle = readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-text-style-chromium153.json'));
if (JSON.parse(textStyle.toString('utf8')).browserVersion !== '153.0.8010.12') throw new Error('Unexpected text-style browser');

const fixed = readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-fixed-chromium153.json'));
if (JSON.parse(fixed.toString('utf8')).browserVersion !== '153.0.8010.12') throw new Error('Unexpected fixed browser');

const scrollAnchor = readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-scroll-anchor-chromium153.json'));
if (JSON.parse(scrollAnchor.toString('utf8')).browserVersion !== '153.0.8010.12') throw new Error('Unexpected scroll-anchor browser');

const elementAnchor = readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-element-anchor-chromium153.json'));
if (JSON.parse(elementAnchor.toString('utf8')).browserVersion !== '153.0.8010.12') throw new Error('Unexpected element-anchor browser');

const scrollRetention = readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-scroll-retention-chromium153.json'));
if (JSON.parse(scrollRetention.toString('utf8')).browserVersion !== '153.0.8010.12') throw new Error('Unexpected scroll-retention browser');

const scrollCommands = readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-scroll-commands-chromium153.json'));
if (JSON.parse(scrollCommands.toString('utf8')).browserVersion !== '153.0.8010.12') throw new Error('Unexpected scroll-command browser');

const scrollFeedback = readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-scroll-feedback-chromium153.json'));
if (JSON.parse(scrollFeedback.toString('utf8')).browserVersion !== '153.0.8010.12') throw new Error('Unexpected scroll-feedback browser');

const scrollingElement = readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-scrolling-element-chromium153.json'));
if (JSON.parse(scrollingElement.toString('utf8')).browserVersion !== '153.0.8010.12') throw new Error('Unexpected scrolling-element browser');

const scrollBehavior = readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-scroll-behavior-chromium153.json'));
if(JSON.parse(scrollBehavior.toString('utf8')).browserVersion !== '153.0.8010.12') throw new Error('Unexpected scroll-behavior browser');

const transformScroll = readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-transform-scroll-chromium153.json'));
if (JSON.parse(transformScroll.toString('utf8')).browserVersion !== '153.0.8010.12') throw new Error('Unexpected transform-scroll browser');

const transformOffset = readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-transform-offset-chromium153.json'));
if (JSON.parse(transformOffset.toString('utf8')).browserVersion !== '153.0.8010.12') throw new Error('Unexpected transform-offset browser');

const transformCB = readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-transform-cb-chromium153.json'));
if (JSON.parse(transformCB.toString('utf8')).browserVersion !== '153.0.8010.12') throw new Error('Unexpected transform-cb browser');

const transformStyle = readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-transform-style-chromium153.json'));
if (JSON.parse(transformStyle.toString('utf8')).browserVersion !== '153.0.8010.12') throw new Error('Unexpected transform-style browser');

const scrollRect = readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-scroll-rect-chromium153.json'));
if (JSON.parse(scrollRect.toString('utf8')).browserVersion !== '153.0.8010.12') throw new Error('Unexpected scroll-rect browser');

const requestedPort = configuredPort();
const server = createServer((request, response) => {
  const pathname = new URL(request.url ?? '/', 'http://127.0.0.1').pathname;
  if (request.method !== 'GET') {
    response.writeHead(405, {
      'cache-control': 'no-store',
      'content-type': 'text/plain; charset=utf-8',
    });
    response.end('Method not allowed');
    return;
  }
  if (pathname === '/chart.js') {
    response.writeHead(200, {
      'cache-control': 'no-store',
      'content-length': library.length,
      'content-type': 'text/javascript; charset=utf-8',
      'x-chartjs-version': provenance.version,
      'x-chartjs-sha256': actualSha256,
    });
    response.end(library);
    return;
  }
  if (pathname === '/interactions.json') {
    response.writeHead(200, {
      'cache-control': 'no-store',
      'content-type': 'application/json; charset=utf-8',
    });
    response.end(interactions);
    return;
  }
  if (pathname === '/initial-history.json') {
    response.writeHead(200, {'cache-control':'no-store','content-type':'application/json; charset=utf-8'});
    response.end(readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-initial-history-chromium153.json')));
    return;
  }
  if (pathname === '/late-fragment.json') {
    response.writeHead(200, {'cache-control':'no-store','content-type':'application/json; charset=utf-8'});
    response.end(readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-late-fragment-chromium153.json')));
    return;
  }
  if (pathname === '/target-state.json') {
    response.writeHead(200, {'cache-control':'no-store','content-type':'application/json; charset=utf-8'});
    response.end(targetState);
    return;
  }
  if(pathname === '/fragment-focus.json') {
    response.writeHead(200,{'cache-control':'no-store','content-type':'application/json; charset=utf-8'});
    response.end(readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-fragment-focus-chromium153.json')));return;
  }
  if(pathname === '/fragment-scroll.json') {
    response.writeHead(200,{'cache-control':'no-store','content-type':'application/json; charset=utf-8'});
    response.end(readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-fragment-scroll-chromium153.json')));return;
  }
  if(pathname === '/fragment.json') {
    response.writeHead(200,{'cache-control':'no-store','content-type':'application/json; charset=utf-8'});
    response.end(readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-fragment-chromium153.json')));return;
  }
  if(pathname === '/into-view.json') {
    response.writeHead(200,{'cache-control':'no-store','content-type':'application/json; charset=utf-8'});
    response.end(readFileSync(path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-into-view-chromium153.json')));return;
  }
  if(pathname === '/scroll-behavior.json') {
    response.writeHead(200,{'cache-control':'no-store','content-type':'application/json; charset=utf-8'});
    response.end(scrollBehavior);return;
  }
  if (pathname === '/transform-scroll.json') {
    response.writeHead(200, {'cache-control': 'no-store', 'content-type': 'application/json; charset=utf-8'});
    response.end(transformScroll);
    return;
  }
  if (pathname === '/transform-offset.json') {
    response.writeHead(200, {'cache-control': 'no-store', 'content-type': 'application/json; charset=utf-8'});
    response.end(transformOffset);
    return;
  }
  if (pathname === '/transform-cb.json') {
    response.writeHead(200, {'cache-control': 'no-store', 'content-type': 'application/json; charset=utf-8'});
    response.end(transformCB);
    return;
  }
  if (pathname === '/transform-style.json') {
    response.writeHead(200, {'cache-control': 'no-store', 'content-type': 'application/json; charset=utf-8'});
    response.end(transformStyle);
    return;
  }
  if (pathname === '/scroll-rect.json') {
    response.writeHead(200, {'cache-control': 'no-store', 'content-type': 'application/json; charset=utf-8'});
    response.end(scrollRect);
    return;
  }
  if (pathname === '/scrolling-element.json') {
    response.writeHead(200, {'cache-control': 'no-store', 'content-type': 'application/json; charset=utf-8'});
    response.end(scrollingElement);
    return;
  }
  if (pathname === '/scroll-feedback.json') {
    response.writeHead(200, {'cache-control': 'no-store', 'content-type': 'application/json; charset=utf-8'});
    response.end(scrollFeedback);
    return;
  }
  if (pathname === '/scroll-commands.json') {
    response.writeHead(200, {'cache-control': 'no-store', 'content-type': 'application/json; charset=utf-8'});
    response.end(scrollCommands);
    return;
  }
  if (pathname === '/scroll-retention.json') {
    response.writeHead(200, {'cache-control': 'no-store', 'content-type': 'application/json; charset=utf-8'});
    response.end(scrollRetention);
    return;
  }
  if (pathname === '/element-anchor.json') {
    response.writeHead(200, {'cache-control': 'no-store', 'content-type': 'application/json; charset=utf-8'});
    response.end(elementAnchor);
    return;
  }
  if (pathname === '/scroll-anchor.json') {
    response.writeHead(200, {'cache-control': 'no-store', 'content-type': 'application/json; charset=utf-8'});
    response.end(scrollAnchor);
    return;
  }
  if (pathname === '/fixed.json') {
    response.writeHead(200, {'cache-control': 'no-store', 'content-type': 'application/json; charset=utf-8'});
    response.end(fixed);
    return;
  }
  if (pathname === '/text-style.json') {
    response.writeHead(200, {'cache-control': 'no-store', 'content-type': 'application/json; charset=utf-8'});
    response.end(textStyle);
    return;
  }
  if (pathname === '/pointer-events.json') {
    response.writeHead(200, {'cache-control': 'no-store', 'content-type': 'application/json; charset=utf-8'});
    response.end(pointerEvents);
    return;
  }
  if (pathname === '/absolute.json') {
    response.writeHead(200, {'cache-control': 'no-store', 'content-type': 'application/json; charset=utf-8'});
    response.end(absoluteFixture);
    return;
  }
  if (pathname === '/chart-animation.json') {
    response.writeHead(200, {'cache-control': 'no-store', 'content-type': 'application/json; charset=utf-8'});
    response.end(chartAnimation);
    return;
  }
  if (pathname === '/chart-types.json') {
    response.writeHead(200, {'cache-control': 'no-store', 'content-type': 'application/json; charset=utf-8'});
    response.end(chartTypes);
    return;
  }
  if (pathname === '/canvas-sizing.json') {
    response.writeHead(200, {'cache-control':'no-store','content-type':'application/json; charset=utf-8'});
    response.end(canvasSizing); return;
  }
  if (pathname === '/box-style-projection.json') {
    response.writeHead(200, {'cache-control':'no-store','content-type':'application/json; charset=utf-8'});
    response.end(boxStyleProjection);
    return;
  }
  if (pathname === '/layout-dependencies.json') {
    response.writeHead(200, {'cache-control':'no-store','content-type':'application/json; charset=utf-8'});
    response.end(layoutDependencies);
    return;
  }
  if (pathname === '/frame-steps.json') {
    response.writeHead(200, {'cache-control':'no-store','content-type':'application/json; charset=utf-8'});
    response.end(frameSteps);
    return;
  }
  if (pathname === '/responsive-layout.json') {
    response.writeHead(200, {'cache-control':'no-store','content-type':'application/json; charset=utf-8'});
    response.end(responsive);
    return;
  }
  if (pathname === '/reference.json') {
    response.writeHead(200, {
      'cache-control': 'no-store',
      'content-length': reference.length,
      'content-type': 'application/json; charset=utf-8',
      'x-chartjs-version': provenance.version,
      'x-reference-sha256': referenceSha256,
    });
    response.end(reference);
    return;
  }

  response.writeHead(404, {
    'cache-control': 'no-store',
    'content-type': 'text/plain; charset=utf-8',
  });
  response.end('Not found');
});

server.on('error', (error) => {
  console.error(error);
  process.exitCode = 1;
});
server.listen(requestedPort, '127.0.0.1', () => {
  const address = server.address();
  console.log(JSON.stringify({
    ready: true,
    host: '127.0.0.1',
    port: address.port,
    paths: ['/chart.js', '/reference.json'],
    url: `http://127.0.0.1:${address.port}/chart.js`,
    referenceUrl: `http://127.0.0.1:${address.port}/reference.json`,
    package: provenance.package,
    version: provenance.version,
    sha256: actualSha256,
    referenceSha256,
    caseCount: fixture.cases.length,
  }));
});

function closeServer() {
  server.close(() => process.exit(0));
}
process.once('SIGINT', closeServer);
process.once('SIGTERM', closeServer);
