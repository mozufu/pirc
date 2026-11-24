// minimal stand-in for the design runtime, for local screenshots only
class DCLogic { constructor(){ this.state={}; this.props={}; } setState(o){ this.state=Object.assign({},this.state,o); window.__rerender && window.__rerender(); } }
window.DCLogic = DCLogic;
window.addEventListener('DOMContentLoaded', () => {
  const xdc = document.querySelector('x-dc');
  const helmet = xdc.querySelector('helmet'); if (helmet) helmet.remove();
  const tpl = xdc.innerHTML; xdc.innerHTML = '';
  const code = document.querySelector('script[data-dc-script]').textContent;
  const C = new Function('DCLogic', code + '; return Component;')(DCLogic);
  const comp = new C();
  const q = new URLSearchParams(location.search); q.forEach((v, k) => { comp.props[k] = v; });
  const get = (path, scope) => { path = path.trim(); if (path === 'true') return true; if (path === 'false') return false; return path.split('.').reduce((o, k) => (o == null ? undefined : o[k]), scope); };
  const interp = (str, scope) => str.replace(/\{\{([^}]+)\}\}/g, (_, p) => { const v = get(p, scope); return v == null ? '' : String(v); });
  const single = (str) => { const m = /^\{\{([^}]+)\}\}$/.exec(str.trim()); return m ? m[1] : null; };
  function proc(node, scope, out) {
    if (node.nodeType === 3) { out.appendChild(document.createTextNode(interp(node.textContent, scope))); return; }
    if (node.nodeType !== 1) return;
    const tag = node.tagName.toLowerCase();
    if (tag === 'sc-if') { const v = get(single(node.getAttribute('value')), scope); if (v === true || v === 'true' || (v && v !== 'false')) node.childNodes.forEach((c) => proc(c, scope, out)); return; }
    if (tag === 'sc-for') { const list = get(single(node.getAttribute('list')), scope) || []; const as = node.getAttribute('as'); list.forEach((item) => { const sc = Object.create(scope); sc[as] = item; node.childNodes.forEach((c) => proc(c, sc, out)); }); return; }
    const el = document.createElement(tag === 'svg' || node.namespaceURI === 'http://www.w3.org/2000/svg' ? tag : tag);
    let real = el;
    if (node.namespaceURI === 'http://www.w3.org/2000/svg') real = document.createElementNS('http://www.w3.org/2000/svg', node.tagName);
    for (const a of node.attributes) {
      if (a.name.startsWith('hint-')) continue;
      if (a.name.toLowerCase() === 'onclick') { const f = get(single(a.value) || '', scope); if (typeof f === 'function') real.addEventListener('click', (e) => { e.stopPropagation(); f(); }); continue; }
      if (a.name === 'disabled') { const p = single(a.value); if (p) { const v = get(p, scope); if (v === true || v === 'true') real.setAttribute('disabled', ''); } else real.setAttribute('disabled', ''); continue; }
      real.setAttribute(a.name, interp(a.value, scope));
    }
    node.childNodes.forEach((c) => proc(c, scope, real));
    out.appendChild(real);
  }
  const holder = document.createElement('template'); holder.innerHTML = tpl;
  window.__rerender = () => { const vals = comp.renderVals(); xdc.innerHTML = ''; holder.content.childNodes.forEach((c) => proc(c, vals, xdc)); };
  window.__rerender();
  window.__ready = true;
});
