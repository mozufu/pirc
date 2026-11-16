import { tr } from './i18n.svelte';
/**
 * Markdown → sanitized HTML for conversation content.
 *
 * - GFM (tables, task lists, strikethrough) via marked
 * - LaTeX via KaTeX: `$…$`, `\(…\)` inline; `$$…$$`, `\[…\]` display
 * - Syntax highlighting via highlight.js (common languages)
 * - ```mermaid blocks become placeholders rendered lazily by {@link enhanceMarkdown}
 *
 * Output is always passed through DOMPurify: model output and tool results are untrusted.
 */
import DOMPurify from 'dompurify';
import { Marked, type Token, type Tokens, type TokenizerAndRendererExtension } from 'marked';
import { writable } from 'svelte/store';
import {
  BARE_PATH,
  BARE_PATH_SEARCH,
  CODE_PATH,
  localFilePath,
  parseFileLink,
  requestFilePreview,
  stripFileScheme,
} from './file-links';

const escapeHtml = (value: string) =>
  value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');

/*
 * KaTeX and highlight.js are the two largest pieces of the main bundle, and most
 * messages need neither. They are loaded on first use: rendering is kept
 * synchronous, emitting plain text until the module lands, and `rendererTick`
 * bumps so components that depend on it re-render once with the real output.
 */
type Katex = typeof import('katex').default;
type Hljs = typeof import('highlight.js/lib/common').default;

let katex: Katex | undefined;
let hljs: Hljs | undefined;
let katexLoader: Promise<void> | undefined;
let hljsLoader: Promise<void> | undefined;

/**
 * Set while rendering when output fell back to plain text because KaTeX or
 * highlight.js had not loaded yet; only such output needs a re-render once
 * `rendererTick` bumps.
 */
let usedFallback = false;

/** Bumped when a lazily loaded renderer becomes available. */
export const rendererTick = writable(0);
const bump = () => rendererTick.update((n) => n + 1);

export function loadKatex(): Promise<void> {
  katexLoader ??= Promise.all([import('katex'), import('katex/dist/katex.min.css')]).then(
    ([module]) => {
      katex = module.default;
      bump();
    },
  );
  return katexLoader;
}

export function loadHighlighter(): Promise<void> {
  hljsLoader ??= import('highlight.js/lib/common').then((module) => {
    hljs = module.default;
    bump();
  });
  return hljsLoader;
}

/** Whether highlight.js has loaded (until then `highlightCode` returns plain text). */
export const highlighterReady = () => !!hljs;

/** Load both renderers up front (tests, or idle-time warm-up). */
export const preloadRenderers = () => Promise.all([loadKatex(), loadHighlighter()]);

function renderMath(source: string, displayMode: boolean): string {
  if (!katex) {
    usedFallback = true;
    void loadKatex();
    return `<code class="math-pending">${escapeHtml(source)}</code>`;
  }
  try {
    return katex.renderToString(source, {
      displayMode,
      throwOnError: false,
      strict: 'ignore',
      output: 'htmlAndMathml',
      trust: false,
      maxExpand: 500,
    });
  } catch {
    return `<code class="math-error">${escapeHtml(source)}</code>`;
  }
}

const blockMath: TokenizerAndRendererExtension = {
  name: 'blockMath',
  level: 'block',
  start: (src) => src.match(/\$\$|\\\[/)?.index,
  tokenizer(src) {
    const match = /^(?:\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\])[^\S\n]*(?:\n|$)/.exec(src);
    if (!match) return undefined;
    return { type: 'blockMath', raw: match[0], text: (match[1] ?? match[2] ?? '').trim() };
  },
  renderer: (token) => `<div class="math-block">${renderMath(token.text, true)}</div>\n`,
};

const inlineMath: TokenizerAndRendererExtension = {
  name: 'inlineMath',
  level: 'inline',
  start: (src) => src.match(/\$|\\\(/)?.index,
  tokenizer(src) {
    // $$…$$ used inline (e.g. inside a sentence or list item) still renders as display math.
    const display = /^\$\$([^$]+?)\$\$/.exec(src);
    if (display)
      return { type: 'inlineMath', raw: display[0], text: display[1]!.trim(), display: true };
    const paren = /^\\\(([\s\S]+?)\\\)/.exec(src);
    if (paren) return { type: 'inlineMath', raw: paren[0], text: paren[1]!.trim(), display: false };
    // `$x$`: no space inside the delimiters and no digit right after, so "$5 and $10" stays text.
    const dollar = /^\$(?!\s)((?:\\.|[^\\$\n])+?)(?<!\s)\$(?!\d)/.exec(src);
    if (dollar) return { type: 'inlineMath', raw: dollar[0], text: dollar[1]!, display: false };
    return undefined;
  },
  renderer: (token) => renderMath(token.text, !!token.display),
};

/** Bare file paths in prose (`see src/a.ts:12`) become file links. */
const barePath: TokenizerAndRendererExtension = {
  name: 'barePath',
  level: 'inline',
  start: (src) => src.match(BARE_PATH_SEARCH)?.index,
  tokenizer(src) {
    if (this.lexer.state.inLink) return undefined;
    const match = BARE_PATH.exec(src);
    return match ? { type: 'barePath', raw: match[0], text: match[0] } : undefined;
  },
  renderer: (token) => `<a href="${escapeHtml(token.text)}">${escapeHtml(token.text)}</a>`,
};

function highlight(code: string, language: string): string {
  if (!language) return escapeHtml(code);
  if (!hljs) {
    usedFallback = true;
    void loadHighlighter();
    return escapeHtml(code);
  }
  if (hljs.getLanguage(language)) {
    try {
      return hljs.highlight(code, { language, ignoreIllegals: true }).value;
    } catch {
      /* fall through */
    }
  }
  return escapeHtml(code);
}

const marked = new Marked({
  gfm: true,
  breaks: false,
  extensions: [blockMath, inlineMath, barePath],
  walkTokens(token) {
    // Inline code inside a link must not become a (nested) file link.
    if (token.type !== 'link') return;
    const mark = (tokens: Token[] | undefined) =>
      tokens?.forEach((child) => {
        if (child.type === 'codespan')
          (child as Tokens.Codespan & { inLink?: boolean }).inLink = true;
        if ('tokens' in child) mark(child.tokens);
      });
    mark(token.tokens);
  },
  hooks: {
    emStrongMask(source) {
      // CommonMark treats punctuation before ** followed by text as an opener,
      // not a closer (e.g. **驗證：**新增). Treat CJK punctuation as a letter
      // only in the delimiter-analysis mask; preserve source text and offsets.
      // Marked has already masked code, links, HTML, and escaped delimiters.
      return source.replace(/[\u3000-\u303f\uff00-\uffef](?=\*\*(?!\*)[^\s*])/gu, (char) =>
        /\p{P}/u.test(char) ? 'a' : char,
      );
    },
  },
  renderer: {
    codespan(token: Tokens.Codespan & { inLink?: boolean }) {
      // `src/a.ts:12` in inline code links to the file.
      const code = `<code>${escapeHtml(token.text)}</code>`;
      if (token.inLink || !CODE_PATH.test(token.text)) return code;
      return `<a href="${escapeHtml(token.text)}">${code}</a>`;
    },
    code({ text, lang }: Tokens.Code) {
      const language = (lang ?? '').trim().split(/\s+/)[0]!.toLowerCase();
      if (language === 'mermaid')
        // Source lives in the text node: DOMPurify drops attributes containing `-->`.
        return `<div class="mermaid-block"><pre class="mermaid-source"><code>${escapeHtml(text)}</code></pre></div>\n`;
      if (language === 'math' || language === 'latex' || language === 'tex')
        return `<div class="math-block">${renderMath(text, true)}</div>\n`;
      const label = language || 'text';
      return `<div class="code-block"><div class="code-head"><span>${escapeHtml(label)}</span><button type="button" class="code-copy" data-copy>${escapeHtml(tr('Copy'))}</button></div><pre><code class="hljs language-${escapeHtml(label)}">${highlight(text, language)}</code></pre></div>\n`;
    },
    table(token: Tokens.Table) {
      // Wrap so wide tables scroll horizontally instead of stretching the timeline.
      const header = token.header
        .map(
          (cell) =>
            `<th${cell.align ? ` align="${cell.align}"` : ''}>${this.parser.parseInline(cell.tokens)}</th>`,
        )
        .join('');
      const rows = token.rows
        .map(
          (row) =>
            `<tr>${row
              .map(
                (cell) =>
                  `<td${cell.align ? ` align="${cell.align}"` : ''}>${this.parser.parseInline(cell.tokens)}</td>`,
              )
              .join('')}</tr>`,
        )
        .join('');
      return `<div class="table-wrap"><table><thead><tr>${header}</tr></thead><tbody>${rows}</tbody></table></div>\n`;
    },
  },
});

/**
 * Attributes that give a form (or a button of one) a submission target. Content
 * shown here is not the app: a form in it may submit to other sites, but never
 * to the app's own origin, whatever form the URL is written in (relative,
 * absolute, protocol-relative).
 */
const FORM_TARGET_ATTRIBUTES = ['action', 'formaction'];

function dropSameOriginFormTargets(node: Element) {
  for (const name of FORM_TARGET_ATTRIBUTES) {
    const value = node.getAttribute?.(name);
    if (value === null || value === undefined) continue;
    let sameOrigin = true;
    try {
      sameOrigin = new URL(value.trim(), document.baseURI).origin === window.location.origin;
    } catch {
      // A target that cannot be resolved is not kept.
    }
    if (sameOrigin) node.removeAttribute(name);
  }
}

/** Options for untrusted content: styles never come with it. */
const CONTENT_SANITIZE = {
  // `formaction` is allowed so forms to other sites work; same-origin ones are dropped by the hook.
  ADD_ATTR: ['target', 'data-copy', 'data-file-link', 'formaction'],
  ADD_TAGS: ['semantics', 'annotation'],
  FORBID_TAGS: ['style'],
};

let hooked = false;
function purifier() {
  if (!hooked && typeof window !== 'undefined') {
    DOMPurify.addHook('beforeSanitizeAttributes', (node) => {
      // DOMPurify drops `file:` URLs; keep them as plain paths so they stay previewable.
      const href = node.tagName === 'A' ? node.getAttribute('href') : null;
      if (href && /^file:/i.test(href.trim()))
        node.setAttribute('href', stripFileScheme(href) || '#');
    });
    DOMPurify.addHook('afterSanitizeAttributes', (node) => {
      dropSameOriginFormTargets(node);
      if (node.tagName !== 'A' || !node.getAttribute('href')) return;
      // Workspace file links open in the side panel (see enhanceMarkdown), not a new tab.
      if (localFilePath(node.getAttribute('href'))) {
        node.removeAttribute('target');
        node.setAttribute('data-file-link', '');
        return;
      }
      node.setAttribute('target', '_blank');
      node.setAttribute('rel', 'noopener noreferrer');
    });
    hooked = true;
  }
  return DOMPurify;
}

/** Close an unterminated code fence so a streaming message renders stably. */
function closeOpenFence(source: string): string {
  const fences = source.match(/^ {0,3}(`{3,}|~{3,})/gm);
  if (!fences || fences.length % 2 === 0) return source;
  const fence = fences[fences.length - 1]!.trim();
  return `${source}\n${fence}`;
}

/**
 * Where the last top-level block of `source` starts, searching from `from`
 * (itself a block boundary). Blocks before it are complete: text arriving
 * later cannot change how they render, so a streaming message renders them
 * once and re-renders only the last block. Returns `from` when unsure.
 */
export function stableBlockEnd(source: string, from = 0): number {
  const rest = source.slice(from);
  if (rest.includes('\r')) return from;
  const tokens = marked.lexer(rest);
  let last = tokens.length - 1;
  while (last >= 0 && tokens[last]!.type === 'space') last--;
  if (last <= 0) return from;
  let raw = '';
  for (let index = 0; index < last; index++) raw += tokens[index]!.raw;
  // Token offsets are only trusted when their raw text is the source verbatim.
  return rest.startsWith(raw) ? from + raw.length : from;
}

export function renderMarkdown(source: string, options: { streaming?: boolean } = {}): string {
  return renderMarkdownChecked(source, options).html;
}

/**
 * Like {@link renderMarkdown}; `pending` tells whether math or code was
 * rendered as plain text while its renderer loads (re-render on `rendererTick`).
 */
export function renderMarkdownChecked(
  source: string,
  options: { streaming?: boolean } = {},
): { html: string; pending: boolean } {
  if (!source) return { html: '', pending: false };
  usedFallback = false;
  const input = options.streaming ? closeOpenFence(source) : source;
  const html = marked.parse(input, { async: false });
  const pending = usedFallback;
  return {
    html: purifier().sanitize(html, CONTENT_SANITIZE),
    pending,
  };
}

/**
 * Longer text is shown without highlighting: highlight.js runs synchronously
 * on the main thread and would freeze the page on a large file.
 */
export const MAX_HIGHLIGHT = 200_000;

/** Highlight a standalone snippet (tool input/output). Returns sanitized HTML. */
export function highlightCode(code: string, language?: string): string {
  const html = code.length > MAX_HIGHLIGHT ? escapeHtml(code) : highlight(code, language ?? '');
  // The highlighter only produces spans; nothing else passes.
  return purifier().sanitize(html, { ALLOWED_TAGS: ['span'], ALLOWED_ATTR: ['class'] });
}

/** At most `MAX_HIGHLIGHT` characters of `text`, with a note of how much was cut. */
export function clipText(text: string): string {
  if (text.length <= MAX_HIGHLIGHT) return text;
  const rest = text.length - MAX_HIGHLIGHT;
  return tr('{0}\n… {1} more characters not shown', [
    text.slice(0, MAX_HIGHLIGHT),
    rest.toLocaleString('en'),
  ]);
}

const EXTENSION_LANGUAGES: Record<string, string> = {
  ts: 'typescript',
  tsx: 'typescript',
  mts: 'typescript',
  cts: 'typescript',
  js: 'javascript',
  jsx: 'javascript',
  mjs: 'javascript',
  cjs: 'javascript',
  py: 'python',
  rs: 'rust',
  go: 'go',
  rb: 'ruby',
  java: 'java',
  kt: 'kotlin',
  swift: 'swift',
  c: 'c',
  h: 'c',
  cc: 'cpp',
  cpp: 'cpp',
  hpp: 'cpp',
  cs: 'csharp',
  php: 'php',
  sh: 'bash',
  bash: 'bash',
  zsh: 'bash',
  json: 'json',
  yaml: 'yaml',
  yml: 'yaml',
  toml: 'ini',
  ini: 'ini',
  md: 'markdown',
  html: 'xml',
  xml: 'xml',
  svelte: 'xml',
  vue: 'xml',
  css: 'css',
  scss: 'scss',
  less: 'less',
  sql: 'sql',
  lua: 'lua',
  diff: 'diff',
  patch: 'diff',
  graphql: 'graphql',
  r: 'r',
  pl: 'perl',
  mk: 'makefile',
};

export function languageForPath(path: unknown): string | undefined {
  if (typeof path !== 'string') return undefined;
  const name = path.split('/').pop() ?? '';
  if (/^(Makefile|GNUmakefile)$/.test(name)) return 'makefile';
  if (name === 'Dockerfile') return 'dockerfile';
  const extension = name.includes('.') ? name.split('.').pop()!.toLowerCase() : '';
  return EXTENSION_LANGUAGES[extension];
}

type MermaidApi = typeof import('mermaid').default;
let mermaidLoader: Promise<MermaidApi> | undefined;
let mermaidCount = 0;

function loadMermaid(): Promise<MermaidApi> {
  mermaidLoader ??= import('mermaid').then(({ default: mermaid }) => {
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: 'strict',
      theme: matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'base',
      fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
      themeVariables: matchMedia('(prefers-color-scheme: dark)').matches
        ? { fontSize: '13px' }
        : {
            background: '#ffffff',
            primaryColor: '#edf3fe',
            primaryBorderColor: '#4176e6',
            primaryTextColor: '#0f1115',
            lineColor: '#81858c',
            secondaryColor: '#f1f3f5',
            tertiaryColor: '#f9fafb',
            fontSize: '13px',
          },
    });
    return mermaid;
  });
  return mermaidLoader;
}

async function renderMermaidBlocks(root: HTMLElement) {
  const blocks = [...root.querySelectorAll<HTMLElement>('.mermaid-block:not([data-rendered])')];
  if (!blocks.length) return;
  const mermaid = await loadMermaid();
  for (const block of blocks) {
    const source = block.querySelector('.mermaid-source code')?.textContent ?? '';
    block.dataset.rendered = 'pending';
    try {
      const { svg } = await mermaid.render(`pirc-mermaid-${++mermaidCount}`, source);
      if (!block.isConnected) continue;
      const figure = document.createElement('div');
      figure.className = 'mermaid-figure';
      // Mermaid's strict mode sanitizes labels; this also covers the SVG it builds around them.
      figure.innerHTML = purifier().sanitize(svg, {
        USE_PROFILES: { html: true, svg: true, svgFilters: true },
        // HTML labels sit in foreignObject.
        ADD_TAGS: ['foreignObject'],
      });
      block.prepend(figure);
      block.dataset.rendered = 'ok';
    } catch (error) {
      block.dataset.rendered = 'error';
      const note = document.createElement('p');
      note.className = 'mermaid-error';
      note.textContent = `Mermaid: ${error instanceof Error ? error.message.split('\n')[0] : 'invalid diagram'}`;
      block.append(note);
    }
  }
}

interface EnhanceParams {
  html: string;
  ready: boolean;
  /** Directory relative links resolve against (a previewed document's folder). */
  linkBase?: string;
}

/**
 * Svelte action: copy buttons on code blocks, workspace file links (opened in
 * the side panel) and lazy Mermaid rendering.
 * Diagrams render only once `ready` is true (i.e. the message stopped streaming),
 * since a half-written diagram cannot be parsed.
 */
export function enhanceMarkdown(node: HTMLElement, params: EnhanceParams) {
  let linkBase = params.linkBase ?? '';
  const openFileLink = (event: MouseEvent) => {
    const link = (event.target as HTMLElement).closest<HTMLAnchorElement>('a[data-file-link]');
    if (!link || !node.contains(link)) return false;
    event.preventDefault();
    const target = parseFileLink(link.getAttribute('href'), linkBase);
    if (target) requestFilePreview(target);
    return true;
  };
  // Middle click would otherwise open the 404ing URL in a new tab.
  const onAuxClick = (event: MouseEvent) => {
    if (event.button === 1) openFileLink(event);
  };
  const onClick = (event: MouseEvent) => {
    if (openFileLink(event)) return;
    const button = (event.target as HTMLElement).closest<HTMLButtonElement>('[data-copy]');
    if (!button || !node.contains(button)) return;
    const code = button.closest('.code-block')?.querySelector('code')?.textContent ?? '';
    void navigator.clipboard?.writeText(code).then(() => {
      button.textContent = tr('Copied');
      setTimeout(() => (button.textContent = tr('Copy')), 1400);
    });
  };
  node.addEventListener('click', onClick);
  node.addEventListener('auxclick', onAuxClick);
  const run = (next: { ready: boolean }) => {
    if (next.ready) void renderMermaidBlocks(node);
  };
  run(params);
  return {
    update: (next: EnhanceParams) => {
      linkBase = next.linkBase ?? '';
      queueMicrotask(() => run(next));
    },
    destroy: () => {
      node.removeEventListener('click', onClick);
      node.removeEventListener('auxclick', onAuxClick);
    },
  };
}
