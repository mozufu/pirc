import 'package:markdown/markdown.dart' as md;

/// Same delimiters and currency exclusions as web markdown.ts. This runs as an
/// inline parser extension, so escaped text and code spans stay literal.
class NativeMathInlineSyntax extends md.InlineSyntax {
  NativeMathInlineSyntax()
    : super(
        r'\$\$([^$]+?)\$\$|\\\(([\s\S]+?)\\\)|\$(?!\s)((?:\\.|[^\\$\n])+?)(?<!\s)\$(?!\d)',
      );
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final element = md.Element.text(
      'pirc-math',
      (match[1] ?? match[2] ?? match[3]!).trim(),
    );
    element.attributes['display'] = match[1] != null ? 'true' : 'false';
    parser.addNode(element);
    return true;
  }
}

class NativeMathBlockSyntax extends md.BlockSyntax {
  const NativeMathBlockSyntax();
  @override
  RegExp get pattern => RegExp(r'^(?:\$\$|\\\[)');
  (String, int)? _match(md.BlockParser parser) {
    if (!pattern.hasMatch(parser.current.content)) return null;
    final source = StringBuffer();
    final closing = parser.current.content.startsWith(r'$$') ? r'$$' : r'\]';
    for (var index = 0; parser.peek(index) != null; index++) {
      if (index > 0) source.write('\n');
      source.write(parser.peek(index)!.content);
      final value = source.toString();
      final end = value.indexOf(closing, 2);
      if (end >= 0) {
        if (value.substring(end + 2).trim().isNotEmpty) return null;
        final body = value.substring(2, end);
        return body.isEmpty ? null : (body.trim(), index + 1);
      }
    }
    return null;
  }

  @override
  bool canParse(md.BlockParser parser) => _match(parser) != null;
  @override
  md.Node parse(md.BlockParser parser) {
    final (body, count) = _match(parser)!;
    for (var i = 0; i < count; i++) {
      parser.advance();
    }
    return md.Element.text('pirc-math-block', body);
  }
}

/// Preserve markdown's mature fence handling (including unfinished streaming
/// fences and nesting). The synthetic tag avoids Material's stock code block.
class NativeFenceSyntax extends md.FencedCodeBlockSyntax {
  const NativeFenceSyntax();
  @override
  md.Node parse(md.BlockParser parser) {
    final pre = super.parse(parser) as md.Element;
    final code = pre.children!.single as md.Element;
    final language = (code.attributes['class'] ?? '')
        .replaceFirst('language-', '')
        .toLowerCase();
    final text = code.textContent.replaceFirst(RegExp(r'\n$'), '');
    final tag = ['math', 'latex', 'tex'].contains(language)
        ? 'pirc-math-block'
        : 'pirc-code';
    return md.Element.text(tag, text)..attributes['language'] = language;
  }
}

class NativeTableCell {
  const NativeTableCell(this.source, this.alignment);
  final String source;
  final String? alignment;
}

/// Keep the original inline source (including formatting, links and escaped
/// pipes) in each cell. Reusing TableSyntax preserves the GFM column rules.
class NativeTableElement extends md.Element {
  NativeTableElement(this.rows, this.references)
    : super('pirc-table', const []);
  final Map<String, md.LinkReference> references;
  final List<List<NativeTableCell>> rows;
}

class NativeTableSyntax extends md.TableSyntax {
  const NativeTableSyntax();
  @override
  md.Node? parse(md.BlockParser parser) {
    final table = super.parse(parser);
    if (table == null) return null;
    return NativeTableElement([
      for (final section in (table as md.Element).children!.cast<md.Element>())
        for (final row in section.children!.cast<md.Element>())
          [
            for (final cell in row.children!.cast<md.Element>())
              NativeTableCell(cell.textContent, cell.attributes['align']),
          ],
    ], parser.document.linkReferences);
  }
}

/// A GFM cell contains inline Markdown; heading and fence characters inside a
/// cell must not create nested blocks when passed to the native widget builder.
class NativeInlineBlockSyntax extends md.BlockSyntax {
  const NativeInlineBlockSyntax(this.references);
  final Map<String, md.LinkReference> references;
  @override
  RegExp get pattern => RegExp(r'^');
  @override
  md.Node parse(md.BlockParser parser) {
    parser.document.linkReferences.addAll(references);
    final lines = <String>[];
    while (!parser.isDone) {
      lines.add(parser.current.content);
      parser.advance();
    }
    return md.Element('p', [md.UnparsedContent(lines.join('\n'))]);
  }
}

/// Marked consumes empty lines as part of an ATX heading token. A single
/// remaining whitespace-only line is a space token, but does not loosen a
/// list; two such lines do. Keep Dart's list looseness state consistent with
/// those token boundaries instead of removing paragraph margins afterward.
class NativeHeadingSyntax extends md.HeaderSyntax {
  const NativeHeadingSyntax();
  @override
  md.Node parse(md.BlockParser parser) {
    final node = super.parse(parser);
    while (!parser.isDone && parser.current.content.isEmpty) {
      parser.advance();
    }
    if (!parser.isDone &&
        parser.current.isBlankLine &&
        !(parser.peek(1)?.isBlankLine ?? false)) {
      parser.advance();
    }
    return node;
  }
}
