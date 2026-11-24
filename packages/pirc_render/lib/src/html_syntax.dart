import 'package:markdown/markdown.dart' as md;

/// Mark raw HTML while the Markdown lexer can still distinguish it from
/// escaped text, fenced code and angle autolinks. HTML is never found by a
/// regexp over the final plain-text AST.
class NativeHtmlBlockSyntax extends md.HtmlBlockSyntax {
  const NativeHtmlBlockSyntax();
  @override
  md.Node parse(md.BlockParser parser) =>
      NativeHtmlRaw(super.parse(parser).textContent);
}

class NativeHtmlInlineSyntax extends md.InlineHtmlSyntax {
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(NativeHtmlRaw(match[0]!));
    return true;
  }
}

class NativeHtmlRaw extends md.Element {
  NativeHtmlRaw(this.html) : super('pirc-html-raw', const []);
  final String html;
}

bool containsNativeHtml(Iterable<md.Node> nodes) => nodes.any(
  (n) =>
      n is NativeHtmlRaw ||
      n is md.Element && containsNativeHtml(n.children ?? []),
);
