import '../render_l10n.dart';
import 'kanban_model.dart';

/// Parses the Kanban subset backed by Mermaid 11.17.2's `kanbanDb`.
///
/// It accepts the diagram header, ordered columns, card labels in Mermaid's
/// common bracket form, multiline bracket labels, and inline ticket/assignee/
/// priority metadata. It rejects icon/class decorators, nested YAML, unknown
/// metadata keys, and unmatched shapes rather than dropping those values.
NativeMermaidKanbanBoard parseNativeMermaidKanban(String source) {
  final normalized = source.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (normalized.length > 50000) {
    throw FormatException(
      tr("Mermaid Kanban exceeds the 50000 character native limit"),
    );
  }
  final lines = normalized.split('\n');
  var headerSeen = false;
  final nodes = <_ParsedKanbanNode>[];
  var generatedId = 0;

  Never invalid(int line, String message) => throw FormatException(
    tr("Kanban parse error on line {0}: {1}", [line, message]),
  );

  for (var index = 0; index < lines.length; index++) {
    final lineNumber = index + 1;
    final rawLine = lines[index];
    final content = rawLine.trim();
    if (content.isEmpty || content.startsWith('%%')) continue;
    if (!headerSeen) {
      if (content.toLowerCase() != 'kanban') {
        invalid(lineNumber, tr("Expected a Kanban header"));
      }
      headerSeen = true;
      continue;
    }

    final indent = rawLine.length - rawLine.trimLeft().length;
    var nodeSource = rawLine.trimLeft();
    if (nodeSource.contains(':::') || nodeSource.contains('::icon(')) {
      invalid(
        lineNumber,
        tr("Kanban class and icon decorators are unsupported"),
      );
    }

    final metadataStart = nodeSource.indexOf('@{');
    String? metadataText;
    if (metadataStart >= 0) {
      if (!nodeSource.endsWith('}')) {
        invalid(lineNumber, tr("Metadata must end with a closing brace"));
      }
      metadataText = nodeSource.substring(
        metadataStart + 2,
        nodeSource.length - 1,
      );
      nodeSource = nodeSource.substring(0, metadataStart).trimRight();
      if (metadataText.contains('{') || metadataText.contains('}')) {
        invalid(lineNumber, tr("Nested metadata objects are unsupported"));
      }
    }

    final parsedShape = _parseShape(nodeSource, lineNumber, invalid);
    if (parsedShape.needsContinuation) {
      final bodyLines = <String>[parsedShape.label];
      while (index + 1 < lines.length) {
        final continuation = lines[++index];
        final closing = _closingDelimiter(parsedShape.sourceShape);
        final closeAt = continuation.indexOf(closing);
        if (closeAt >= 0) {
          bodyLines.add(continuation.substring(0, closeAt));
          final trailing = continuation
              .substring(closeAt + closing.length)
              .trim();
          if (trailing.isNotEmpty) {
            invalid(
              index + 1,
              tr("Text after a multiline card label is unsupported"),
            );
          }
          break;
        }
        bodyLines.add(continuation);
      }
      if (index >= lines.length - 1 &&
          !lines[index].contains(_closingDelimiter(parsedShape.sourceShape))) {
        invalid(lineNumber, tr("Unterminated multiline card label"));
      }
      nodes.add(
        _ParsedKanbanNode(
          id: parsedShape.id.isEmpty ? 'kbn${generatedId++}' : parsedShape.id,
          label: bodyLines.join('\n'),
          level: indent,
          lineNumber: lineNumber,
          sourceShape: parsedShape.sourceShape,
          metadata: _metadata(metadataText, lineNumber, invalid),
        ),
      );
      continue;
    }

    nodes.add(
      _ParsedKanbanNode(
        id: parsedShape.id.isEmpty ? 'kbn${generatedId++}' : parsedShape.id,
        label: parsedShape.label,
        level: indent,
        lineNumber: lineNumber,
        sourceShape: parsedShape.sourceShape,
        metadata: _metadata(metadataText, lineNumber, invalid),
      ),
    );
  }

  if (!headerSeen) throw FormatException(tr("Missing Kanban header"));
  if (nodes.isEmpty) return NativeMermaidKanbanBoard(columns: const []);

  final sectionLevel = nodes.first.level;
  final sections = <_ParsedKanbanNode>[];
  final children = <String, List<_ParsedKanbanNode>>{};
  _ParsedKanbanNode? currentSection;
  for (final node in nodes) {
    if (node.level < sectionLevel) {
      invalid(
        node.lineNumber,
        tr("Items cannot be above the first column level"),
      );
    }
    if (node.level == sectionLevel) {
      sections.add(node);
      currentSection = node;
      children[node.id] = <_ParsedKanbanNode>[];
    } else {
      if (currentSection == null) {
        invalid(node.lineNumber, tr("A card must follow a column"));
      }
      children[currentSection.id]!.add(node);
    }
  }

  return NativeMermaidKanbanBoard(
    columns: sections.map((section) {
      return NativeMermaidKanbanColumn(
        id: section.id,
        label: section.metadata['label']?.isNotEmpty == true
            ? section.metadata['label']!
            : section.label,
        sourceLevel: section.level,
        ticket: section.metadata['ticket'],
        cards: children[section.id]!.map((node) {
          final effectiveLabel = node.metadata['label']?.isNotEmpty == true
              ? node.metadata['label']!
              : node.label;
          return NativeMermaidKanbanCard(
            id: node.id,
            label: effectiveLabel,
            sourceLevel: node.level,
            ticket: node.metadata['ticket'],
            assigned: node.metadata['assigned'],
            priority: node.metadata['priority'],
            sourceShape: node.sourceShape,
          );
        }),
      );
    }),
  );
}

class _ParsedKanbanNode {
  const _ParsedKanbanNode({
    required this.id,
    required this.label,
    required this.level,
    required this.sourceShape,
    required this.metadata,
    required this.lineNumber,
  });

  final String id;
  final String label;
  final int level;
  final String sourceShape;
  final Map<String, String> metadata;
  final int lineNumber;
}

class _ParsedShape {
  const _ParsedShape({
    required this.id,
    required this.label,
    required this.sourceShape,
    this.needsContinuation = false,
  });

  final String id;
  final String label;
  final String sourceShape;
  final bool needsContinuation;
}

_ParsedShape _parseShape(
  String value,
  int line,
  Never Function(int, String) invalid,
) {
  final source = value.trim();
  if (source.isEmpty) invalid(line, tr("Column or card label is empty"));
  final openIndex = _firstShapeDelimiter(source);
  if (openIndex < 0) {
    return _ParsedShape(id: source, label: source, sourceShape: 'default');
  }

  final id = source.substring(0, openIndex).trim();
  final shaped = source.substring(openIndex);
  final opening = _openingDelimiter(shaped);
  if (opening == null) invalid(line, tr("Unsupported Kanban card shape"));
  final close = _closingDelimiterForOpening(opening);
  final bodyStart = opening.length;
  final closeAt = shaped.indexOf(close, bodyStart);
  if (closeAt < 0) {
    return _ParsedShape(
      id: id,
      label: shaped.substring(bodyStart),
      sourceShape: _shapeName(opening),
      needsContinuation: true,
    );
  }
  if (shaped.substring(closeAt + close.length).trim().isNotEmpty) {
    invalid(line, tr("Unexpected text after the card shape"));
  }
  return _ParsedShape(
    id: id,
    label: shaped.substring(bodyStart, closeAt),
    sourceShape: _shapeName(opening),
  );
}

int _firstShapeDelimiter(String value) {
  final candidates = [
    value.indexOf('['),
    value.indexOf('('),
    value.indexOf('{{'),
  ].where((index) => index >= 0);
  return candidates.isEmpty ? -1 : candidates.reduce((a, b) => a < b ? a : b);
}

String? _openingDelimiter(String value) {
  if (value.startsWith('((')) return '((';
  if (value.startsWith('{{')) return '{{';
  if (value.startsWith('[')) return '[';
  if (value.startsWith('(')) return '(';
  return null;
}

String _closingDelimiterForOpening(String opening) => switch (opening) {
  '((' => '))',
  '{{' => '}}',
  '[' => ']',
  '(' => ')',
  _ => '',
};

String _closingDelimiter(String sourceShape) => switch (sourceShape) {
  'circle' => '))',
  'hexagon' => '}}',
  'rect' => ']',
  'rounded-rect' => ')',
  _ => '',
};

String _shapeName(String opening) => switch (opening) {
  '((' => 'circle',
  '{{' => 'hexagon',
  '[' => 'rect',
  '(' => 'rounded-rect',
  _ => 'default',
};

Map<String, String> _metadata(
  String? source,
  int line,
  Never Function(int, String) invalid,
) {
  if (source == null || source.trim().isEmpty) return const {};
  final result = <String, String>{};
  for (final entry in _splitMetadata(source)) {
    final separator = entry.indexOf(':');
    if (separator <= 0) invalid(line, tr("Expected key: value metadata"));
    final key = entry.substring(0, separator).trim();
    final value = _unquote(entry.substring(separator + 1).trim());
    if (!const {
      'ticket',
      'assigned',
      'priority',
      'label',
      'shape',
    }.contains(key)) {
      invalid(line, tr("Unsupported Kanban metadata key \"{0}\"", [key]));
    }
    if (key == 'shape' && value != 'kanbanItem') {
      invalid(line, tr("Only the source kanbanItem shape is supported"));
    }
    if (result.containsKey(key)) {
      invalid(line, tr("Duplicate metadata key \"{0}\"", [key]));
    }
    result[key] = value;
  }
  return Map.unmodifiable(result);
}

List<String> _splitMetadata(String source) {
  final entries = <String>[];
  var start = 0;
  String? quote;
  for (var index = 0; index < source.length; index++) {
    final character = source[index];
    if (quote != null) {
      if (character == quote && (index == 0 || source[index - 1] != r'\')) {
        quote = null;
      }
    } else if (character == '"' || character == "'") {
      quote = character;
    } else if (character == ',') {
      entries.add(source.substring(start, index).trim());
      start = index + 1;
    }
  }
  if (quote != null) {
    throw FormatException(tr("Unterminated quoted metadata value"));
  }
  entries.add(source.substring(start).trim());
  return entries;
}

String _unquote(String value) {
  if (value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'")))) {
    return value.substring(1, value.length - 1);
  }
  if (value.contains('{') || value.contains('}')) {
    throw FormatException(tr("Nested Kanban metadata values are unsupported"));
  }
  return value;
}
