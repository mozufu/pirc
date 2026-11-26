import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';

const { chromium } = createRequire(import.meta.url)('playwright-core');
const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
});
try {
  if (browser.version() !== '153.0.8010.12') throw Error('Expected pinned Chromium');
  const page = await browser.newPage();
  await page.route('**/*', route => route.abort());
  await page.setContent('<div id="host"></div>');
  const html = await page.evaluate(() => {
    const host = document.querySelector('#host');
    const range = document.createRange();
    range.selectNodeContents(host);
    window.fragmentRuns = 0;
    const fragment = range.createContextualFragment(
      '<script>window.fragmentRuns += 1<\/script>' +
      '<button id="fragment-button" onclick="window.fragmentRuns += 10">Go</button>',
    );
    const beforeConnect = window.fragmentRuns;
    host.appendChild(fragment);
    const afterConnect = window.fragmentRuns;
    document.querySelector('#fragment-button').click();
    const afterClick = window.fragmentRuns;
    const script = host.querySelector('script');
    script.remove();
    host.appendChild(script);
    return {
      beforeConnect,
      afterConnect,
      afterClick,
      afterMove: window.fragmentRuns,
      rangeContextTag: range.commonAncestorContainer.localName,
      fragmentEmptied: fragment.childNodes.length === 0,
    };
  });
  await page.setContent('<table><tbody id="host"></tbody></table>');
  const table = await page.evaluate(() => {
    const host = document.querySelector('#host');
    const range = document.createRange();
    range.selectNodeContents(host);
    const child = range.createContextualFragment('<tr><td>Cell</td></tr>').firstChild;
    return { tag: child.localName, namespace: child.namespaceURI, text: child.textContent };
  });
  await page.setContent('<svg id="host" xmlns="http://www.w3.org/2000/svg"></svg>');
  const svg = await page.evaluate(() => {
    const host = document.querySelector('#host');
    const range = document.createRange();
    range.selectNodeContents(host);
    const child = range.createContextualFragment('<circle cx="10" cy="10" r="5"/>').firstChild;
    return { tag: child.localName, namespace: child.namespaceURI };
  });
  await page.setContent(
    '<svg id="host" xmlns="http://www.w3.org/2000/svg">' +
    '<foreignObject id="foreign"></foreignObject></svg>',
  );
  const svgNested = await page.evaluate(() => {
    const host = document.querySelector('#host');
    const range = document.createRange();
    range.selectNodeContents(host);
    const fragment = range.createContextualFragment(
      '<g id="group"><circle id="circle" cx="10"/></g>',
    );
    const group = fragment.firstChild;
    const circle = group.firstChild;
    const beforeOwner = [group.ownerSVGElement?.id || null, circle.ownerSVGElement?.id || null];
    host.appendChild(fragment);
    const afterOwner = [group.ownerSVGElement?.id || null, circle.ownerSVGElement?.id || null];
    const foreign = document.querySelector('#foreign');
    const foreignRange = document.createRange();
    foreignRange.selectNodeContents(foreign);
    const htmlChild = foreignRange.createContextualFragment('<div>Text</div>').firstChild;
    return {
      beforeOwner, afterOwner,
      namespaces: [group.namespaceURI, circle.namespaceURI, htmlChild.namespaceURI],
      foreignTag: htmlChild.localName,
    };
  });
  await page.setContent('<svg id="a"></svg><svg id="b"></svg>');
  const svgClone = await page.evaluate(() => {
    const first = document.getElementById('a');
    const second = document.getElementById('b');
    const range = document.createRange();
    range.selectNodeContents(first);
    first.appendChild(range.createContextualFragment('<g><circle/></g>'));
    const clone = first.firstChild.cloneNode(true);
    const before = clone.firstChild.ownerSVGElement?.id || null;
    second.appendChild(clone);
    return {
      before,
      after: clone.firstChild.ownerSVGElement?.id || null,
      namespace: clone.firstChild.namespaceURI,
    };
  });
  const svgPaint = [];
  for (const width of [390, 768]) {
    await page.setViewportSize({ width, height: 796 });
    await page.setContent(`<!doctype html><style>html,body{margin:0}</style>
      <svg id="vector" width="40" height="40" viewBox="0 0 40 40"></svg>
      <script>
        (function(){
          const vector=document.getElementById('vector');
          const range=document.createRange();range.selectNodeContents(vector);
          vector.appendChild(range.createContextualFragment(
            '<circle cx="20" cy="20" r="12" fill="#ff0000"/>'));
        })();
      <\/script>`);

    await page.evaluate(() => new Promise(resolve =>
      requestAnimationFrame(() => requestAnimationFrame(resolve))));
    const rect = await page.locator('#vector').boundingBox();
    const screenshot = await page.screenshot();
    const centerPixel = await page.evaluate(async base64 => {
      const image = new Image();
      image.src = 'data:image/png;base64,' + base64;
      await image.decode();
      const canvas = document.createElement('canvas');
      canvas.width = image.width;
      canvas.height = image.height;
      const context = canvas.getContext('2d');
      context.drawImage(image, 0, 0);
      return Array.from(context.getImageData(20, 20, 1, 1).data);
    }, screenshot.toString('base64'));
    svgPaint.push({ width, rect: [rect.x, rect.y, rect.width, rect.height], centerPixel });
  }
  const fixture = { schemaVersion: 1, browserVersion: browser.version(), html, table, svg, svgNested, svgClone, svgPaint };
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-contextual-fragment-chromium153.json', import.meta.url),
    JSON.stringify(fixture) + '\n',
  );
  console.log(JSON.stringify(fixture));
} finally {
  await browser.close();
}
