import '../render_l10n.dart';
import 'block_model.dart';

/// Parses a documented subset of pinned Mermaid 11.17.2 block-beta syntax.
/// Unsupported style/class statements fail explicitly rather than being lost.
NativeMermaidBlockDiagram parseNativeMermaidBlock(String source) {
  if (source.length > 50000) {
    throw FormatException(tr("Block diagram exceeds 50000 characters."));
  }
  final lines = source
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  var headerIndex = -1;
  for (var i = 0; i < lines.length; i++) {
    final line = _stripComment(lines[i]).trim();
    if (line.isNotEmpty) {
      headerIndex = i;
      if (line != 'block-beta' && line != 'block') {
        throw FormatException(tr("Expected a block-beta diagram header."));
      }
      break;
    }
  }
  if (headerIndex < 0) {
    throw FormatException(tr("Missing block-beta diagram header."));
  }

  var generatedId = 0;
  final registry = <String, _BlockBuilder>{};
  final edges = <NativeMermaidBlockEdge>[];
  final root = _BlockBuilder(
    id: 'root',
    label: '',
    shape: NativeMermaidBlockShape.composite,
    sourceType: 'composite',
    columns: -1,
  );

  _parseContainer(
    lines,
    headerIndex + 1,
    root,
    registry,
    edges,
    nextGeneratedId: () => ++generatedId,
    nested: false,
  );

  return NativeMermaidBlockDiagram(root: root.freeze(), edges: edges);
}

int _parseContainer(
  List<String> lines,
  int start,
  _BlockBuilder parent,
  Map<String, _BlockBuilder> registry,
  List<NativeMermaidBlockEdge> edges, {
  required int Function() nextGeneratedId,
  required bool nested,
}) {
  var lineNumber = start;
  while (lineNumber < lines.length) {
    final line = _stripComment(lines[lineNumber]).trim();
    if (line.isEmpty) {
      lineNumber++;
      continue;
    }
    if (line == 'end') {
      if (!nested) {
        throw FormatException(
          tr("Unexpected end at line {0}.", [lineNumber + 1]),
        );
      }
      return lineNumber + 1;
    }
    if (line == 'block' || line.startsWith('block:')) {
      final rawId = line == 'block'
          ? ''
          : line.substring('block:'.length).trim();
      if (rawId.contains(RegExp(r'\s')) || rawId.contains(':')) {
        throw FormatException(
          tr("Invalid block ID at line {0}.", [lineNumber + 1]),
        );
      }
      final id = rawId.isEmpty ? 'generated-block-${nextGeneratedId()}' : rawId;
      final group = _BlockBuilder(
        id: id,
        label: '',
        shape: NativeMermaidBlockShape.composite,
        sourceType: 'composite',
        columns: -1,
      );
      final existing = registry[id];
      if (existing == null) {
        registry[id] = group;
        parent.children.add(group);
      } else {
        existing
          ..shape = NativeMermaidBlockShape.composite
          ..sourceType = 'composite'
          ..label = '';
      }
      final actualGroup = registry[id] ?? group;
      lineNumber = _parseContainer(
        lines,
        lineNumber + 1,
        actualGroup,
        registry,
        edges,
        nextGeneratedId: nextGeneratedId,
        nested: true,
      );
      continue;
    }
    if (line.startsWith('classDef ') ||
        line.startsWith('class ') ||
        line.startsWith('style ') ||
        line.startsWith('linkStyle ') ||
        line.startsWith('interpolate ')) {
      throw FormatException(
        tr("Block classes and style directives are unsupported (line {0}).", [
          lineNumber + 1,
        ]),
      );
    }
    if (line.startsWith('columns')) {
      final match = RegExp(r'^columns\s+(auto|\d+)$').firstMatch(line);
      if (match == null) {
        throw FormatException(
          tr("Invalid columns setting at line {0}.", [lineNumber + 1]),
        );
      }
      parent.columns = match.group(1) == 'auto'
          ? -1
          : int.parse(match.group(1)!);
      lineNumber++;
      continue;
    }
    if (line.startsWith('%%{')) {
      throw FormatException(
        tr("Mermaid directives are unsupported (line {0}).", [lineNumber + 1]),
      );
    }

    _parseNodeAndEdgeLine(
      line,
      lineNumber + 1,
      parent,
      registry,
      edges,
      nextGeneratedId,
    );
    lineNumber++;
  }
  if (nested) {
    throw FormatException(
      tr("Block has no matching end (opened before line {0}).", [start + 1]),
    );
  }
  return lineNumber;
}

void _parseNodeAndEdgeLine(
  String line,
  int lineNumber,
  _BlockBuilder parent,
  Map<String, _BlockBuilder> registry,
  List<NativeMermaidBlockEdge> edges,
  int Function() nextGeneratedId,
) {
  final cursor = _BlockCursor(line, lineNumber);
  while (true) {
    cursor.skipWhitespace();
    if (cursor.done) return;
    final node = _readNode(cursor, nextGeneratedId);
    final registered = _register(node, parent, registry);
    if (registered.shape == NativeMermaidBlockShape.space) {
      cursor.skipWhitespace();
      if (!cursor.done && _readOperator(cursor, allowStartOnly: true) != null) {
        throw FormatException(
          tr("A space block cannot be connected (line {0}).", [lineNumber]),
        );
      }
      continue;
    }

    var from = registered;
    while (true) {
      final saved = cursor.index;
      cursor.skipWhitespace();
      final operator = _readOperator(cursor, allowStartOnly: true);
      if (operator == null) {
        cursor.index = saved;
        break;
      }

      var label = '';
      var finalOperator = operator.value;
      if (!operator.complete) {
        cursor.skipWhitespace();
        if (!cursor.peek('"')) {
          throw FormatException(
            tr("Incomplete block edge at line {0}.", [lineNumber]),
          );
        }
        label = cursor.readQuoted();
        cursor.skipWhitespace();
        final second = _readOperator(cursor, allowStartOnly: false);
        if (second == null || !second.complete) {
          throw FormatException(
            tr("Expected a complete edge after its label at line {0}.", [
              lineNumber,
            ]),
          );
        }
        finalOperator = second.value;
      }

      cursor.skipWhitespace();
      if (cursor.done) {
        throw FormatException(
          tr("Block edge has no destination at line {0}.", [lineNumber]),
        );
      }
      final destination = _register(
        _readNode(cursor, nextGeneratedId),
        parent,
        registry,
      );
      if (destination.shape == NativeMermaidBlockShape.space ||
          destination.shape == NativeMermaidBlockShape.composite) {
        throw FormatException(
          tr("Block edges must connect ordinary nodes (line {0}).", [
            lineNumber,
          ]),
        );
      }
      final baseId = '${from.id}-${destination.id}';
      edges.add(
        NativeMermaidBlockEdge(
          id: baseId,
          start: from.id,
          end: destination.id,
          label: label,
          thickness: finalOperator.contains('==') ? 'thick' : 'normal',
          pattern: finalOperator.contains('.-') ? 'dotted' : 'solid',
          arrowTypeStart: _startArrow(finalOperator),
          arrowTypeEnd: _endArrow(finalOperator),
        ),
      );
      from = destination;
    }
  }
}

_BlockBuilder _register(
  _BlockBuilder candidate,
  _BlockBuilder parent,
  Map<String, _BlockBuilder> registry,
) {
  if (candidate.shape == NativeMermaidBlockShape.space) {
    if (candidate.spaceCount > 0) parent.children.add(candidate);
    return candidate;
  }
  final existing = registry[candidate.id];
  if (existing == null) {
    registry[candidate.id] = candidate;
    parent.children.add(candidate);
    return candidate;
  }
  if (candidate.explicitShape) {
    existing
      ..shape = candidate.shape
      ..sourceType = candidate.sourceType
      ..label = candidate.label;
  }
  return existing;
}

_BlockBuilder _readNode(_BlockCursor cursor, int Function() nextGeneratedId) {
  cursor.skipWhitespace();
  final start = cursor.index;
  if (cursor.startsWith('space')) {
    final afterWord = start + 'space'.length;
    if (afterWord == cursor.text.length ||
        cursor.text[afterWord].trim().isEmpty ||
        cursor.text[afterWord] == ':') {
      cursor.index = afterWord;
      var count = 1;
      if (cursor.peek(':')) {
        cursor.index++;
        final numberStart = cursor.index;
        while (!cursor.done && _isDigit(cursor.current)) {
          cursor.index++;
        }
        if (numberStart == cursor.index) {
          throw FormatException(
            tr("Expected a space count at line {0}.", [cursor.line]),
          );
        }
        count = int.parse(cursor.text.substring(numberStart, cursor.index));
      }
      return _BlockBuilder(
        id: 'generated-${nextGeneratedId()}',
        label: '',
        shape: NativeMermaidBlockShape.space,
        sourceType: 'space',
        spaceCount: count,
      );
    }
  }

  final idStart = cursor.index;
  while (!cursor.done && !_isIdDelimiter(cursor.current)) {
    cursor.index++;
  }
  if (idStart == cursor.index) {
    throw FormatException(
      tr("Expected a block ID at line {0}.", [cursor.line]),
    );
  }
  final id = cursor.text.substring(idStart, cursor.index);
  var shape = NativeMermaidBlockShape.rectangle;
  var sourceType = 'na';
  var label = id;
  var explicitShape = false;

  final whitespaceIndex = cursor.index;
  cursor.skipWhitespace();
  final shapeSyntax = _shapeAt(cursor);
  if (shapeSyntax != null) {
    explicitShape = true;
    shape = shapeSyntax.shape;
    sourceType = shapeSyntax.sourceType;
    cursor.index += shapeSyntax.prefix.length;
    cursor.skipWhitespace();
    if (!cursor.peek('"')) {
      throw FormatException(
        tr("Expected a quoted block label at line {0}.", [cursor.line]),
      );
    }
    label = cursor.readQuoted();
    cursor.skipWhitespace();
    if (!cursor.startsWith(shapeSyntax.suffix)) {
      throw FormatException(
        tr("Unclosed block shape at line {0}.", [cursor.line]),
      );
    }
    cursor.index += shapeSyntax.suffix.length;
  } else {
    cursor.index = whitespaceIndex;
  }

  cursor.skipWhitespace();
  var span = 1;
  if (cursor.peek(':')) {
    cursor.index++;
    final spanStart = cursor.index;
    while (!cursor.done && _isDigit(cursor.current)) {
      cursor.index++;
    }
    if (spanStart == cursor.index) {
      throw FormatException(
        tr("Expected a block span at line {0}.", [cursor.line]),
      );
    }
    span = int.parse(cursor.text.substring(spanStart, cursor.index));
  }
  if (label.contains('<') && label.contains('>')) {
    throw FormatException(
      tr("HTML block labels are not supported (line {0}).", [cursor.line]),
    );
  }
  return _BlockBuilder(
    id: id,
    label: label,
    shape: shape,
    sourceType: sourceType,
    widthInColumns: span,
    explicitShape: explicitShape,
  );
}

const _shapeSyntaxes = <_ShapeSyntax>[
  _ShapeSyntax(
    '(((',
    ')))',
    NativeMermaidBlockShape.doubleCircle,
    'doublecircle',
  ),
  _ShapeSyntax('[[', ']]', NativeMermaidBlockShape.subroutine, 'subroutine'),
  _ShapeSyntax('{{', '}}', NativeMermaidBlockShape.hexagon, 'hexagon'),
  _ShapeSyntax('([', '])', NativeMermaidBlockShape.stadium, 'stadium'),
  _ShapeSyntax('[(', ')]', NativeMermaidBlockShape.cylinder, 'cylinder'),
  _ShapeSyntax('((', '))', NativeMermaidBlockShape.circle, 'circle'),
  _ShapeSyntax('[//', ']', NativeMermaidBlockShape.leanRight, 'lean_right'),
  _ShapeSyntax(
    '[\\',
    '/]',
    NativeMermaidBlockShape.inverseTrapezoid,
    'inv_trapezoid',
  ),
  _ShapeSyntax('[/\\', '\\]', NativeMermaidBlockShape.trapezoid, 'trapezoid'),
  _ShapeSyntax('[\\', ']', NativeMermaidBlockShape.leanLeft, 'lean_left'),
  _ShapeSyntax('<[', ']>', NativeMermaidBlockShape.blockArrow, 'block_arrow'),
  _ShapeSyntax(
    '>',
    ']',
    NativeMermaidBlockShape.leftArrow,
    'rect_left_inv_arrow',
  ),
  _ShapeSyntax('[', ']', NativeMermaidBlockShape.rectangle, 'square'),
  _ShapeSyntax('(', ')', NativeMermaidBlockShape.rounded, 'round'),
  _ShapeSyntax('{', '}', NativeMermaidBlockShape.diamond, 'diamond'),
];

_ShapeSyntax? _shapeAt(_BlockCursor cursor) {
  for (final syntax in _shapeSyntaxes) {
    if (cursor.startsWith(syntax.prefix)) return syntax;
  }
  return null;
}

_Operator? _readOperator(_BlockCursor cursor, {required bool allowStartOnly}) {
  const fullPatterns = <String>[
    r'[xo<]?--+[-xo>]',
    r'[xo<]?==+[=xo>]',
    r'[xo<]?-?\.+-[xo>]',
    r'~~~+',
  ];
  const startPatterns = <String>[r'[xo<]?--+', r'[xo<]?==+', r'[xo<]?-?\.+-'];
  for (final pattern in fullPatterns) {
    final match = RegExp('^$pattern').firstMatch(cursor.remaining);
    if (match != null) {
      cursor.index += match.end;
      return _Operator(match.group(0)!, complete: true);
    }
  }
  if (allowStartOnly) {
    for (final pattern in startPatterns) {
      final match = RegExp('^$pattern').firstMatch(cursor.remaining);
      if (match != null) {
        cursor.index += match.end;
        return _Operator(match.group(0)!, complete: false);
      }
    }
  }
  return null;
}

String _startArrow(String operator) {
  final first = operator.isEmpty ? '' : operator[0];
  return switch (first) {
    'x' => 'arrow_cross',
    'o' => 'arrow_circle',
    '<' => 'arrow_point',
    _ => 'arrow_open',
  };
}

String _endArrow(String operator) {
  final last = operator.isEmpty ? '' : operator[operator.length - 1];
  return switch (last) {
    'x' => 'arrow_cross',
    'o' => 'arrow_circle',
    '>' => 'arrow_point',
    _ => '',
  };
}

String _stripComment(String line) {
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    if (line[i] == '"' && (i == 0 || line[i - 1] != '\\')) {
      quoted = !quoted;
    }
    if (!quoted && line.startsWith('%%', i)) {
      // Mermaid init directives are not comments. Leave them intact so the
      // parser rejects them instead of silently discarding unsupported config.
      if (line.substring(i).startsWith('%%{')) return line;
      return line.substring(0, i);
    }
  }
  return line;
}

bool _isIdDelimiter(String char) =>
    char.trim().isEmpty || '[](){}<>:-'.contains(char);

bool _isDigit(String char) =>
    char.codeUnitAt(0) >= 0x30 && char.codeUnitAt(0) <= 0x39;

class _BlockBuilder {
  _BlockBuilder({
    required this.id,
    required this.label,
    required this.shape,
    this.sourceType = 'na',
    this.widthInColumns = 1,
    this.columns = -1,
    this.spaceCount = 0,
    this.explicitShape = false,
    List<_BlockBuilder>? children,
  }) : children = children ?? <_BlockBuilder>[];

  final String id;
  String label;
  NativeMermaidBlockShape shape;
  String sourceType;
  int widthInColumns;
  int columns;
  int spaceCount;
  bool explicitShape;
  final List<_BlockBuilder> children;

  NativeMermaidBlockNode freeze() => NativeMermaidBlockNode(
    id: id,
    label: label,
    shape: shape,
    sourceType: sourceType,
    widthInColumns: widthInColumns,
    columns: columns,
    spaceCount: spaceCount,
    children: children.map((child) => child.freeze()).toList(growable: false),
  );
}

class _BlockCursor {
  _BlockCursor(this.text, this.line);
  final String text;
  final int line;
  int index = 0;

  bool get done => index >= text.length;
  String get current => done ? '' : text[index];
  String get remaining => text.substring(index);
  bool peek(String value) => startsWith(value);
  bool startsWith(String value) => text.startsWith(value, index);

  void skipWhitespace() {
    while (!done && current.trim().isEmpty) {
      index++;
    }
  }

  String readQuoted() {
    if (!peek('"')) {
      throw FormatException(tr("Expected quoted text at line {0}.", [line]));
    }
    index++;
    final result = StringBuffer();
    while (!done) {
      final char = current;
      index++;
      if (char == '"') return result.toString();
      if (char == '\\' && !done && current == '"') {
        result.write('"');
        index++;
      } else {
        result.write(char);
      }
    }
    throw FormatException(tr("Unclosed quoted text at line {0}.", [line]));
  }
}

class _ShapeSyntax {
  const _ShapeSyntax(this.prefix, this.suffix, this.shape, this.sourceType);
  final String prefix;
  final String suffix;
  final NativeMermaidBlockShape shape;
  final String sourceType;
}

class _Operator {
  const _Operator(this.value, {required this.complete});
  final String value;
  final bool complete;
}
