// Captures the fixed Chromium 153 dialog light-dismiss event oracle.
// test_browser.mjs refuses a daily-use Chrome executable or profile.
import {writeFileSync} from 'node:fs';
import {chromium} from 'playwright-core';
import {requireTestBrowserExecutable} from './test_browser.mjs';

const browser=await chromium.launch({
  executablePath:requireTestBrowserExecutable(), headless:true,
});
try {
  if(!browser.version().startsWith('153.'))
    throw new Error(`Expected pinned Chromium 153, got ${browser.version()}`);
  const cases=[];
  for(const [name,gesture,closedby,cancel,preventPointerDown] of [
    ['mouse-any','mouse','any',false,false],
    ['mouse-any-pointerdown-prevented','mouse','any',false,true],
    ['mouse-any-cancel-prevented','mouse','any',true,false],
    ['mouse-none','mouse','none',false,false],
    ['mouse-default','mouse',null,false,false],
    ['touch-any','touch','any',false,false],
    ['touch-any-cancel-prevented','touch','any',true,false],
    ['touch-none','touch','none',false,false],
  ]) {
    const context=await browser.newContext({
      viewport:{width:390,height:796}, hasTouch:gesture==='touch',
      isMobile:gesture==='touch',
    });
    const page=await context.newPage();
    await page.route('**/*',route=>route.abort());
    await page.setContent(`<!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">
      <dialog ${closedby==null?'':`closedby="${closedby}"`}>Dialog</dialog>
      <script>
      window.events=[];
      const dialog=document.querySelector('dialog');
      for(const type of ['pointerdown','cancel','beforetoggle','pointerup','click','close','toggle'])
        dialog.addEventListener(type,event=>{
          events.push({type,target:event.target.localName,trusted:event.isTrusted,
            oldState:event.oldState||null,newState:event.newState||null});
          if(type==='cancel' && ${cancel}) event.preventDefault();
          if(type==='pointerdown' && ${preventPointerDown}) event.preventDefault();
        });
      dialog.showModal();
      </script>`);
    await page.waitForTimeout(50);
    await page.evaluate(()=>window.events=[]);
    if(gesture==='touch') await page.touchscreen.tap(20,200);
    else await page.mouse.click(20,200);
    await page.waitForTimeout(50);
    cases.push({name,gesture,closedby,cancel,preventPointerDown,
      ...await page.evaluate(()=>({open:document.querySelector('dialog').open,events}))});
    await context.close();
  }
  const fixture={
    oracle:'Dedicated Playwright-pinned Chromium Headless Shell; no external requests or daily Chrome profile.',
    browserVersion:browser.version(),viewport:{width:390,height:796},cases,
  };
  const output=new URL('../../../../packages/pirc_render/test/fixtures/parity/document-dialog-modal-backdrop-chromium153.json',import.meta.url);
  writeFileSync(output,JSON.stringify(fixture,null,2)+'\n');
  console.log(output.pathname);
} finally {
  await browser.close();
}
