// node apps/web/tool/browser/remote-content.mjs
//
// Real-browser check of click-to-load: remote images and media in untrusted content
// make no request until the user activates the placeholder; then exactly that one
// address opens in a new tab (no opener, no referrer). A local server records every
// request it receives, so "nothing was fetched" is observed, not assumed.
import assert from 'node:assert/strict';
import { launchTestBrowser, openFixture, startFixtureServer, startReceiver } from './harness.mjs';

const fixture = await startFixtureServer();
const receiver = await startReceiver();
const browser = await launchTestBrowser();
const R = receiver.origin;
const DOT =
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

/** Every automatic-load route of design §1.2, each with its own path on the receiver. */
const payload = `
![markdown image](${R}/md-image.png)

<img src="${R}/img-src.png" alt="html image">
<img srcset="${R}/img-srcset-1x.png 1x, ${R}/img-srcset-2x.png 2x" alt="srcset only">
<picture><source srcset="${R}/picture-source.webp" type="image/webp"><img src="${R}/picture-img.png" alt="picture"></picture>
<video src="${R}/video-src.mp4" poster="${R}/video-poster.png" controls preload="auto"></video>
<video controls preload="auto"><source src="${R}/video-source.mp4"><track src="${R}/video-track.vtt" kind="subtitles"></video>
<audio src="${R}/audio-src.mp3" controls preload="auto"></audio>
<form><input type="image" src="${R}/input-image.png" alt="go"></form>
<svg width="20" height="20"><image href="${R}/svg-image.png" width="20" height="20"/><use href="${R}/svg-use.svg#a"/></svg>
<svg width="20" height="20"><filter id="f"><feImage href="${R}/svg-feimage.png"/></filter><rect width="10" height="10" fill="url(${R}/svg-fill.svg#p)"/></svg>
<div style="background:url(${R}/style-background.png);list-style:url(${R}/style-list.png);border-image:url(${R}/style-border.png) 30;-webkit-mask:url(${R}/style-mask.svg);cursor:url(${R}/style-cursor.cur),auto;content:url(${R}/style-content.png);color:rgb(1,2,3)">styled box</div>
<div style="background-image:image-set('${R}/style-image-set.png' 1x)">image-set</div>
<table background="${R}/table-background.png"><tr><td background="${R}/td-background.png">cell</td></tr></table>
<a href="${R}/anchor-not-clicked" ping="${R}/anchor-ping">a link that is never clicked</a>
<img lowsrc="${R}/lowsrc.png" dynsrc="${R}/dynsrc.avi" alt="old attributes">
<meta http-equiv="refresh" content="0;url=${R}/meta-refresh">
<link rel="preload" href="${R}/link-preload.png" as="image"><link rel="prefetch" href="${R}/link-prefetch"><link rel="icon" href="${R}/link-icon.png">
<img src="${DOT}" alt="inline image" id="inline-image">

\`\`\`mermaid
%%{init: {'themeCSS': '.nodeLabel{background-image:url(${R}/mermaid-themecss.png)}'}}%%
flowchart LR
  A["<img src='${R}/mermaid-label-img.png'>"] --> B["<span style='background:url(${R}/mermaid-label-style.png);display:inline-block;width:10px;height:10px'>x</span>"]
\`\`\`
`;

const targets = {
  message: (page) => page.evaluate((m) => window.pirc.renderMessage(m), payload),
  system: (page) => page.evaluate((m) => window.pirc.renderSystem(m), payload),
  document: (page) => page.evaluate((m) => window.pirc.renderDocument(m), payload),
};
const boxes = {
  message: '[data-message-id="a1"]',
  system: '[data-message-id="s1"]',
  document: '#doc',
};

const report = [];
try {
  // Warm the dependency optimiser.
  {
    const page = await openFixture(browser.context, fixture.origin);
    await targets.message(page);
    await page.waitForFunction(() => document.querySelector('.mermaid-block')?.dataset.rendered);
    await page.close();
  }
  // Control: the same sources inserted without the gate do reach the receiver, so a count
  // of zero below means something.
  {
    receiver.reset();
    const page = await openFixture(browser.context, fixture.origin);
    await page.evaluate(
      (html) => {
        document.querySelector('#doc').innerHTML = html;
      },
      payload
        .slice(0, payload.indexOf('```mermaid'))
        .replace(/!\[markdown image\]\(([^)]*)\)/, '<img src="$1">'),
    );
    await page.waitForTimeout(1500);
    const control = new Set(receiver.hits.map((h) => h.url));
    assert.ok(control.size >= 10, `control: only ${control.size} requests without the gate`);
    report.push({
      control: 'ungated insertion of the same markup',
      distinctRequests: control.size,
    });
    await page.close();
  }
  for (const [name, render] of Object.entries(targets)) {
    receiver.reset();
    const page = await openFixture(browser.context, fixture.origin);
    const opened = [];
    browser.context.on('page', (p) => opened.push(p));
    await render(page);
    await page.waitForFunction(
      () => [...document.querySelectorAll('.mermaid-block')].every((b) => b.dataset.rendered),
      undefined,
      { timeout: 20000 },
    );
    // Give any stray fetch (including lazy and preloading ones) time to show up.
    await page.waitForTimeout(1500);
    await page.mouse.wheel(0, 400);
    await page.waitForTimeout(500);
    const box = boxes[name];
    const state = await page.evaluate((box) => {
      const scope = document.querySelector(box);
      return {
        placeholders: scope.querySelectorAll('.remote-media').length,
        buttons: scope.querySelectorAll('.remote-media-open').length,
        fetchable: [
          ...scope.querySelectorAll(
            'img, video, audio, source, track, input[type=image], image, use, feImage',
          ),
        ]
          .filter(
            (e) =>
              (e.getAttribute('src') ?? e.getAttribute('href') ?? '').trim() &&
              !(e.getAttribute('src') ?? '').startsWith('data:'),
          )
          .map((e) => e.outerHTML.slice(0, 80)),
        inlineImageLoaded: (() => {
          const img = scope.querySelector('#inline-image');
          return !!img && img.complete && img.naturalWidth === 1;
        })(),
        styledBoxColor: [...scope.querySelectorAll('div')].find(
          (d) => d.textContent === 'styled box',
        )
          ? getComputedStyle(
              [...scope.querySelectorAll('div')].find((d) => d.textContent === 'styled box'),
            ).color
          : null,
        urls: [...scope.querySelectorAll('.remote-media-url')].map((e) => e.textContent),
      };
    }, box);
    const before = receiver.hits.map((h) => h.url);
    assert.deepEqual(before, [], `${name}: requests were made before any click`);
    assert.deepEqual(state.fetchable, [], `${name}: elements that fetch by themselves remain`);
    assert.ok(state.placeholders >= 8, `${name}: expected placeholders, got ${state.placeholders}`);
    assert.ok(state.inlineImageLoaded, `${name}: the data: image no longer displays`);
    assert.equal(state.styledBoxColor, 'rgb(1, 2, 3)', `${name}: ordinary inline style was lost`);

    // Activate one placeholder with a real click: exactly that address opens in a new tab.
    const wanted = `${R}/md-image.png`;
    const button = page.locator(`${box} button[data-remote-open="${wanted}"]`);
    const popup = browser.context.waitForEvent('page', { timeout: 10000 });
    await button.scrollIntoViewIfNeeded();
    await button.click();
    const tab = await popup;
    await tab.waitForLoadState('load').catch(() => {});
    const opener = await tab.evaluate(() => window.opener === null).catch(() => 'n/a');
    assert.equal(tab.url(), wanted, `${name}: the new tab opened a different address`);
    const after = receiver.hits.map((h) => h.url);
    assert.deepEqual(after, ['/md-image.png'], `${name}: requests after the click`);
    assert.equal(receiver.hits[0].referer, undefined, `${name}: a referrer was sent`);
    assert.equal(opener, true, `${name}: the new tab has an opener`);
    assert.equal(page.url().startsWith(fixture.origin), true, `${name}: the page itself navigated`);
    report.push({
      target: name,
      placeholders: state.placeholders,
      requestsBeforeClick: before.length,
      requestsAfterClick: after,
      newTabUrl: tab.url(),
      referer: receiver.hits[0].referer ?? null,
      openerIsNull: opener,
    });
    await tab.close();
    await page.close();
    browser.context.removeAllListeners('page');
  }
} finally {
  await browser.close();
  await receiver.close();
  await fixture.close();
}
console.log(`browser: ${browser.executablePath} (${browser.version})`);
for (const r of report) console.log(JSON.stringify(r));
console.log('remote-content: ok');
