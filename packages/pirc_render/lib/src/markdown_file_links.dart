import 'package:markdown/markdown.dart' as md;

// Kept identical to the pinned web file-links.ts grammar. Matching a path is
// separate from resolving its workspace/base/line target at activation time.
const nativeFilePathSource =
    r'(?!www\.)(?:\/|(?:\.{1,2}\/)+)?(?:[\w@+-][\w@.+-]*\/|\.[\w@+-][\w@.+-]*\/)+[\w@.+-]*\.[A-Za-z0-9]*[A-Za-z][A-Za-z0-9]*(?::\d+(?:[:-]\d+)?)?';
final _codePath = RegExp('^$nativeFilePathSource\$');
const _automatic = 'pirc-auto-file';
md.Element _link(String path, md.Node content) =>
    md.Element('a', [content])
      ..attributes.addAll({'href': path, _automatic: 'true'});

// Tildes and backslashes are token boundaries in Marked's inline lexer;
// Dart keeps them in this parser's source after handling delimiters.
class NativeBareFileSyntax extends md.InlineSyntax {
  NativeBareFileSyntax()
    : super(r'(?<![\w@.+\-/:])' + nativeFilePathSource + r'(?![\w/])');
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final path = match[0]!;
    parser.addNode(_link(path, md.Text(path)));
    return true;
  }
}

class NativeCodeFileSyntax extends md.CodeSyntax {
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    var code = match[2]!.replaceAll('\n', ' ');
    if (code.trim().isNotEmpty && code.startsWith(' ') && code.endsWith(' ')) {
      code = code.substring(1, code.length - 1);
    }
    if (!_codePath.hasMatch(code)) return super.onMatch(parser, match);
    parser.addNode(
      _link(
        code,
        md.Element.text('code', code)..attributes['pirc-href'] = code,
      ),
    );
    return true;
  }
}

// Dart Markdown resolves enclosing links after their label's inline nodes.
// Strip only our automatic links when a real Markdown link is completed, so
// `[src/a.ts](https://example.com)` and linked code keep the author's target.
class NativeExplicitLinkSyntax extends md.LinkSyntax {
  @override
  md.Node createNode(
    String destination,
    String? title, {
    required List<md.Node> Function() getChildren,
  }) {
    final link =
        super.createNode(
              destination.trim().replaceFirst(
                RegExp(r'^file:(//(localhost)?)?', caseSensitive: false),
                '',
              ),
              title,
              getChildren: () => _label(getChildren()),
            )
            as md.Element;
    void annotate(md.Node node) {
      if (node is! md.Element) return;
      if (node.tag == 'code') {
        node.attributes['pirc-href'] = link.attributes['href']!;
      }
      for (final child in node.children ?? <md.Node>[]) {
        annotate(child);
      }
    }

    annotate(link);
    return link;
  }

  List<md.Node> _label(List<md.Node> nodes) => [
    for (final node in nodes)
      if (node is md.Element && node.attributes[_automatic] == 'true')
        ..._label(node.children ?? [])
      else if (node is md.Element && node.children != null)
        md.Element(node.tag, _label(node.children!))
          ..attributes.addAll(node.attributes)
      else
        node,
  ];
}

// The pinned Marked URL rule accepts single-label hosts, unlike Dart GFM.
// Keep its trailing punctuation/parenthesis backpedal and URI escaping.
class NativeWebUrlSyntax extends md.InlineSyntax {
  NativeWebUrlSyntax()
    : super(
        r'((?:[hH][tT][tT][pP][sS]?|[fF][tT][pP]):\/\/|www\.)(?:[a-zA-Z0-9\-]+\.?)+[^\s<]*',
      );
  static final _tail = RegExp(
    r"""(?:[^?!.,:;*_'"~()&]+|\([^)]*\)|&(?![a-zA-Z0-9]+;$)|[?!.,:;*_'"~)]+(?!$))+""",
  );
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    var text = match[0]!;
    while (true) {
      final next = _tail.firstMatch(text)?[0] ?? '';
      if (next == text) break;
      text = next;
    }
    final href = Uri.encodeFull(
      text.startsWith('www.') ? 'http://$text' : text,
    ).replaceAll('%25', '%');
    parser.addNode(_link(href, md.Text(text)));
    parser.consume(text.length);
    return false;
  }
}

List<md.InlineSyntax> nativeFileLinkSyntaxes() => [
  NativeExplicitLinkSyntax(),
  NativeCodeFileSyntax(),
  NativeBareFileSyntax(),
  NativeWebUrlSyntax(),
];
