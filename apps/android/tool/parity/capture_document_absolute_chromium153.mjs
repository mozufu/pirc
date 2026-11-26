import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';
const { chromium } = createRequire(import.meta.url)('playwright-core');
const modes = [
  [
    'left_top',
    'position:relative;width:260px;height:160px;padding:12px;border:4px solid #111',
    'left:17px;top:23px;width:50px;height:30px',
    '',
  ],
  [
    'right_bottom',
    'position:relative;width:260px;height:160px;padding:12px;border:4px solid #111',
    'right:11px;bottom:19px;width:50px;height:30px',
    '',
  ],
  [
    'percent',
    'position:relative;width:260px;height:160px;padding:12px;border:4px solid #111',
    'left:10%;top:20%;width:25%;height:30%',
    'nested',
  ],
  [
    'stretch',
    'position:relative;width:260px;height:160px;padding:12px;border:4px solid #111',
    'inset:10px 20px 30px 40px',
    '',
  ],
  [
    'margins',
    'position:relative;width:260px;height:160px;padding:12px;border:4px solid #111',
    'left:10px;top:15px;width:50px;height:30px;margin:5% 10px',
    '',
  ],
  [
    'auto_margins',
    'position:relative;width:260px;height:160px;padding:12px;border:4px solid #111',
    'inset:10px;width:50px;height:30px;margin:auto',
    '',
  ],
  [
    'nested_host',
    'position:relative;width:260px;height:160px;padding:12px;border:4px solid #111',
    'left:-10px;top:15px;width:50px;height:30px',
    'positioned',
  ],
  [
    'flex',
    'position:relative;display:flex;gap:11px;width:260px;height:160px;padding:12px;border:4px solid #111',
    'right:11px;top:19px;width:50px;height:30px',
    '',
  ],
  [
    'grid',
    'position:relative;display:grid;grid-template-columns:60px 60px;gap:11px;width:260px;height:160px;padding:12px;border:4px solid #111',
    'right:11px;top:19px;width:50px;height:30px',
    '',
  ],
  [
    'viewport',
    'width:260px;height:160px;margin:40px;padding:12px;border:4px solid #111',
    'right:11px;bottom:19px;width:50px;height:30px',
    '',
  ],
  [
    'auto_size',
    'position:relative;width:260px;height:160px;padding:12px;border:4px solid #111',
    'left:17px;top:23px',
    'child',
  ],
  [
    'clamped_stretch',
    'position:relative;width:260px;height:160px;padding:12px;border:4px solid #111',
    'inset:10px;max-width:100px;max-height:60px',
    '',
  ],
];
for (const kind of ['span', 'img', 'canvas'])
  modes.push([
    'absolute_' + kind,
    'position:relative;width:260px;height:160px;padding:12px;border:4px solid #111',
    'left:10px;top:10px;width:50%;height:25%',
    kind,
  ]);
modes.push([
  'rtl',
  'position:relative;direction:rtl;width:260px;height:160px;padding:12px;border:4px solid #111',
  'inset:10px;width:50px;height:30px',
  '',
]);
for (const kind of ['overlap_z', 'overlap_source'])
  modes.push([
    kind,
    'position:relative;width:260px;height:160px;padding:12px;border:4px solid #111',
    'left:10px;top:10px;width:80px;height:50px;z-index:1',
    kind,
  ]);
for (const box of ['content-box', 'border-box'])
  modes.push([
    'own_' + box,
    'position:relative;width:260px;height:160px;padding:12px;border:4px solid #111',
    'left:17px;top:23px;width:50%;height:25%;padding:5%;border:3px solid #3b82f6;box-sizing:' + box,
    '',
  ]);
modes.push([
  'inline_mixed',
  'position:relative;width:260px;height:160px;padding:12px;border:4px solid #111',
  'left:10px;top:10px;width:50px;height:30px',
  'mixed',
]);
const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
});
try {
  if (browser.version() !== '153.0.8010.12') throw Error('Unexpected Chromium');
  const cases = [];
  for (const [name, parent, absolute, nesting] of modes)
    for (const width of [390, 768])
      for (const dpr of [1, 3])
        for (const theme of ['light', 'dark']) {
          const tag = ['span', 'img', 'canvas'].includes(nesting) ? nesting : 'div';
          const source =
            tag === 'img'
              ? 'src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII="'
              : '';
          const abs = `<${tag} ${source} id="abs" data-pirc-script-click style="position:absolute;background:#3b82f6;${absolute}">${nesting === 'child' ? '<div id="inside" style="width:40px;height:35px"></div>' : ''}</${tag}>${nesting.startsWith('overlap') ? `<div id="abs2" data-pirc-script-click style="position:absolute;left:10px;top:10px;width:80px;height:50px;background:#f97316;z-index:${nesting === 'overlap_z' ? 2 : 1}"></div>` : ''}`;
          let markup = `<!doctype html><html><head><style>html,body{margin:0;padding:0}#one,#two{width:40px;height:20px;background:#22c55e}#after{width:70px;height:13px}</style></head><body><div id="host" style="${parent}"><div id="one" data-pirc-script-click></div>${nesting === 'nested' ? `<div id="static" style="margin:7px;padding:9px">${abs}</div>` : nesting === 'positioned' ? `<div id="inner" style="position:relative;width:140px;height:90px;margin:7px;padding:9px;border:2px solid">${abs}</div>` : abs}<div id="two" data-pirc-script-click></div></div><div id="after"></div></body></html>`;
          if (nesting === 'mixed') {
            const pixel =
              'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=';
            markup = `<!doctype html><html><head><style>html,body{margin:0;padding:0}#one{width:240px;background:#22c55e;line-height:0;font-size:0}#two{width:40px;height:20px;background:#22c55e}#after{width:70px;height:13px}img{width:20px;height:10px;vertical-align:top}</style></head><body><div id="host" style="${parent}"><div id="one" data-pirc-script-click><img src="${pixel}">${abs}<img id="inside" src="${pixel}"></div><div id="two" data-pirc-script-click></div></div><div id="after"></div></body></html>`;
          }
          const context = await browser.newContext({
            viewport: { width, height: width === 390 ? 844 : 1024 },
            deviceScaleFactor: dpr,
            colorScheme: theme,
          });
          try {
            const page = await context.newPage();
            await page.route('**/*', (r) => r.abort());
            await page.setContent(markup);
            if (
              !(await page
                .locator('img')
                .evaluateAll((images) =>
                  images.every((image) => image.complete && image.naturalWidth === 1),
                ))
            )
              throw new Error('Fixture image did not decode');
            const observed = await page.evaluate(() =>
              Object.fromEntries(
                ['host', 'abs', 'one', 'two', 'after', 'inner', 'inside', 'abs2'].flatMap((id) => {
                  const e = document.getElementById(id);
                  if (!e) return [];
                  const r = e.getBoundingClientRect();
                  return [[id, { x: r.x, y: r.y, width: r.width, height: r.height }]];
                }),
              ),
            );
            const probes = ['abs', 'one', 'two'].map((id) => ({
              name: id,
              x: observed[id].x + observed[id].width / 2,
              y: observed[id].y + observed[id].height / 2,
            }));
            probes.push({
              name: 'abs-left',
              x: observed.abs.x + 2,
              y: observed.abs.y + observed.abs.height / 2,
            });
            const png = (await page.screenshot({ omitBackground: true })).toString('base64');
            const pixels = await page.evaluate(
              async ({ png, probes, dpr }) => {
                const bitmap = await createImageBitmap(
                  new Blob([Uint8Array.from(atob(png), (c) => c.charCodeAt(0))], {
                    type: 'image/png',
                  }),
                );
                const canvas = document.createElement('canvas');
                canvas.width = bitmap.width;
                canvas.height = bitmap.height;
                const ctx = canvas.getContext('2d');
                ctx.drawImage(bitmap, 0, 0);
                bitmap.close();
                return probes.map((p) => ({
                  ...p,
                  rgba: [
                    ...ctx.getImageData(Math.floor(p.x * dpr), Math.floor(p.y * dpr), 1, 1).data,
                  ],
                  hit:
                    document.elementFromPoint(p.x, p.y)?.closest('[data-pirc-script-click]')?.id ??
                    null,
                }));
              },
              { png, probes, dpr },
            );
            cases.push({ name, width, dpr, theme, html: markup, observed, pixels });
          } finally {
            await context.close();
          }
        }
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-absolute-chromium153.json', import.meta.url),
    JSON.stringify({ browserVersion: browser.version(), cases }) + '\n',
  );
  console.log(JSON.stringify({ cases: cases.length, browserVersion: browser.version() }));
} finally {
  await browser.close();
}
