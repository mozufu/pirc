import 'dart:async';
import 'dart:convert';
import 'package:html/parser.dart' as html;
import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;
import 'markdown_syntax.dart';
import 'html_syntax.dart';

/// Observe top-level parser boundaries without replacing any GFM syntax.
/// Nested lists/quotes have their own parsers; probes inside a paragraph keep
/// linesToConsume anchored at its beginning, so they cannot split that block.
class _BoundaryProbe extends md.BlockSyntax {
  md.BlockParser? root;
  final starts = <md.Line>{};
  @override
  RegExp get pattern => RegExp(r'(?!)');
  @override
  bool canParse(md.BlockParser parser) {
    if (identical(parser, root) &&
        identical(parser.linesToConsume.first, parser.current) &&
        !parser.current.isBlankLine &&
        !starts.contains(parser.current)) {
      starts.add(parser.current);
    }
    return false;
  }

  @override
  md.Node? parse(md.BlockParser parser) => null;
}

/// Native analogue of markdown.ts stableBlockEnd. Only the tail is lexed.
/// CRLF stays whole, matching the web offset guard. Native GFM
/// grammar differences are compared with pinned-web fixtures, not assumed away.
int nativeStableBlockEnd(String source, [int from = 0]) {
  RangeError.checkValueInInterval(from, 0, source.length, 'from');
  final rest = source.substring(from);
  if (rest.contains('\r')) return from;
  final lines = rest.split('\n').map(md.Line.new).toList();
  final offsets = <md.Line, int>{};
  var offset = from;
  for (final line in lines) {
    offsets[line] = offset;
    offset += line.content.length + 1;
  }
  final probe = _BoundaryProbe();
  final document = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    blockSyntaxes: [
      probe,
      const NativeHeadingSyntax(),
      const NativeMathBlockSyntax(),
      const NativeFenceSyntax(),
      const NativeTableSyntax(),
    ],
    inlineSyntaxes: [NativeMathInlineSyntax()],
    encodeHtml: false,
  );
  final parser = md.BlockParser(lines, document);
  probe.root = parser;
  parser.parseLines();
  for (final start in probe.starts.skip(1).toList().reversed) {
    final end = offsets[start]!;
    final prefix = source.substring(from, end);
    if (!prefix.contains('<') || _htmlScopeClosed(prefix)) return end;
  }
  return from;
}

/// Only actual raw HTML participates: escaped tags, code and math remain text.
/// Inspect the HTML parser's open-element/formatting state instead of counting
/// tags, so void tags, quoted `>`, implicit closes and malformed nesting follow
/// the same tree construction as the native renderer. Open containers stay in
/// the mutable tail; a fully closed container can be cached normally.
bool _htmlScopeClosed(String source) {
  final nodes = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    blockSyntaxes: const [
      NativeHtmlBlockSyntax(),
      NativeHeadingSyntax(),
      NativeMathBlockSyntax(),
      NativeFenceSyntax(),
      NativeTableSyntax(),
    ],
    inlineSyntaxes: [NativeHtmlInlineSyntax(), NativeMathInlineSyntax()],
    encodeHtml: false,
  ).parseLines(source.split('\n'));
  if (!containsNativeHtml(nodes)) return true;
  String serialize(md.Node node) {
    if (node is NativeHtmlRaw) return node.html;
    if (node is md.Text) return const HtmlEscape().convert(node.text);
    if (node is! md.Element) return '';
    if (['br', 'hr', 'img', 'input'].contains(node.tag)) return '<${node.tag}>';
    return '<${node.tag}>${(node.children ?? []).map(serialize).join()}</${node.tag}>';
  }

  final parser = html.HtmlParser(nodes.map(serialize).join('\n'));
  parser.parseFragment();
  return parser.tree.openElements.length <= 1 &&
      !parser.tree.activeFormattingElements.any((element) => element != null);
}

/// Keep completed chunks mounted while coalescing streamed deltas to 80ms.
/// Completion renders the full original document synchronously, restoring all
/// document-level reference resolution and avoiding a delayed final answer.
class MarkdownStream extends StatefulWidget {
  const MarkdownStream({
    super.key,
    required this.source,
    required this.streaming,
    required this.builder,
    required this.spacing,
    required this.configuration,
    this.boundarySpacing,
  });
  final Object configuration;
  final String source;
  final bool streaming;
  final Widget Function(
    String source,
    bool cursor,
    bool documentStart,
    bool documentEnd,
  )
  builder;
  final double spacing;
  final double Function(String previous, String next)? boundarySpacing;
  @override
  State<MarkdownStream> createState() => _MarkdownStreamState();
}

class _MarkdownStreamState extends State<MarkdownStream> {
  final chunks = <String>[];
  final cached = <Widget>[];
  final cachedGaps = <double>[];
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    cached.clear();
    cachedGaps.clear();
  }

  String stable = '', tail = '';
  Timer? cooldown;
  bool pending = false;
  int revision = 0;
  @override
  void initState() {
    super.initState();
    render();
  }

  @override
  void didUpdateWidget(covariant MarkdownStream old) {
    super.didUpdateWidget(old);
    if (old.configuration != widget.configuration) {
      cached.clear();
      cachedGaps.clear();
    }
    if (old.source == widget.source && old.streaming == widget.streaming) {
      return;
    }
    if (!widget.streaming || cooldown == null) {
      cooldown?.cancel();
      cooldown = null;
      render();
    } else {
      pending = true;
    }
  }

  void render() {
    pending = false;
    if (!widget.streaming) {
      chunks.clear();
      cached.clear();
      cachedGaps.clear();
      stable = '';
      tail = widget.source;
      ++revision;
      return;
    }
    if (!widget.source.startsWith(stable)) {
      chunks.clear();
      cached.clear();
      cachedGaps.clear();
      stable = '';
      ++revision;
    }
    final end = nativeStableBlockEnd(widget.source, stable.length);
    if (end > stable.length) {
      chunks.add(widget.source.substring(stable.length, end));
      stable = widget.source.substring(0, end);
    }
    tail = widget.source.substring(stable.length);
    cooldown = Timer(const Duration(milliseconds: 80), () {
      cooldown = null;
      if (pending && mounted) setState(render);
    });
  }

  @override
  void dispose() {
    cooldown?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Theme.of(context);
    MediaQuery.of(context);
    while (cached.length < chunks.length) {
      cached.add(
        widget.builder(chunks[cached.length], false, cached.isEmpty, false),
      );
    }
    if (!widget.streaming) {
      return widget.builder(tail, widget.streaming, true, true);
    }
    // Stable boundaries do not change as deltas arrive. Recompute only the
    // live tail boundary, retaining the stream's completed-chunk cache.
    while (cachedGaps.length + 1 < chunks.length) {
      final i = cachedGaps.length;
      cachedGaps.add(
        widget.boundarySpacing?.call(chunks[i], chunks[i + 1]) ??
            widget.spacing,
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < chunks.length; i++) ...[
          KeyedSubtree(key: ValueKey('stable-$revision-$i'), child: cached[i]),
          SizedBox(
            height: i + 1 < chunks.length
                ? cachedGaps[i]
                : widget.boundarySpacing?.call(chunks[i], tail) ??
                      widget.spacing,
          ),
        ],
        KeyedSubtree(
          key: ValueKey('tail-$revision'),
          child: widget.builder(tail, widget.streaming, chunks.isEmpty, true),
        ),
      ],
    );
  }
}
