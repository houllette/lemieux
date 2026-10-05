// Portions adapted from jev-ultrafast at 1231850a (browser-use/jev-ultrafast,
// jev_ultrafast/snapshot.js at 1231850a0bf1a0c0341fe408ef1668dbbfdfac46),
// MIT License, Copyright (c) 2026 Browser Use. See ../NOTICE for the license.
// This script is extension-owned; model responses never become executable code.
const command = arguments[0], args = arguments[1];
if (!document.body) return null;
const cache = window.__lmxComputerUse ||= { ids: new WeakMap(), nodes: new Map(), next: 1 };
const identity = e => {
  if (!cache.ids.has(e)) cache.ids.set(e, String(cache.next++));
  const id = cache.ids.get(e); cache.nodes.set(id, e); return id;
};
for (const [id, e] of cache.nodes) if (!e.isConnected) cache.nodes.delete(id);
const visible = e => e.isConnected && !e.closest('[aria-hidden="true"],[inert]') &&
  e.checkVisibility({checkOpacity:true, checkVisibilityCSS:true});
const name = (e, seen = new Set()) => {
  if (!e || seen.has(e)) return '';
  seen.add(e);
  return ((e.getAttribute('aria-labelledby') || '').split(/\s+/)
    .map(id => name(document.getElementById(id), seen)).filter(Boolean).join(' ') ||
    e.getAttribute('aria-label') || [...(e.labels || [])].map(l => {
      const copy=l.cloneNode(true);
      copy.querySelectorAll('input,select,textarea,button,[aria-hidden="true"]').forEach(n=>n.remove());
      return copy.textContent;
    }).join(' ') ||
    e.getAttribute('alt') || (e.tagName === 'INPUT' ? '' : e.innerText) ||
    e.getAttribute('placeholder') || e.getAttribute('title') ||
    (['submit','button'].includes(e.type) ? e.value : '') || '').trim().slice(0, 240);
};
const safe = e => !['password','file','hidden'].includes(e.type);
const formState = () => JSON.stringify([...document.querySelectorAll('input,textarea,select')]
  .filter(safe).slice(0, 200).map(e => [identity(e), String(e.value).slice(0,2000), e.checked, e.selectedIndex]));
const guard = e => JSON.stringify([name(e), e.value, e.checked, e.disabled, e.readOnly,
  e.getAttribute('aria-expanded'), e.getAttribute('aria-selected'), e.getAttribute('href'),
  (e.closest('form,dialog,[role="dialog"],li,tr') || e.parentElement)?.innerText?.slice(0, 1500)]);

if (command === 'resolve') {
  const {page, action} = args;
  if (page.document !== performance.timeOrigin || page.url !== location.href) return {stale:true};
  if (action.operation === 'SCROLL_DOWN' || action.operation === 'SCROLL_UP') {
    if (action.scroll_y !== scrollY) return {stale:true};
    scrollBy(0, action.operation === 'SCROLL_DOWN' ? 600 : -600);
    return {scrolled:true};
  }
  const e = cache.nodes.get(action.node), control = action.operation === 'SELECT' ? e?.closest('select') : e;
  if (!e?.isConnected || !control || !visible(control) || control.matches(':disabled') ||
      control.closest('[aria-disabled="true"]') || action.guard !== guard(control) ||
      page.form_state !== formState()) return {stale:true};
  if (action.operation === 'TYPE_TEXT' && (control.readOnly || control.getAttribute('aria-readonly') === 'true')) return {stale:true};
  if (action.operation === 'SELECT' && (e.disabled || e.closest('optgroup[disabled]'))) return {stale:true};
  const r = control.getBoundingClientRect(), x = r.x + r.width/2, y = r.y + r.height/2;
  if (x < 0 || y < 0 || x >= innerWidth || y >= innerHeight || !control.contains(document.elementFromPoint(x,y))) return {stale:true};
  return {element:e};
}

const actions = [], fields = formState();
const selector = 'a[href],button,input,textarea,select,summary,[contenteditable="true"],[role="button"],[role="link"],[role="combobox"],[role="option"],[role="checkbox"],[role="tab"],[role="menuitem"],[role="switch"],[role="gridcell"]';
let scanned = 0, omitted = 0;
for (const e of document.querySelectorAll(selector)) {
  if (++scanned > 2000) { omitted++; continue; }
  if (!safe(e) || !visible(e) || e.matches(':disabled') || e.closest('[aria-disabled="true"]')) continue;
  const r = e.getBoundingClientRect();
  if (!r.width || !r.height || r.x+r.width/2 < 0 || r.x+r.width/2 >= innerWidth || r.y+r.height/2 < 0 || r.y+r.height/2 >= innerHeight) continue;
  const role = e.getAttribute('role') || e.tagName.toLowerCase();
  const base = {node:identity(e), label:name(e) || role, role,
    value:String(e.value ?? '').slice(0, 500), checked:e.checked ?? null,
    expanded:e.getAttribute('aria-expanded'), guard:guard(e),
    href:e.href || null, form_action:e.form?.action || null};
  const add = action => { if (actions.length < 150) actions.push({...action, id:String(actions.length+1)}); else omitted++; };
  if (e.tagName === 'SELECT') {
    for (const option of e.options) if (!option.selected && !option.disabled && !option.closest('optgroup[disabled]'))
      add({...base, node:identity(option), operation:'SELECT', label:base.label+' → '+option.label});
  } else {
    const editable = !e.readOnly && e.getAttribute('aria-readonly') !== 'true' &&
      (e.tagName === 'TEXTAREA' || e.isContentEditable ||
       (e.tagName === 'INPUT' && ['text','search','email','url','tel','number'].includes(e.type)));
    if (editable) add({...base, operation:'TYPE_TEXT'});
    add({...base, operation:'CLICK'});
  }
}
if (scrollY + innerHeight < document.documentElement.scrollHeight - 2)
  actions.push({id:'down', operation:'SCROLL_DOWN', label:'Scroll down', scroll_y:scrollY});
if (scrollY > 0) actions.push({id:'up', operation:'SCROLL_UP', label:'Scroll up', scroll_y:scrollY});
const words=[], walker=document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT), range=document.createRange();
let node, length=0, textNodes=0;
while ((node=walker.nextNode()) && length < 6000 && ++textNodes < 10000) {
  const value=node.textContent.trim(), e=node.parentElement;
  if (!value || !e || e.closest('script,style,noscript,template') || !visible(e)) continue;
  range.selectNodeContents(node); const r=range.getBoundingClientRect();
  if (r.bottom>0 && r.top<innerHeight && r.right>0 && r.left<innerWidth) {words.push(value); length+=value.length;}
}
return {url:location.href, title:document.title, document:performance.timeOrigin,
  text:words.join('\n').slice(0,6000), form_state:fields, actions, omitted_actions:omitted};
