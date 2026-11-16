// @vitest-environment jsdom
import { beforeAll, describe, expect, it } from 'vitest';
import { highlightCode, preloadRenderers, renderMarkdown, stableBlockEnd } from './markdown';

describe('renderMarkdown', () => {
  beforeAll(() => preloadRenderers());

  it('renders GFM and highlighted code', () => {
    const html = renderMarkdown(
      '# Title\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```ts\nconst x = 1;\n```',
    );
    expect(html).toContain('<h1>Title</h1>');
    expect(html).toContain('<div class="table-wrap"><table>');
    expect(html).toContain('class="hljs language-ts"');
    expect(html).toContain('hljs-keyword');
  });

  it.each(['：', '，', '。', '！', '？', '」', '）'])(
    'renders bold ending in CJK punctuation %s without a following space',
    (punctuation) => {
      expect(renderMarkdown(`**驗證${punctuation}**新增 4 個測試`)).toContain(
        `<strong>驗證${punctuation}</strong>新增 4 個測試`,
      );
    },
  );

  it('preserves inline formatting inside CJK bold labels', () => {
    expect(renderMarkdown('**驗證 `check`：**新增')).toContain(
      '<strong>驗證 <code>check</code>：</strong>新增',
    );
    expect(renderMarkdown('- **驗證：**新增')).toContain('<strong>驗證：</strong>新增');
  });

  it('leaves escaped delimiters, code, and ordinary emphasis rules unchanged', () => {
    expect(renderMarkdown('`**驗證：**新增`')).toContain('<code>**驗證：**新增</code>');
    expect(renderMarkdown('```text\n**驗證：**新增\n```')).toContain('**驗證：**新增</code>');
    expect(renderMarkdown('\\*\\*驗證：\\*\\*新增')).not.toContain('<strong>');
    expect(renderMarkdown('**Label:**next')).not.toContain('<strong>');
    expect(renderMarkdown('**粗體**與 *斜體*')).toContain('<strong>粗體</strong>與 <em>斜體</em>');
    expect(renderMarkdown('**驗證：')).not.toContain('<strong>');
  });

  it('renders inline and display math but leaves prices alone', () => {
    const html = renderMarkdown('Area $\\pi r^2$ costs $5 and $10.\n\n$$\n\\int_0^1 x\\,dx\n$$');
    expect(html).toContain('class="katex"');
    expect(html).toContain('class="math-block"');
    expect(html).toContain('costs $5 and $10.');
  });

  it('leaves math inside code spans untouched', () => {
    expect(renderMarkdown('`$x$`')).toContain('<code>$x$</code>');
  });

  it('turns mermaid fences into lazy placeholders', () => {
    const html = renderMarkdown('```mermaid\ngraph TD; A-->B\n```');
    expect(html).toContain('class="mermaid-block"');
    expect(html).toContain('<code>graph TD; A--&gt;B</code>');
  });

  it('sanitizes raw HTML from model output', () => {
    const html = renderMarkdown(
      '<img src=x onerror="alert(1)"><script>alert(2)</script>[x](javascript:alert(3))',
    );
    expect(html).not.toContain('onerror');
    expect(html).not.toContain('<script');
    expect(html).not.toContain('javascript:');
  });

  it('closes an open fence while streaming', () => {
    const html = renderMarkdown('text\n\n```py\nprint(1)', { streaming: true });
    expect(html).toContain('class="code-block"');
  });
});

describe('stableBlockEnd', () => {
  it.each([
    ['# Title\n\npara one\n\n- a\n- b\n\nlast', 28],
    ['```ts\nx\n\ny\n```\n\nafter', 16],
    ['| a | b |\n|---|---|\n| 1 | 2 |\n\ntext', 31],
    ['$$\nx\n\ny\n$$\n\nz', 12],
    ['> q\n\n> r\n\nz', 10],
  ])('splits %j where both halves render like the whole', (source, end) => {
    expect(stableBlockEnd(source)).toBe(end);
    expect(renderMarkdown(source.slice(0, end)) + renderMarkdown(source.slice(end))).toBe(
      renderMarkdown(source),
    );
  });

  it.each([
    ['one block', 'just a paragraph'],
    // A loose list is one block: splitting it would restart the numbering.
    ['a loose list', '1. a\n\n2. b\n\n3. c'],
    ['an open fence', '```ts\nopen\n\nstill'],
    ['CRLF text', 'a\r\n\r\nb'],
  ])('keeps %s whole', (_, source) => {
    expect(stableBlockEnd(source)).toBe(0);
  });

  it('continues from an earlier boundary', () => {
    const source = 'one\n\ntwo\n\nthree';
    expect(stableBlockEnd(source, 5)).toBe(10);
  });
});

describe('forms in rendered content', () => {
  beforeAll(() => preloadRenderers());

  const parse = (html: string) => {
    const template = document.createElement('template');
    template.innerHTML = html;
    return template.content;
  };
  const sameOrigin = [
    '/api/memory/proposals/p1/approve',
    'api/sessions/s1/read',
    './api/x',
    '../api/x',
    '?x=1',
    '#fragment',
    '  /api/push/test',
    '\t/api/push/test',
    '//' + window.location.host + '/api/push/test',
    window.location.origin + '/api/push/test',
    window.location.origin.toUpperCase() + '/api/push/test',
    '/api/a%2Fb',
  ];

  it('keeps forms and the usual form controls working', () => {
    const html = renderMarkdown(
      [
        '<form action="https://other.example/submit" method="post" enctype="multipart/form-data">',
        '<label>Name <input type="text" name="name" value="x" required></label>',
        '<input type="checkbox" name="c" checked><input type="radio" name="r" value="1">',
        '<select name="s"><option value="1">One</option></select>',
        '<textarea name="t">hi</textarea>',
        '<button type="submit" formaction="https://other.example/other">Send</button>',
        '</form>',
      ].join(''),
    );
    const form = parse(html).querySelector('form')!;
    expect(form.getAttribute('action')).toBe('https://other.example/submit');
    expect(form.getAttribute('method')).toBe('post');
    expect(form.getAttribute('enctype')).toBe('multipart/form-data');
    for (const selector of [
      'input[type=text][required]',
      'input[type=checkbox][checked]',
      'input[type=radio]',
      'select option',
      'textarea',
      'button[type=submit]',
    ])
      expect(form.querySelector(selector), selector).not.toBeNull();
    expect(form.querySelector('button')!.getAttribute('formaction')).toBe(
      'https://other.example/other',
    );
  });

  it.each(['//other.example/submit', 'http://other.example:8080/x', 'https://evil.test/a'])(
    'keeps a form that targets another origin (%s)',
    (target) => {
      const form = parse(
        renderMarkdown(`<form action="${target}"><input name="a"></form>`),
      ).querySelector('form')!;
      expect(form.getAttribute('action')).toBe(target);
    },
  );

  it.each(sameOrigin)('drops an action that resolves to the app origin (%j)', (target) => {
    const html = renderMarkdown(`<form action="${target}" method="post"><input name="a"></form>`);
    const form = parse(html).querySelector('form')!;
    expect(form).not.toBeNull();
    expect(form.hasAttribute('action')).toBe(false);
    expect(form.getAttribute('method')).toBe('post');
    expect(form.querySelector('input')).not.toBeNull();
  });

  it.each(sameOrigin)('drops a formaction that resolves to the app origin (%j)', (target) => {
    const html = renderMarkdown(
      `<form action="https://other.example/x"><button formaction="${target}">Go</button>` +
        `<input type="submit" formaction="${target}"></form>`,
    );
    const root = parse(html);
    expect(root.querySelector('button')!.hasAttribute('formaction')).toBe(false);
    expect(root.querySelector('input[type=submit]')!.hasAttribute('formaction')).toBe(false);
    expect(root.querySelector('form')!.getAttribute('action')).toBe('https://other.example/x');
  });

  it('drops the target whatever the attribute name case or entity encoding', () => {
    const html = renderMarkdown(
      '<form ACTION="&#47;api&#47;x"><button FORMACTION="/api/y">Go</button></form>',
    );
    expect(html).not.toMatch(/action/i);
  });

  it('does not let a base element move where relative targets lead', () => {
    const html = renderMarkdown(
      '<base href="https://other.example/"><form action="/api/x"><input name="a"></form>',
    );
    expect(html).not.toContain('<base');
    expect(html).not.toContain('action=');
  });

  it('drops forms nested in other content as well', () => {
    const html = renderMarkdown(
      '> quote\n>\n> <form action="/api/x"><button>Go</button></form>\n\n- item <form action="/api/y"><button>Go</button></form>',
    );
    expect(html).toContain('<button>Go</button>');
    expect(html).not.toContain('action=');
  });

  it('refuses scripting targets', () => {
    const html = renderMarkdown('<form action="javascript:alert(1)"><button>Go</button></form>');
    expect(html).not.toContain('javascript:');
  });

  it('drops style elements, wherever they are', () => {
    for (const source of [
      '<style>body{display:none}</style>text',
      'a <style>form{position:fixed;inset:0}</style> b',
      '<div><style media="all">* {color:red}</style></div>',
      '<form><style>button{opacity:0}</style><button>Go</button></form>',
      '<STYLE>x{}</STYLE>',
      '<svg><style>a{}</style></svg>',
    ]) {
      const html = renderMarkdown(source);
      expect(html.toLowerCase(), source).not.toContain('<style');
      expect(html, source).not.toContain('position:fixed');
    }
  });

  it('keeps inline style attributes out of the question as before', () => {
    // Only the element is in scope here: the attribute behaviour is DOMPurify's.
    const html = renderMarkdown('<p style="color:red">x</p>');
    expect(html).toContain('<p');
  });
});

describe('highlighted code', () => {
  beforeAll(() => preloadRenderers());

  it('only carries spans and classes', () => {
    const html = highlightCode('const x = "<img src=x onerror=alert(1)>";', 'typescript');
    expect(html).toContain('hljs-keyword');
    expect(html).not.toContain('<img');
    expect(highlightCode('<form action="/api/x"></form>', 'html')).not.toContain('<form');
    expect(highlightCode('<b>plain</b> & text')).toBe('&lt;b&gt;plain&lt;/b&gt; &amp; text');
  });
});

describe('HTML sinks', () => {
  const sources = import.meta.glob(['./**/*.svelte', './**/*.ts', '../*.svelte', '../*.ts'], {
    query: '?raw',
    import: 'default',
    eager: true,
  }) as Record<string, string>;
  const code = Object.entries(sources).filter(([path]) => !/\.test\.ts$/.test(path));

  it('lists every {@html} expression, each a sanitised renderer result', () => {
    const found = new Map<string, string[]>();
    for (const [path, text] of code)
      for (const [, expression] of text.matchAll(/\{@html\s+([^}]+)\}/g))
        found.set(path, [...(found.get(path) ?? []), expression!.trim()]);
    expect(Object.fromEntries(found)).toEqual({
      './components/Markdown.svelte': ['chunk', 'html'],
      './components/ToolCard.svelte': [
        'scriptHtml',
        'commandHtml',
        'contentHtml',
        'inputHtml',
        'outputHtml',
      ],
      './components/panel/FilesTab.svelte': ['highlighted'],
    });
    // Each takes its value from markdown.ts, which sanitises it.
    const markdownImport = /from '(\.\.\/)+markdown'/;
    expect(sources['./components/Markdown.svelte']).toMatch(/renderMarkdownChecked/);
    for (const path of found.keys()) expect(sources[path], path).toMatch(markdownImport);
    expect(sources['./components/ToolCard.svelte']).toMatch(/highlightCode/);
    expect(sources['./components/panel/FilesTab.svelte']).toMatch(/highlightCode/);
  });

  it('writes HTML nowhere else', () => {
    const writers = code
      .filter(([, text]) =>
        /\.(innerHTML|outerHTML)\s*=|insertAdjacentHTML|document\.write|createContextualFragment|DOMParser/.test(
          text,
        ),
      )
      .map(([path]) => path);
    // The one other writer is the Mermaid figure, which is sanitised on the line before.
    expect(writers).toEqual(['./markdown.ts']);
    const mermaid = sources['./markdown.ts']!;
    expect(mermaid).toMatch(/figure\.innerHTML = purifier\(\)\.sanitize\(svg/);
  });
});
