/**
 * Remote images and media in untrusted content load only when the user asks.
 *
 * Text from a model, a tool or a document may name an image, a video, a style
 * sheet or a font. Fetching it as soon as the content is shown would let the
 * author learn that (and when, and from where) the message was read, and would
 * let the app's own origin be addressed by a URL it did not choose. So the
 * sanitiser keeps every fetchable attribute out of the content: the original
 * address is stored in a data attribute that does not fetch, and Markdown output
 * shows a placeholder with the alternative text, the source address and a
 * button. The button opens that address in a new tab, straight from the user's
 * device, without a referrer and without access to this page.
 *
 * What stays: `data:` sources (the bytes are in the content itself) and
 * references to a place inside the same document (`#id`). Images the app itself
 * shows (attachments, file previews) are not rendered through this path. An
 * address is never trusted for looking like one of the app's own: a relative or
 * same-origin URL is gated like any other.
 */
import { tr } from './i18n.svelte';

/** Where the original address of a gated source is kept (never fetched). */
export const REMOTE_SOURCE = 'data-remote-src';
/** The button that opens a gated source; its value is the absolute URL. */
export const REMOTE_OPEN = 'data-remote-open';

/** Longest address shown as text; the full value stays in the button. */
const SHOWN_URL_LENGTH = 400;

type Kind = 'image' | 'video' | 'audio';

/** True for a value that cannot make the browser fetch anything on its own. */
function inlineSource(value: string): boolean {
  const trimmed = value.trim();
  return trimmed === '' || trimmed.startsWith('#') || /^data:/i.test(trimmed);
}

/** CSS with its escapes resolved, for looking for functions an escape would hide. */
function unescapeCss(text: string): string {
  return text.replace(/\\(?:([0-9a-fA-F]{1,6})[ \t\n\r\f]?|([^\n\r\f]))/g, (_, hex, plain) => {
    if (plain !== undefined) return plain;
    const code = parseInt(hex, 16);
    return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : '�';
  });
}

/** Functions through which CSS can fetch a resource. */
const CSS_URL = /url\(\s*(?:"([^"]*)"|'([^']*)'|([^)]*))\s*\)/gi;

/** Whether every function in `text` that could fetch something is a `url()` to `data:` or `#id`. */
function cssIsInline(text: string): boolean {
  const plain = unescapeCss(text);
  if (/@import/i.test(plain)) return false;
  // Anything but url() (image-set(), src(), …) is not allowed to name a source.
  const others = plain.replace(CSS_URL, 'url()');
  if (
    /(?:^|[^\w-])(?:-webkit-)?(?:image-set|src|image|element|cross-fade|paint)\s*\(/i.test(others)
  )
    return false;
  for (const match of plain.matchAll(CSS_URL)) {
    const target = (match[1] ?? match[2] ?? match[3] ?? '').trim();
    if (!inlineSource(target)) return false;
  }
  return !/(?:^|[^\w-])url\s*\((?![^)]*\))/i.test(plain);
}

/** Split a declaration list on `;` outside quotes and parentheses (`data:…;base64,…` stays whole). */
function declarations(text: string): string[] {
  const parts: string[] = [];
  let depth = 0;
  let quote = '';
  let start = 0;
  for (let index = 0; index < text.length; index++) {
    const char = text[index]!;
    if (char === '\\') {
      index++;
    } else if (quote) {
      if (char === quote) quote = '';
    } else if (char === '"' || char === "'") {
      quote = char;
    } else if (char === '(') {
      depth++;
    } else if (char === ')') {
      depth = Math.max(0, depth - 1);
    } else if (char === ';' && depth === 0) {
      parts.push(text.slice(start, index));
      start = index + 1;
    }
  }
  parts.push(text.slice(start));
  return parts;
}

/**
 * An inline `style` value without the declarations that name a source to fetch
 * (`background: url(…)`, `list-style`, `border-image`, `mask`, `cursor`, `content`, …).
 * The rest of the styling is kept.
 */
export function cleanInlineStyle(value: string): string {
  const all = declarations(value).filter((declaration) => declaration.trim() !== '');
  const kept = all.filter((declaration) => cssIsInline(declaration));
  // Untouched when nothing had to go.
  if (kept.length === all.length) return value;
  return kept.map((declaration) => declaration.trim()).join('; ');
}

/**
 * Style sheet text (inside a diagram's SVG) without `@import` and without
 * `url()` to anything but `data:` or `#id`. A sheet that hides such a function
 * behind CSS escapes is dropped (`undefined`).
 */
export function cleanStyleSheet(text: string): string | undefined {
  const cleaned = text
    .replace(/@import\b[^;{}]*;?/gi, '')
    .replace(CSS_URL, (whole, double, single, bare) => {
      const target = (double ?? single ?? bare ?? '').trim();
      return inlineSource(target) ? whole : 'url("")';
    })
    .replace(/(?:-webkit-)?image-set\s*\([^)]*\)/gi, 'none');
  // Anything still fetching once escapes are resolved was hidden by them.
  return cssIsInline(cleaned) ? cleaned : undefined;
}

/** SVG presentation attributes whose value may be a CSS `url()`. */
const PRESENTATION_ATTRIBUTES = new Set([
  'fill',
  'stroke',
  'filter',
  'mask',
  'clip-path',
  'marker',
  'marker-start',
  'marker-mid',
  'marker-end',
  'cursor',
]);

const URL_ATTRIBUTES = ['src', 'poster', 'background', 'lowsrc', 'dynsrc', 'ping'];

function kindOf(element: Element): Kind | undefined {
  switch (element.localName) {
    case 'img':
    case 'image':
      return 'image';
    case 'input':
      return element.getAttribute('type')?.toLowerCase() === 'image' ? 'image' : undefined;
    case 'video':
      return 'video';
    case 'audio':
      return 'audio';
    default:
      return undefined;
  }
}

/** First candidate address of a `srcset`. */
function firstCandidate(srcset: string): string {
  const trimmed = srcset.trim();
  if (/^data:/i.test(trimmed)) return '';
  return trimmed.split(/[\s,]/, 1)[0] ?? '';
}

/**
 * Take every attribute that makes the browser fetch a remote resource off one
 * element. The first address found for an element is kept in {@link REMOTE_SOURCE}.
 * Runs as a DOMPurify hook, so it also covers the sanitiser calls Mermaid makes
 * for its labels.
 */
export function neutralizeRemoteSources(element: Element): void {
  if (element.nodeType !== 1) return;
  let remote = '';
  const keep = (value: string) => {
    if (!remote && value) remote = value.trim();
  };
  for (const name of URL_ATTRIBUTES) {
    const value = element.getAttribute(name);
    if (value === null) continue;
    if (name === 'src' && inlineSource(value)) continue;
    element.removeAttribute(name);
    if (name !== 'poster' && name !== 'ping' && name !== 'background') keep(value);
  }
  const srcset = element.getAttribute('srcset');
  if (srcset !== null) {
    element.removeAttribute('srcset');
    keep(firstCandidate(srcset));
  }
  // SVG: <image>, <use>, <feImage> and the like. Same-document references stay.
  for (const name of ['href', 'xlink:href']) {
    if (!element.hasAttribute(name)) continue;
    const tag = element.localName.toLowerCase();
    if (!['image', 'use', 'feimage', 'link'].includes(tag)) continue;
    const value = element.getAttribute(name)!;
    if (inlineSource(value)) continue;
    element.removeAttribute(name);
    if (tag === 'image') keep(value);
  }
  // Any other attribute (fill, filter, mask, marker, cursor, …) that points at a url().
  for (const attribute of Array.from(element.attributes)) {
    if (attribute.name === 'style') {
      const cleaned = cleanInlineStyle(attribute.value);
      if (cleaned) element.setAttribute('style', cleaned);
      else element.removeAttribute('style');
    } else if (PRESENTATION_ATTRIBUTES.has(attribute.name) && !cssIsInline(attribute.value)) {
      element.removeAttribute(attribute.name);
    }
  }
  if (element.localName === 'style' && element.textContent) {
    const cleaned = cleanStyleSheet(element.textContent);
    if (cleaned === undefined) element.remove();
    else if (cleaned !== element.textContent) element.textContent = cleaned;
  }
  if (
    remote &&
    (kindOf(element) || element.localName === 'source' || element.localName === 'track')
  ) {
    element.setAttribute(REMOTE_SOURCE, remote);
  }
}

/** Attributes carrying our own markers are never taken from the content. */
export function clearRemoteMarkers(element: Element): void {
  if (element.nodeType !== 1) return;
  for (const attribute of Array.from(element.attributes)) {
    if (attribute.name.startsWith('data-remote-')) element.removeAttribute(attribute.name);
  }
}

/** Resolve an address the way the page would have, for showing and opening. */
function resolve(value: string): URL | undefined {
  try {
    return new URL(value, document.baseURI);
  } catch {
    return undefined;
  }
}

function placeholder(kind: Kind, alt: string, source: string): HTMLElement {
  const url = resolve(source);
  const openable = !!url && (url.protocol === 'http:' || url.protocol === 'https:');
  const shown = (url?.href ?? source).slice(0, SHOWN_URL_LENGTH);
  const box = document.createElement('span');
  box.className = 'remote-media';
  box.setAttribute('data-remote-media', kind);
  box.setAttribute('role', 'group');
  const heading =
    kind === 'image'
      ? tr('Remote image not loaded')
      : kind === 'video'
        ? tr('Remote video not loaded')
        : tr('Remote audio not loaded');
  box.setAttribute('aria-label', heading);
  const title = document.createElement('span');
  title.className = 'remote-media-title';
  title.textContent = heading;
  box.append(title);
  if (alt.trim()) {
    const text = document.createElement('span');
    text.className = 'remote-media-alt';
    text.textContent = alt.trim().slice(0, 300);
    box.append(text);
  }
  const address = document.createElement('code');
  address.className = 'remote-media-url';
  address.textContent = shown + (url && url.href.length > SHOWN_URL_LENGTH ? '…' : '');
  box.append(address);
  if (openable) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'remote-media-open';
    button.setAttribute(REMOTE_OPEN, url.href);
    button.textContent =
      kind === 'image'
        ? tr('Open image in a new tab')
        : kind === 'video'
          ? tr('Open video in a new tab')
          : tr('Open audio in a new tab');
    box.append(button);
  }
  return box;
}

function altOf(element: Element): string {
  return (
    element.getAttribute('alt') ??
    element.getAttribute('aria-label') ??
    element.getAttribute('title') ??
    ''
  );
}

/** Replace what {@link neutralizeRemoteSources} marked with placeholders. */
export function gateRemoteContent(root: DocumentFragment | Element): void {
  for (const element of [...root.querySelectorAll(`[${REMOTE_SOURCE}]`)]) {
    // Already replaced together with an ancestor.
    if (!root.contains(element)) continue;
    const kind = kindOf(element);
    if (kind === 'video' || kind === 'audio') {
      const source =
        element.getAttribute(REMOTE_SOURCE) ??
        element.querySelector(`source[${REMOTE_SOURCE}]`)?.getAttribute(REMOTE_SOURCE) ??
        '';
      if (source) element.replaceWith(placeholder(kind, altOf(element), source));
      continue;
    }
    if (kind === 'image') {
      const source = element.getAttribute(REMOTE_SOURCE) ?? '';
      if (!source) continue;
      // An SVG <image> is the content of a wrapper drawing: gate the whole drawing.
      const target = element.localName === 'image' ? (element.closest('svg') ?? element) : element;
      target.replaceWith(placeholder('image', altOf(element), source));
      continue;
    }
    // A <source> or <track>: the media element around it is gated; a stray one is dropped.
    if (element.localName === 'source' || element.localName === 'track') {
      const media = element.closest('video, audio');
      if (media && element.localName === 'source') {
        media.replaceWith(
          placeholder(media.localName as Kind, altOf(media), element.getAttribute(REMOTE_SOURCE)!),
        );
      } else if (!media) {
        element.remove();
      }
    }
  }
  // <picture> with its sources gone and no image left is empty chrome.
  for (const picture of [...root.querySelectorAll('picture')]) {
    for (const source of picture.querySelectorAll('source')) source.remove();
  }
}

/**
 * Open a gated address in a new tab. Called from a user's click only.
 * Only http(s) addresses are opened; the tab gets no `opener` and no referrer.
 */
export function openRemote(value: string | null | undefined): boolean {
  const url = value ? resolve(value) : undefined;
  if (!url || (url.protocol !== 'http:' && url.protocol !== 'https:')) return false;
  const link = document.createElement('a');
  link.href = url.href;
  link.target = '_blank';
  link.rel = 'noopener noreferrer';
  link.referrerPolicy = 'no-referrer';
  link.click();
  return true;
}
