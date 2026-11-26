import assert from 'node:assert/strict';
import {writeFile} from 'node:fs/promises';
import {chromium} from 'playwright-core';
import {requireTestBrowserExecutable} from './test_browser.mjs';

const cases=[
  {name:'rootless-relative-centered',rootless:true,dialogStyle:'position:relative'},
  {name:'html-without-body-relative-centered',omitBody:true,dialogStyle:'position:relative'},
  {name:'relative-centered',dialogStyle:'position:relative'},
  {name:'auto-insets',dialogStyle:'inset:auto'},
  {name:'auto-insets-no-margins',dialogStyle:'inset:auto;margin:0'},
  {name:'auto-insets-in-positioned-parent',parentStyle:'position:relative;top:100px;left:60px',dialogStyle:'inset:auto'},
  {name:'static-important-centered',dialogStyle:'position:static!important'},
  {name:'sticky-centered',dialogStyle:'position:sticky'},
  {name:'relative-offset',dialogStyle:'position:relative;top:40px;left:20px;margin:0'},
  {name:'absolute-offset-in-positioned-parent',
    parentStyle:'position:relative;top:100px;left:100px',
    dialogStyle:'position:absolute;top:40px;left:20px;margin:0'},
  {name:'fixed-offset-in-transformed-parent',
    parentStyle:'position:relative;transform:translateX(100px)',
    dialogStyle:'position:fixed;top:40px;left:20px;margin:0'},
];
const browser=await chromium.launch({
  executablePath:requireTestBrowserExecutable(),headless:true,
});
try {
  assert.equal(browser.version(),'153.0.8010.12');
  const rows=[];
  for(const viewport of [{width:390,height:796},{width:768,height:976}]) {
    const context=await browser.newContext({viewport});
    try {
      for(const scenario of cases) {
        const page=await context.newPage();
        await page.route('**/*',route=>route.abort());
        const body=`<meta name="viewport" content="width=device-width,initial-scale=1">
          <div style="${scenario.parentStyle||''}">
          <dialog style="${scenario.dialogStyle}"><button>Inside</button></dialog></div>
          <script>document.querySelector('dialog').showModal()</script>`;
        const content=body.replace(/^<meta[^>]*>/,'');
        const html=scenario.rootless?`<!doctype html>${body}`:
          scenario.omitBody?
            `<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>${content}</html>`:
            `<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head><body>${content}</body></html>`;
        await page.setContent(html);
        const result=await page.evaluate(()=>{
          const dialog=document.querySelector('dialog');
          const style=getComputedStyle(dialog),rect=dialog.getBoundingClientRect();
          return {position:style.position,
            rect:{x:rect.x,y:rect.y,width:rect.width,height:rect.height},
            inset:{top:style.top,left:style.left,right:style.right,bottom:style.bottom}};
        });
        rows.push({...scenario,viewport,result});
        await page.close();
      }
    } finally {await context.close();}
  }
  const output=new URL('../../../../packages/pirc_render/test/fixtures/parity/document-dialog-author-position-chromium153.json',import.meta.url);
  await writeFile(output,JSON.stringify({
    oracle:'Dedicated Playwright-pinned Chromium Headless Shell; no external requests or daily Chrome profile.',
    browserVersion:browser.version(),cases:rows,
  },null,2)+'\n');
  console.log(`${rows.length} modal author-position cases captured`);
} finally {await browser.close();}
