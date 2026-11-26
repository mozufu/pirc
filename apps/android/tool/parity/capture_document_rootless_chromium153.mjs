import assert from 'node:assert/strict';
import {writeFile} from 'node:fs/promises';
import {chromium} from 'playwright-core';
import {requireTestBrowserExecutable} from './test_browser.mjs';

const sources=[
  {name:'doctype-meta-content',html:'<!doctype html><meta name="viewport" content="width=device-width"><div id="x">X</div><script>window.marker=document.documentElement.localName</script>'},
  {name:'simple-paragraph',html:'<p id="x">X</p>'},
  {name:'explicit-head-body',html:'<head><title>T</title></head><body><p id="x">X</p></body>'},
  {name:'metadata-before-explicit-head',html:'<meta name="a"><title>T</title><head><style>p{color:red}</style></head><body><p id="x">X</p></body>'},
  {name:'body-only',html:'<body class="hello"><p id="x">X</p></body>'},
  {name:'script-before-content',html:'<script>window.marker=document.currentScript.parentElement.localName</script><meta charset="utf-8"><div id="x">X</div>'},
  {name:'multiple-root-elements',html:'<section id="x">A</section><section id="y">B</section>'},
  {name:'html-without-head-body',html:'<html><p id="x">X</p></html>'},
  {name:'html-without-body',html:'<html><head><title>T</title></head><p id="x">X</p></html>'},
  {name:'html-without-head',html:'<html><body><p id="x">X</p></body></html>'},
];
const browser=await chromium.launch({
  executablePath:requireTestBrowserExecutable(),headless:true,
});
try {
  assert.equal(browser.version(),'153.0.8010.12');
  const context=await browser.newContext({viewport:{width:390,height:796}});
  const cases=[];
  try {
    for(const source of sources) {
      const page=await context.newPage();
      await page.route('**/*',route=>route.abort());
      await page.setContent(source.html);
      const result=await page.evaluate(()=>({
        root:document.documentElement?.localName||null,
        head:document.head?.localName||null,
        body:document.body?.localName||null,
        headElements:[...document.head.children].map(e=>e.localName),
        bodyElements:[...document.body.children].map(e=>e.localName),
        xInBody:document.body.contains(document.getElementById('x')),
        doctype:document.doctype?.name||null,
        marker:window.marker||null,
      }));
      cases.push({...source,result});
      await page.close();
    }
  } finally {await context.close();}
  const output=new URL('../../../../packages/pirc_render/test/fixtures/parity/document-rootless-chromium153.json',import.meta.url);
  await writeFile(output,JSON.stringify({
    oracle:'Dedicated Playwright-pinned Chromium Headless Shell; no external requests or daily Chrome profile.',
    browserVersion:browser.version(),cases,
  },null,2)+'\n');
  console.log(`${cases.length} rootless document cases captured`);
} finally {await browser.close();}
