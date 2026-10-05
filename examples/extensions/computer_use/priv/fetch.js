// Whole-document fetch projection, including content below the viewport.
// Only fixed tag/attribute names are serialized; form values are never read.
const limit = arguments[0], encoder = new TextEncoder();
const escape = s => String(s).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;');
const root = document.querySelector('article,main,[role="main"]') || document.body;
const parts = []; let bytes = 0, count = 0, truncated = false;
function add(s) {
  const size = encoder.encode(s).length;
  if (bytes + size > limit) {
    const buffer = new Uint8Array(Math.max(0,limit-bytes));
    const {written} = encoder.encodeInto(s,buffer);
    parts.push(new TextDecoder().decode(buffer.subarray(0,written))); bytes += written;
    truncated = true; return false;
  }
  parts.push(s); bytes += size; return true;
}
const omitted = new Set(['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','SVG','IFRAME','INPUT','TEXTAREA']);
function visit(node, depth) {
  if (truncated) return;
  if (++count > 20000 || depth > 100) { truncated = true; return; }
  if (node.nodeType === Node.TEXT_NODE) { add(escape(node.textContent)); return; }
  if (node.nodeType !== Node.ELEMENT_NODE || omitted.has(node.tagName) ||
      node.hidden || node.getAttribute('aria-hidden') === 'true') return;
  const style = getComputedStyle(node);
  if (style.display === 'none' || style.visibility === 'hidden') return;
  const tag = node.tagName.toLowerCase();
  let attrs = '';
  for (const key of ['role','id','class']) if (node.hasAttribute(key))
    attrs += ' '+key+'="'+escape(node.getAttribute(key).slice(0,500))+'"';
  if (tag === 'a' && node.href) attrs += ' href="'+escape(node.href.slice(0,2048))+'"';
  if (!add('<'+tag+attrs+'>')) return;
  for (const child of node.childNodes) { visit(child,depth+1); if (truncated) break; }
  if (!['br','hr','img','wbr','source','link','meta'].includes(tag)) add('</'+tag+'>');
}
add('<title>'+escape(document.title.slice(0,300))+'</title>');
if (root) visit(root,0);
const text = (root?.innerText || '').trim();
return {url:location.href, html:parts.join(''), truncated,
  ready:document.readyState !== 'loading' && text.length > 0 &&
    !root?.querySelector('[aria-busy="true"]') && root?.getAttribute('aria-busy') !== 'true' &&
    !(text.length < 200 && /^(?:loading\b|please wait\b|(?:please )?enable javascript|this (?:page|app) requires? javascript)/i.test(text))};
