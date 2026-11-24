import 'package:html/dom.dart' as dom;
import 'render_theme.dart';

// Selectors and cascade order from the pinned web's markdown.css. Keep class
// specificity: e.g. .hljs-variable.constant_ wins over the later .hljs-variable.
const _rules = [
  (['.hljs-comment', '.hljs-quote'], 'comment'),
  (
    [
      '.hljs-keyword',
      '.hljs-selector-tag',
      '.hljs-literal',
      '.hljs-doctag',
      '.hljs-meta .hljs-keyword',
    ],
    'keyword',
  ),
  (
    [
      '.hljs-string',
      '.hljs-regexp',
      '.hljs-addition',
      '.hljs-meta .hljs-string',
    ],
    'string',
  ),
  (
    [
      '.hljs-number',
      '.hljs-symbol',
      '.hljs-bullet',
      '.hljs-variable.constant_',
    ],
    'number',
  ),
  (['.hljs-title', '.hljs-title.function_', '.hljs-section'], 'title'),
  (['.hljs-title.class_', '.hljs-type', '.hljs-built_in'], 'type'),
  (
    [
      '.hljs-attr',
      '.hljs-attribute',
      '.hljs-property',
      '.hljs-variable',
      '.hljs-template-variable',
      '.hljs-params',
    ],
    'attr',
  ),
  (
    ['.hljs-name', '.hljs-tag', '.hljs-selector-id', '.hljs-selector-class'],
    'tag',
  ),
  (['.hljs-deletion'], 'del'),
  (['.hljs-meta'], 'meta'),
];

bool _classes(dom.Element node, String selector) =>
    selector.split('.').skip(1).every(node.classes.contains);

bool _matches(dom.Element node, String selector) {
  final parts = selector.split(' ');
  if (!_classes(node, parts.last)) return false;
  if (parts.length == 1) return true;
  for (var parent = node.parent; parent != null; parent = parent.parent) {
    if (_classes(parent, parts.first)) return true;
  }
  return false;
}

/// Applies author-provided highlight.js spans in raw HTML using Flutter text
/// styles. This does not execute code or add highlighting the web didn't emit.
Map<String, String> nativeHtmlHighlightStyles(
  dom.Element element,
  RenderColors colors,
) {
  final styles = <String, String>{};
  var specificity = 0;
  for (final (selectors, token) in _rules) {
    for (final selector in selectors) {
      final weight = '.'.allMatches(selector).length;
      if (weight < specificity || !_matches(element, selector)) continue;
      final color = colors['web.hl-$token'];
      styles['color'] =
          'rgba(${(color.r * 255).round()},${(color.g * 255).round()},${(color.b * 255).round()},${color.a})';
      specificity = weight;
    }
  }
  if (element.classes.any(
    ['hljs-comment', 'hljs-quote', 'hljs-emphasis'].contains,
  )) {
    styles['font-style'] = 'italic';
  }
  if (element.classes.contains('hljs-strong')) styles['font-weight'] = '700';
  return styles;
}
