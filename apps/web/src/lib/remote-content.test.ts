// @vitest-environment jsdom
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest';
import { diagramImage, enhanceMarkdown, preloadRenderers, renderMarkdown } from './markdown';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { cleanInlineStyle, cleanStyleSheet, openRemote } from './remote-content';

const parse = (html: string) => {
  const box = document.createElement('div');
  box.innerHTML = html;
  return box;
};

/** Attributes through which a browser would fetch something by itself. */
const FETCHING_ATTRIBUTE = /^(src|srcset|poster|background|lowsrc|dynsrc|ping)$/i;
const fetching = (html: string) =>
  [...parse(html).querySelectorAll('*')].flatMap((element) =>
    [...element.attributes]
      .filter(({ name, value }) => FETCHING_ATTRIBUTE.test(name) || /url\(|@import/i.test(value))
      .map(({ name, value }) => `${element.localName}[${name}=${value}]`),
  );

beforeAll(() => preloadRenderers());

describe('remote images and media wait for the user', () => {
  it('turns a Markdown image into a placeholder with alt text, source and a button', () => {
    const html = renderMarkdown('![A cat](https://img.example/cat.png)');
    const box = parse(html);
    expect(box.querySelector('img')).toBeNull();
    expect(fetching(html)).toEqual([]);
    const placeholder = box.querySelector('.remote-media')!;
    expect(placeholder.textContent).toContain('A cat');
    expect(placeholder.querySelector('.remote-media-url')!.textContent).toBe(
      'https://img.example/cat.png',
    );
    const button = placeholder.querySelector('button')!;
    expect(button.getAttribute('data-remote-open')).toBe('https://img.example/cat.png');
    expect(button.type).toBe('button');
  });

  it('shows the source as text, never as markup', () => {
    const html = renderMarkdown(
      '<img src="https://e.example/a.png?x=%22%3E%3Cscript%3Ealert(1)%3C/script%3E" alt="&lt;b&gt;bold&lt;/b&gt;">',
    );
    const box = parse(html);
    expect(box.querySelector('script')).toBeNull();
    expect(box.querySelector('b')).toBeNull();
    expect(box.querySelector('.remote-media-alt')!.textContent).toBe('<b>bold</b>');
  });

  it('gates relative and same-origin addresses too: a URL shape is not trust', () => {
    for (const source of ['/api/files/secret.png', './a.png', '//cdn.example/a.png', 'a.png']) {
      const html = renderMarkdown(`<img src="${source}" alt="x">`);
      expect(parse(html).querySelector('img'), source).toBeNull();
      expect(fetching(html), source).toEqual([]);
      expect(parse(html).querySelector('.remote-media'), source).not.toBeNull();
    }
  });

  it('keeps data: images', () => {
    const png =
      'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
    const html = renderMarkdown(`![dot](${png})`);
    expect(parse(html).querySelector('img')!.getAttribute('src')).toBe(png);
    expect(parse(html).querySelector('.remote-media')).toBeNull();
  });

  it.each([
    ['srcset', '<img srcset="https://e.example/a.png 1x, https://e.example/b.png 2x" alt="s">'],
    [
      'picture source',
      '<picture><source srcset="https://e.example/a.webp" type="image/webp"><img src="https://e.example/a.png" alt="p"></picture>',
    ],
    [
      'video src and poster',
      '<video src="https://e.example/v.mp4" poster="https://e.example/p.png" controls></video>',
    ],
    [
      'video source',
      '<video controls><source src="https://e.example/v.mp4"><track src="https://e.example/t.vtt"></video>',
    ],
    ['audio', '<audio src="https://e.example/a.mp3" controls></audio>'],
    [
      'stray source and track',
      '<source src="https://e.example/s.mp4"><track src="https://e.example/t.vtt">',
    ],
    ['input image', '<form><input type="image" src="https://e.example/b.png" alt="go"></form>'],
    [
      'svg image',
      '<svg width="10" height="10"><image href="https://e.example/a.png" width="10" height="10"/></svg>',
    ],
    [
      'svg image xlink',
      '<svg xmlns:xlink="http://www.w3.org/1999/xlink"><image xlink:href="https://e.example/a.png"/></svg>',
    ],
    ['svg use', '<svg><use href="https://e.example/a.svg#x"/></svg>'],
    ['svg feImage', '<svg><filter id="f"><feImage href="https://e.example/a.png"/></filter></svg>'],
    [
      'svg fill url',
      '<svg><rect width="5" height="5" fill="url(https://e.example/a.svg#p)"/></svg>',
    ],
    ['style background', '<div style="background:url(https://e.example/a.png)">x</div>'],
    ['style list-style', '<ul style="list-style:url(https://e.example/a.png)"><li>x</li></ul>'],
    ['style border-image', '<div style="border-image:url(//e.example/a.png) 30 round">x</div>'],
    [
      'style mask',
      '<div style="-webkit-mask:url(/api/x.svg);mask-image:url(\'https://e.example/m.svg\')">x</div>',
    ],
    ['style cursor', '<div style="cursor:url(https://e.example/c.cur),auto">x</div>'],
    ['style content', '<div style="content:url(https://e.example/a.png)">x</div>'],
    [
      'style image-set',
      '<div style="background-image:image-set(\'https://e.example/a.png\' 1x)">x</div>',
    ],
    [
      'style escaped function name',
      '<div style="background:\\75rl(https://e.example/a.png)">x</div>',
    ],
    ['style uppercase', '<div style="BACKGROUND:URL( https://e.example/a.png )">x</div>'],
    [
      'background attribute',
      '<table background="https://e.example/a.png"><tr><td background="/a.png">x</td></tr></table>',
    ],
    ['link ping', '<a href="https://e.example/" ping="https://e.example/ping">x</a>'],
    ['meta refresh', '<meta http-equiv="refresh" content="0;url=https://e.example/">x'],
    [
      'link preload',
      '<link rel="preload" href="https://e.example/a.png" as="image"><link rel="icon" href="https://e.example/i.png">x',
    ],
    [
      'lowsrc and dynsrc',
      '<img lowsrc="https://e.example/l.png" dynsrc="https://e.example/d.avi" alt="x">',
    ],
  ])('leaves nothing that fetches by itself: %s', (_name, source) => {
    const html = renderMarkdown(source);
    expect(fetching(html)).toEqual([]);
  });

  it('shows placeholders for media and keeps the rest of the content', () => {
    const video = parse(renderMarkdown('<video src="https://e.example/v.mp4" controls></video>'));
    expect(video.querySelector('video')).toBeNull();
    expect(
      video.querySelector('[data-remote-media="video"] button')!.getAttribute('data-remote-open'),
    ).toBe('https://e.example/v.mp4');
    const audio = parse(
      renderMarkdown('<audio controls><source src="https://e.example/a.mp3"></audio>'),
    );
    expect(audio.querySelector('audio')).toBeNull();
    expect(audio.querySelector('[data-remote-media="audio"]')).not.toBeNull();
    const picture = parse(
      renderMarkdown(
        '<picture><source srcset="https://e.example/a.webp"><img src="https://e.example/a.png" alt="p"></picture>',
      ),
    );
    expect(picture.querySelector('source')).toBeNull();
    expect(picture.querySelector('.remote-media-url')!.textContent).toBe('https://e.example/a.png');
    const svg = parse(renderMarkdown('<svg><image href="https://e.example/a.svg"/></svg>'));
    expect(svg.querySelector('image')).toBeNull();
    expect(svg.querySelector('[data-remote-media="image"]')).not.toBeNull();
  });

  it('does not let content plant the markers the gate uses', () => {
    const html = renderMarkdown(
      '<img data-remote-src="https://e.example/a.png" alt="x"><p data-remote-src="https://e.example/b.png">kept</p>',
    );
    expect(html).not.toContain('data-remote-src');
    expect(parse(html).querySelector('.remote-media')).toBeNull();
  });

  it('puts only http(s) sources behind an open button', () => {
    const html = renderMarkdown('<img src="ftp://e.example/a.png" alt="x">');
    expect(parse(html).querySelector('.remote-media')).not.toBeNull();
    expect(parse(html).querySelector('button')).toBeNull();
  });

  it('keeps ordinary styling, forms and links', () => {
    const html = renderMarkdown(
      '<div style="color:red;margin-top:4px">styled</div>\n\n<form action="https://other.example/submit"><input name="q"><button>go</button></form>\n\n[a link](https://e.example/page)',
    );
    expect(html).toContain('style="color:red;margin-top:4px"');
    expect(html).toContain('<form action="https://other.example/submit">');
    expect(html).toContain('href="https://e.example/page"');
  });
});

describe('style cleaning', () => {
  it('drops only the declarations that name a source', () => {
    expect(cleanInlineStyle('color:red; background:url(https://e.example/a.png); margin:1px')).toBe(
      'color:red; margin:1px',
    );
  });
  it('keeps data: images, whose semicolons do not end the declaration', () => {
    const value = 'background:url(data:image/png;base64,AAAA) no-repeat; color:blue';
    expect(cleanInlineStyle(value)).toBe(value);
  });
  it('drops obfuscated and quoted forms', () => {
    for (const value of [
      'background:u\\72l(https://e.example/a.png)',
      'background:\\75 rl("https://e.example/a.png")',
      "background:URL( 'https://e.example/a.png' )",
      'background:url(https://e.example/a.png',
      'background:image-set("a.png" 1x)',
      'background:-webkit-image-set(url(a.png) 1x)',
      'background:url(a.png)',
    ])
      expect(cleanInlineStyle(`color:red;${value}`), value).toBe('color:red');
  });
  it('removes @import and remote url() from a style sheet and keeps #id references', () => {
    const sheet =
      '@import url(https://e.example/a.css);\n.a{fill:url(#grad);background:url(https://e.example/b.png)}';
    const cleaned = cleanStyleSheet(sheet)!;
    expect(cleaned).not.toContain('@import');
    expect(cleaned).not.toContain('e.example');
    expect(cleaned).toContain('url(#grad)');
  });
  it('drops a style sheet that hides url() behind CSS escapes', () => {
    expect(cleanStyleSheet('.a{background:\\75rl(https://e.example/a.png)}')).toBeUndefined();
  });
});

describe('diagrams', () => {
  const svg =
    '<svg xmlns="http://www.w3.org/2000/svg" id="d" viewBox="0 0 120 40" width="100%"><style>#d{fill:red}#d .x{background:url(https://e.example/a.png)}@import url(https://e.example/a.css);</style><g><text>Alpha</text><text>Beta</text></g><foreignObject width="50" height="20"><div xmlns="http://www.w3.org/1999/xhtml"><img src="https://e.example/label.png"><br>label</div></foreignObject></svg>';
  it('becomes an image source with its own size, a text label and no remote references', () => {
    const image = diagramImage(svg)!;
    expect(image.width).toBe(120);
    expect(image.height).toBe(40);
    expect(image.label).toBe('Alpha Beta label');
    expect(image.src.startsWith('data:image/svg+xml;charset=utf-8,')).toBe(true);
    const markup = decodeURIComponent(image.src.slice(image.src.indexOf(',') + 1));
    expect(markup).not.toContain('e.example');
    expect(markup).toContain('width="120"');
    expect(markup).toContain('<br');
    const parsed = new DOMParser().parseFromString(markup, 'image/svg+xml');
    expect(parsed.querySelector('parsererror')).toBeNull();
  });
  it('keeps diagram-local url(#id) references', () => {
    const image = diagramImage(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><defs><linearGradient id="g"/></defs><rect fill="url(#g)" width="5" height="5"/></svg>',
    )!;
    expect(decodeURIComponent(image.src)).toContain('url(#g)');
  });
});

describe('opening a remote source', () => {
  let clicked: HTMLAnchorElement | undefined;
  afterEach(() => vi.restoreAllMocks());
  const stubAnchorClick = () =>
    vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(function (
      this: HTMLAnchorElement,
    ) {
      clicked = this;
    });

  it('opens a new tab without opener or referrer', () => {
    clicked = undefined;
    stubAnchorClick();
    expect(openRemote('https://img.example/cat.png')).toBe(true);
    expect(clicked!.href).toBe('https://img.example/cat.png');
    expect(clicked!.target).toBe('_blank');
    expect(clicked!.rel).toBe('noopener noreferrer');
    expect(clicked!.referrerPolicy).toBe('no-referrer');
  });

  it('opens only http(s) addresses', () => {
    clicked = undefined;
    stubAnchorClick();
    for (const value of ['javascript:alert(1)', 'data:text/html,x', 'ftp://e.example/a', '', null])
      expect(openRemote(value), String(value)).toBe(false);
    expect(clicked).toBeUndefined();
  });

  it("ignores a click that is not the user's, and one on the placeholder text", () => {
    clicked = undefined;
    stubAnchorClick();
    const node = document.createElement('div');
    node.innerHTML = renderMarkdown('[![cat](https://img.example/cat.png)](https://site.example/)');
    document.body.append(node);
    const action = enhanceMarkdown(node, { html: node.innerHTML, ready: false });
    // A scripted click (not trusted) on the button, and a real one on the text next to it.
    const scripted = new MouseEvent('click', { bubbles: true, cancelable: true });
    node.querySelector('button')!.dispatchEvent(scripted);
    expect(scripted.defaultPrevented).toBe(true);
    node
      .querySelector('.remote-media-url')!
      .dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
    expect(clicked).toBeUndefined();
    action.destroy();
    node.remove();
  });
});

describe('rendered content stays in its box', () => {
  // The behaviour itself is checked in a real browser (tool/browser/ui-integrity.mjs);
  // this only keeps the declarations from being dropped by accident.
  it('declares paint containment and a local stacking context on the content box', () => {
    const markdownCss = readFileSync(resolve(process.cwd(), 'src/markdown.css'), 'utf8');
    const rule = /^\.markdown \{([^}]*)\}/m.exec(markdownCss)?.[1] ?? '';
    expect(rule).toMatch(/contain:\s*paint/);
    expect(rule).toMatch(/isolation:\s*isolate/);
    expect(rule).toMatch(/position:\s*relative/);
  });
});
