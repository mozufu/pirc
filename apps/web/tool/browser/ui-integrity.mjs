// node apps/web/tool/browser/ui-integrity.mjs [--report-only] [--json out.json]
//
// Real-browser check that untrusted rendered content cannot affect the app's own UI
// outside its message or preview box. The app's real Message / Markdown components
// render each payload in a stand-in shell that holds an approve button, a composer
// and a header. For every payload the page is inspected for:
//   - hit-testing at the centre of each outside control (is it still on top?)
//   - a real mouse click on the approve control (does it still arrive?)
//   - pixels of the header and dock compared with a baseline render
//   - computed style of the outside controls compared with the baseline
// Cases U1-U3 use the `style` attribute; U4-U5 use Mermaid.
// --without-containment drops the containment declarations again (the earlier stylesheet).
// Without --report-only any escape (or a diagram that no longer renders) exits non-zero.
import assert from 'node:assert/strict';
import { writeFile } from 'node:fs/promises';
import { launchTestBrowser, openFixture, startFixtureServer, startReceiver } from './harness.mjs';

const args = process.argv.slice(2);
const reportOnly = args.includes('--report-only');
// Emulates the stylesheet before the content box was contained, to show what the checks catch.
const withoutContainment = args.includes('--without-containment');
const jsonOut = args.includes('--json') ? args[args.indexOf('--json') + 1] : undefined;

const html = (style, text = 'x') => `<div style="${style}">${text}</div>`;
const mermaid = (source) => '```mermaid\n' + source + '\n```';

const cases = (recv) => [
  {
    id: 'U1',
    title: 'style attribute: position:fixed overlay over the whole app',
    markdown: html(
      'position:fixed;inset:0;z-index:2147483647;background:rgba(255,0,0,.85);color:#fff',
      'FAKE FULL-SCREEN LAYER',
    ),
  },
  {
    id: 'U1b',
    title: 'style attribute: fixed fake dock over the real controls',
    markdown: html(
      'position:fixed;left:0;right:0;bottom:0;height:96px;z-index:99999;background:#d00;color:#fff',
      '<button type="button">Approve (fake)</button>',
    ),
  },
  {
    id: 'U1c',
    title: 'style attribute: position:absolute with offsets (no positioned ancestor)',
    markdown: html(
      'position:absolute;top:0;left:0;width:100vw;height:100vh;z-index:99999;background:rgba(0,0,255,.7)',
      'ABSOLUTE LAYER',
    ),
  },
  {
    id: 'U2',
    title: 'style attribute: negative margin, transform and huge size reach outside the box',
    markdown: html(
      'margin-top:-300px;margin-bottom:-300px;height:5000px;width:5000px;transform:translate(0,700px) scale(2);transform-origin:0 0;background:rgba(255,160,0,.8)',
      'BIG TRANSFORMED BOX',
    ),
  },
  {
    id: 'U2b',
    title: 'style attribute: relative offset pushes content onto the dock',
    markdown: html(
      'position:relative;top:620px;left:0;height:140px;background:#d00;color:#fff;z-index:9999',
      'RELATIVELY OFFSET',
    ),
  },
  {
    id: 'U2c',
    title: 'style attribute: translated element lands on the neighbouring message',
    markdown: html(
      'position:relative;z-index:99;height:60px;transform:translateY(90px);background:rgba(255,0,0,.9);color:#fff',
      'COVERS THE NEXT MESSAGE',
    ),
  },
  {
    id: 'U3',
    title: 'style attribute: opacity:0 fixed element over the real approve button',
    markdown: html(
      'position:fixed;bottom:0;left:0;width:100vw;height:96px;opacity:0;z-index:2147483647',
      '<a href="#hijack" style="display:block;width:100%;height:100%">click</a>',
    ),
  },
  {
    id: 'U3b',
    title: 'style attribute: transparent element via color/background alpha over the button',
    markdown: html(
      'position:fixed;inset:auto 0 0 0;height:96px;background:transparent;color:transparent;z-index:2147483647',
      '<button type="button" style="width:100%;height:100%;opacity:0">decoy</button>',
    ),
  },
  {
    id: 'U4a',
    title: 'Mermaid: init themeCSS with ordinary selectors for outside elements',
    mermaid: true,
    markdown: mermaid(
      `%%{init: {'themeCSS': '#approve{display:none!important} body{background:red!important} :root{--ink:red} #app-title{color:red}'}}%%\nflowchart LR\n A-->B`,
    ),
  },
  {
    id: 'U4b',
    title: 'Mermaid: init themeCSS closing the scoped rule with } and starting global rules',
    mermaid: true,
    markdown: mermaid(
      `%%{init: {'themeCSS': '} #approve{display:none!important} #app-title{color:red!important} body{background:#f0f!important} .x{'}}%%\nflowchart LR\n A-->B`,
    ),
  },
  {
    id: 'U4c',
    title: 'Mermaid: themeCSS with @import and a url() background',
    mermaid: true,
    markdown: mermaid(
      `%%{init: {'themeCSS': '@import url(${recv}/themecss-import.css); body{background:url(${recv}/themecss-bg.png)}'}}%%\nflowchart LR\n A-->B`,
    ),
  },
  {
    id: 'U4d',
    title: 'Mermaid: themeVariables value used inside generated CSS',
    mermaid: true,
    markdown: mermaid(
      `%%{init: {'themeVariables': {'fontFamily': 'x;}#approve{display:none!important}body{background:red!important}.y{', 'primaryColor': 'red;}#app-title{color:red!important}.z{'}}}%%\nflowchart LR\n A-->B`,
    ),
  },
  {
    id: 'U4e',
    title: 'Mermaid: classDef / style directives with } sequences (the parser rejects them)',
    mermaid: true,
    mayBeRejected: true,
    markdown: mermaid(
      `flowchart LR\n A-->B\n classDef evil fill:red}#approve{display:none!important}body{background:red!important}.q{x:y\n class A evil\n style B fill:red}#app-title{color:red!important}.r{x:y`,
    ),
  },
  {
    id: 'U4k',
    title: 'Mermaid: node label HTML with a style attribute holding a remote url()',
    mermaid: true,
    markdown: mermaid(
      `flowchart LR\n A["<span style='background:url(${recv}/label-style.png);display:inline-block;width:20px;height:20px'>x</span>"]-->B`,
    ),
  },
  {
    id: 'U4j',
    title: 'Mermaid: themeCSS selecting the diagram labels with url() and @font-face',
    mermaid: true,
    markdown: mermaid(
      `%%{init: {'themeCSS': '.nodeLabel{background-image:url(${recv}/themecss-label.png);font-family:x} @font-face{font-family:x;src:url(${recv}/themecss-font.woff2)}'}}%%\nflowchart LR\n A-->B`,
    ),
  },
  {
    id: 'U4f',
    title: 'Mermaid: directive tries to lower securityLevel and add a remote image label',
    mermaid: true,
    markdown: mermaid(
      `%%{init: {'securityLevel':'loose','flowchart':{'htmlLabels':true}}}%%\nflowchart LR\n A["<img src='${recv}/label-image.png'>"]-->B`,
    ),
  },
  {
    id: 'U5a',
    title: 'Mermaid: themeCSS declarations make the diagram root position:fixed over the app',
    mermaid: true,
    markdown: mermaid(
      `%%{init: {'themeCSS': 'position:fixed;inset:0;width:100vw;height:100vh;max-width:none;z-index:2147483647;background:rgba(255,0,0,.8)'}}%%\nflowchart LR\n A-->B`,
    ),
  },
  {
    id: 'U5b',
    title: 'Mermaid: node label HTML with a fixed full-screen element',
    mermaid: true,
    markdown: mermaid(
      `flowchart LR\n A["<div style='position:fixed;inset:0;z-index:99999;background:red'>COVER</div>"]-->B`,
    ),
  },
  {
    id: 'U5c',
    title: 'Mermaid: classDef gives the node label position:fixed',
    mermaid: true,
    markdown: mermaid(
      `flowchart LR\n A-->B\n classDef cover position:fixed,top:0,left:0,width:100vw,height:100vh,z-index:99999,background:red\n class A,B cover`,
    ),
  },
  {
    id: 'U5d',
    title: 'Mermaid: huge padding and node sizes inflate the diagram',
    mermaid: true,
    markdown: mermaid(
      `%%{init: {'flowchart': {'padding': 5000, 'nodeSpacing': 5000, 'rankSpacing': 5000}}}%%\nflowchart LR\n A-->B-->C`,
    ),
  },
];

const targets = [
  {
    id: 'message',
    render: (page, md) => page.evaluate((m) => window.pirc.renderMessage(m), md),
    box: '[data-message-id="a1"]',
  },
  {
    id: 'system',
    render: (page, md) => page.evaluate((m) => window.pirc.renderSystem(m), md),
    box: '[data-message-id="s1"]',
  },
  {
    id: 'document',
    render: (page, md) => page.evaluate((m) => window.pirc.renderDocument(m), md),
    box: '#doc',
  },
];

const probes = [
  { name: 'approve', selector: '#approve' },
  { name: 'composer', selector: '#composer' },
  { name: 'app-title', selector: '#app-title' },
  // The next message of the timeline (absent from the document preview).
  { name: 'neighbour', selector: '[data-message-id="a2"] .markdown', optional: true },
];

async function settle(page, withDiagram) {
  if (withDiagram) {
    await page.waitForFunction(
      () => {
        const blocks = [...document.querySelectorAll('.mermaid-block')];
        return (
          blocks.length > 0 && blocks.every((b) => ['ok', 'error'].includes(b.dataset.rendered))
        );
      },
      undefined,
      { timeout: 20000 },
    );
  }
  await page.waitForTimeout(150);
}

async function clip(page, selector) {
  const rect = await page.evaluate((s) => {
    const r = document.querySelector(s).getBoundingClientRect();
    return { x: r.x, y: r.y, width: r.width, height: r.height };
  }, selector);
  return page.screenshot({ clip: rect, caret: 'hide', animations: 'disabled' });
}

/** Observations after a render. */
async function observe(page, boxSelector) {
  const inPage = await page.evaluate(
    ({ boxSelector, probes }) => {
      const box = document.querySelector(boxSelector).getBoundingClientRect();
      const hit = {};
      const style = {};
      for (const { name, selector, optional } of probes) {
        const el = document.querySelector(selector);
        if (!el) {
          if (optional) continue;
          throw new Error('missing probe ' + selector);
        }
        const r = el.getBoundingClientRect();
        // Pushed out of view by the content's own layout: nothing to hit-test.
        if (optional && (r.bottom < 0 || r.top > innerHeight || r.height === 0)) continue;
        const points = [
          [r.x + r.width / 2, r.y + r.height / 2],
          [r.x + 4, r.y + 4],
          [r.right - 4, r.bottom - 4],
        ];
        hit[name] = points.every(([x, y]) => {
          const top = document.elementFromPoint(x, y);
          return top === el || el.contains(top);
        });
        const cs = getComputedStyle(el);
        style[name] = [
          'display',
          'visibility',
          'opacity',
          'color',
          'backgroundColor',
          'position',
          'fontSize',
          'transform',
        ]
          .map((k) => `${k}=${cs[k]}`)
          .join(';');
      }
      const body = getComputedStyle(document.body);
      style.body = `background=${body.backgroundColor};color=${body.color}`;
      style.root = `ink=${getComputedStyle(document.documentElement).getPropertyValue('--ink')}`;
      // Informational: do descendants extend beyond the box?
      const scope = document.querySelector(boxSelector);
      let extends_ = false;
      for (const el of scope.querySelectorAll('*')) {
        const r = el.getBoundingClientRect();
        if (r.width === 0 && r.height === 0) continue;
        if (
          r.left < box.left - 1 ||
          r.top < box.top - 1 ||
          r.right > box.right + 1 ||
          r.bottom > box.bottom + 1
        ) {
          extends_ = true;
          break;
        }
      }
      const diagrams = [...scope.querySelectorAll('.mermaid-block')].map((b) => {
        if (b.dataset.rendered !== 'ok') return b.dataset.rendered;
        // Shown as an image once mermaid is done: it has to have decoded to count as rendered.
        const img = b.querySelector('.mermaid-figure img');
        if (img) return img.complete && img.naturalWidth > 0 ? 'ok' : 'ok-but-image-not-loaded';
        return b.querySelector('.mermaid-figure svg') ? 'ok' : 'no-figure';
      });
      return {
        hit,
        style,
        extends: extends_,
        diagrams,
        viewportScroll: [scrollX, scrollY],
        bodyScroll: [document.body.scrollTop, document.documentElement.scrollTop],
      };
    },
    { boxSelector, probes },
  );
  inPage.header = await clip(page, '#app-title');
  inPage.dock = await clip(page, '#dock');
  return inPage;
}

async function clickApprove(page) {
  const before = await page.evaluate(() => window.pirc.approvals());
  const center = await page.evaluate(() => {
    const r = document.querySelector('#approve').getBoundingClientRect();
    return [r.x + r.width / 2, r.y + r.height / 2];
  });
  await page.mouse.click(center[0], center[1]);
  const after = await page.evaluate(() => window.pirc.approvals());
  // The page may have navigated to #hijack; undo it so later probes are unchanged.
  await page.evaluate(() => history.replaceState(null, '', location.pathname));
  return after - before;
}

const fixture = await startFixtureServer();
const receiver = await startReceiver();
const browser = await launchTestBrowser();
const results = [];

/** Render one payload on a fresh page (so no state leaks between cases) and observe it. */
async function run(target, markdown, withDiagram) {
  const page = await openFixture(browser.context, fixture.origin);
  try {
    if (withoutContainment)
      await page.addStyleTag({
        content:
          '.markdown{contain:none!important;isolation:auto!important;position:static!important}',
      });
    await target.render(page, markdown);
    await settle(page, withDiagram);
    const seen = await observe(page, target.box);
    seen.clicks = await clickApprove(page);
    return seen;
  } finally {
    await page.close();
  }
}

try {
  // Warm the dependency optimiser so a late "reloading" cannot interrupt a case.
  await run(targets[0], mermaid('flowchart LR\n A-->B'), true);
  for (const target of targets) {
    const base = await run(target, 'baseline text', false);
    const baseMermaid = await run(target, mermaid('flowchart LR\n A-->B'), true);
    for (const c of cases(receiver.origin)) {
      receiver.reset();
      const seen = await run(target, c.markdown, !!c.mermaid);
      const reference = c.mermaid ? baseMermaid : base;
      const reasons = [];
      for (const { name } of probes)
        if (name in seen.hit && !seen.hit[name]) reasons.push(`hit-test: ${name} is covered`);
      if (seen.clicks !== 1) reasons.push(`click on approve delivered ${seen.clicks} times`);
      if (!seen.header.equals(reference.header)) reasons.push('header pixels differ');
      if (!seen.dock.equals(reference.dock)) reasons.push('dock pixels differ');
      for (const k of Object.keys(seen.style))
        if (seen.style[k] !== reference.style[k]) reasons.push(`computed style of ${k} changed`);
      results.push({
        case: c.id,
        target: target.id,
        title: c.title,
        mayBeRejected: !!c.mayBeRejected,
        escapes: reasons.length > 0,
        reasons,
        descendantsExtendBeyondBox: seen.extends,
        diagramState: seen.diagrams,
        remoteRequests: receiver.hits.map((h) => h.url),
      });
    }
  }
} finally {
  await browser.close();
  await receiver.close();
  await fixture.close();
}

console.log(`browser: ${browser.executablePath} (${browser.version})`);
for (const r of results) {
  console.log(
    `${r.case.padEnd(4)} ${r.target.padEnd(8)} escape=${r.escapes ? 'YES' : 'no '} diagram=${r.diagramState.join(',') || '-'} remote=${r.remoteRequests.length}${r.remoteRequests.length ? ' ' + JSON.stringify(r.remoteRequests) : ''}  ${r.reasons.join('; ')}`,
  );
}
if (jsonOut)
  await writeFile(jsonOut, JSON.stringify({ browser: browser.version, results }, null, 2));
if (!reportOnly) {
  const escaped = results.filter((r) => r.escapes);
  assert.deepEqual(
    escaped.map((r) => `${r.case}/${r.target}`),
    [],
    'content escaped its box',
  );
  const broken = results.filter((r) =>
    r.diagramState.some((s) => s !== 'ok' && !(r.mayBeRejected && s === 'error')),
  );
  assert.deepEqual(
    broken.map((r) => `${r.case}/${r.target}`),
    [],
    'a diagram stopped rendering',
  );
  const requested = results.filter((r) => r.remoteRequests.length);
  assert.deepEqual(
    requested.map((r) => `${r.case}/${r.target}`),
    [],
    'content fetched a remote resource',
  );
}
