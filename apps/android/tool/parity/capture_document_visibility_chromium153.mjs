import { createRequire } from 'node:module';
import { writeFile } from 'node:fs/promises';
import { requireTestBrowserExecutable } from './test_browser.mjs';
const { chromium } = createRequire(import.meta.url)('playwright-core');
const probe = `(function(){
 const d=document;const events=[];let strictHidden=false,strictState=false;
 try{(function(){'use strict';d.hidden=true})()}catch(e){strictHidden=e.name==='TypeError'}
 try{(function(){'use strict';d.visibilityState='hidden'})()}catch(e){strictState=e.name==='TypeError'}
 const initial={hidden:d.hidden,state:d.visibilityState,handler:d.onvisibilitychange,strictHidden,strictState};
 function record(name){return function(e){events.push({name,thisDocument:this===d,thisWindow:this===window,target:e.target===d,current:e.currentTarget===d?'document':'window',phase:e.eventPhase,bubbles:e.bubbles,cancelable:e.cancelable,composed:e.composed,trusted:e.isTrusted});e.preventDefault()}}
 const capture=record('capture'),body=record('document'),bubble=record('bubble');
 window.addEventListener('visibilitychange',capture,true);d.addEventListener('visibilitychange',body);
 d.onvisibilitychange=record('handler');window.addEventListener('visibilitychange',bubble);
 const event=new Event('visibilitychange',{bubbles:true});d.dispatchEvent(event);
 window.removeEventListener('visibilitychange',capture,true);d.removeEventListener('visibilitychange',body);window.removeEventListener('visibilitychange',bubble);d.onvisibilitychange=null;
 return {initial,events,after:{defaultPrevented:event.defaultPrevented,currentTarget:event.currentTarget,eventPhase:event.eventPhase}};
})()`;
const browser = await chromium.launch({
  executablePath: requireTestBrowserExecutable(),
  headless: true,
});
try {
  const browserVersion = browser.version();
  if (browserVersion !== '153.0.8010.12') throw new Error('Expected pinned Chromium');
  const page = await browser.newPage();
  await page.route('**/*', (route) => route.abort());
  const result = await page.evaluate(probe);
  const fixture = {
    schemaVersion: 1,
    browserVersion,
    probe,
    result,
    scope:
      'Initial readonly properties and synthetic DOM event propagation. Real tab/background transitions are not established by this Headless Shell capture.',
    specification: 'https://html.spec.whatwg.org/multipage/interaction.html#page-visibility',
  };
  await writeFile(
    new URL('../../../../packages/pirc_render/test/fixtures/parity/document-visibility-chromium153.json', import.meta.url),
    JSON.stringify(fixture, null, 2) + '\n',
  );
  console.log(
    JSON.stringify({
      browserVersion,
      initial: result.initial,
      eventOrder: result.events.map((e) => e.name),
    }),
  );
} finally {
  await browser.close();
}
