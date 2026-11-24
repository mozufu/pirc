// Static render adapter for the supplied x-dc handoff; does not change handoff files.
const fs=require('fs');
// Set PIRC_PLAYWRIGHT_MODULE if Playwright is installed outside this project.
const {chromium}=require(process.env.PIRC_PLAYWRIGHT_MODULE || 'playwright');
const path=require('path');
const root=path.resolve(__dirname, '../../../pirc-mobile-handoff/prototype');
const out=path.resolve(__dirname, '../build/design-reference');
fs.mkdirSync(out,{recursive:true});
(async()=>{
 const browser=await chromium.launch({executablePath:process.env.PIRC_CHROME_PATH,headless:true});
 const page=await browser.newPage({viewport:{width:390,height:844},deviceScaleFactor:1});
 const html=fs.readFileSync(root+'/PhoneC.dc.html','utf8');
 const script=html.match(/<script type="text\/x-dc"[^>]*>([\s\S]*?)<\/script>/)[1];
 const template=html.match(/<x-dc>([\s\S]*?)<script type=/)[1];
 for(const dark of [false,true]) for(const start of ['home','session','settings','model','panelGit','panelFiles','activity','reader']) {
 await page.setContent('<style>body{margin:0}sc-if,sc-for{display:contents}</style><style>'+fs.readFileSync(root+'/pirc-c.css','utf8')+'</style><main></main>');
 await page.evaluate(({script,template,start,dark})=>{
  const Component=new Function('DCLogic',script+';return Component;')(class{setState(){}});
  const component=new Component();component.props={start,dark,marks:false}; const vals=component.renderVals();
  const get=(expr,ctx)=>{try{return new Function('ctx','with(ctx){return ('+expr+')}')(ctx)}catch{return ''}};
  const bind=(str,ctx)=>str.replace(/{{(.*?)}}/g,(_,expr)=>{const v=get(expr,ctx);return typeof v==='function'?'':v??''});
  const main=document.querySelector('main'); main.innerHTML=template;
  function walk(node,ctx){
   if(node.nodeType===3){node.textContent=bind(node.textContent,ctx);return;}
   if(node.nodeType!==1)return;
   if(node.tagName==='SC-IF'&&!get(node.getAttribute('value').slice(2,-2),ctx)){node.remove();return;}
   if(node.tagName==='SC-FOR'){
    const items=get(node.getAttribute('list').slice(2,-2),ctx)||[];
    for(const value of items){const el=document.createElement('span');el.style.display='contents';el.innerHTML=node.innerHTML;node.before(el);walk(el,{...ctx,[node.getAttribute('as')]:value});}
    node.remove();return;
   }
   for(const attr of [...node.attributes]){if(attr.name.startsWith('on'))node.removeAttribute(attr.name);else if(attr.name==='disabled'&&attr.value.includes('{{')){if(!get(attr.value.slice(2,-2),ctx))node.removeAttribute(attr.name);}else node.setAttribute(attr.name,bind(attr.value,ctx));}
   [...node.childNodes].forEach(n=>walk(n,ctx));
  }
  walk(main,vals);
 },{script,template,start,dark});
 await page.screenshot({path:path.join(out, `${start}-${dark?'dark':'light'}.png`)});
 }
 await browser.close();
})();
