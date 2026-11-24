import 'render_l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'render_theme.dart';
import 'markdown_syntax.dart';

/// Append a widget to the parsed last block, never to the Markdown source.
/// This keeps unfinished emphasis, links and code fence contents unchanged.
Map<String, MarkdownPaddingBuilder> cursorPlacement(String source) {
  final document = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    blockSyntaxes: const [
      NativeHeadingSyntax(),
      NativeMathBlockSyntax(),
      NativeFenceSyntax(),
      NativeTableSyntax(),
    ],
    inlineSyntaxes: [NativeMathInlineSyntax()],
    encodeHtml: false,
  );
  final nodes = document.parseLines(source.split('\n'));
  if (nodes.isEmpty || nodes.last is! md.Element) return {};
  var target = nodes.last as md.Element;
  if (target.tag == 'ul' || target.tag == 'ol') {
    final items = target.children?.whereType<md.Element>().toList() ?? [];
    if (items.isEmpty) return {};
    target = items.last;
  }
  // Web suppresses the tail cursor on code and tables. Block math and raw HTML
  // placement require separate native builders and remain explicitly pending.
  if (![
    'p',
    'li',
    'blockquote',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
  ].contains(target.tag)) {
    return {};
  }
  final matches = <md.Element>[];
  void visit(md.Node node) {
    if (node is md.Element) {
      if (node.tag == target.tag) matches.add(node);
      for (final child in node.children ?? <md.Node>[]) {
        visit(child);
      }
    }
  }

  for (final node in nodes) {
    visit(node);
  }
  return {
    target.tag: _CursorInsertion(matches.indexOf(target), matches.length),
  };
}

class _CursorInsertion extends MarkdownPaddingBuilder {
  _CursorInsertion(this.target, this.count);
  final int target, count;
  int index = 0;
  @override
  void visitElementBefore(md.Element element) {
    if (index++ % count == target) {
      element.children?.add(md.Element.empty('pirc-stream-cursor'));
    }
  }

  @override
  EdgeInsets getPadding() => EdgeInsets.zero;
}

class NativeCursorBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => Text.rich(
    TextSpan(
      children: [
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Semantics(
            label: tr("Streaming"),
            child: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Container(
                key: const ValueKey('markdown-stream-cursor'),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Theme.of(
                    context,
                  ).extension<RenderColors>()!['accent.default'],
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
