import '../render_l10n.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import '../html_policy.dart';
import 'mindmap_model.dart';

/// Parses the Mermaid 11.17.2 mindmap source subset used by the native
/// renderer.
///
/// Indentation uses the source parser's whitespace count: each UTF-16 code
/// unit of leading whitespace counts once (including a tab). Parentage follows
/// Mermaid's DB rule: attach a node to the nearest preceding node with a lower
/// normalized level. Frontmatter and Mermaid `%%{...}%%` directives are
/// rejected because their configuration is not consumed by this parser.
NativeMermaidMindmapDiagram parseNativeMermaidMindmap(String source) {
  final normalizedSource = source
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
  final processedForSize = source
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(RegExp(r'^\s*%%(?!\{)[^\n]+\n?', multiLine: true), '')
      .trimLeft();
  if (processedForSize.length > 50000) {
    throw FormatException(
      tr("Mermaid diagram exceeds the default 50000 character limit"),
    );
  }

  // Mermaid applies its default render limit after removing comments and
  // leading whitespace. Its render-time replacement diagram is not reproduced
  // here; this parser reports the shared size limit explicitly.
  final lines = normalizedSource.split('\n');
  final nodes = <_MutableNode>[];
  final ancestorStack = <int>[];
  var headerSeen = false;
  var rootIndent = 0;

  Never invalid(int line, String details) => throw FormatException(
    tr("Invalid Mermaid mindmap at line {0}: {1}", [line, details]),
  );

  for (var index = 0; index < lines.length; index++) {
    final lineNumber = index + 1;
    final line = lines[index];
    final trimmed = line.trim();

    if (RegExp(r'^\s*%%\{').hasMatch(line)) {
      invalid(
        lineNumber,
        tr("Mermaid configuration directives are unsupported"),
      );
    }

    if (!headerSeen && trimmed == '---') {
      invalid(lineNumber, tr("YAML frontmatter is unsupported"));
    }

    if (trimmed.isEmpty || RegExp(r'^\s*%%').hasMatch(line)) continue;

    if (!headerSeen) {
      // preprocessDiagram removes leading comments and trimStart()s the
      // remaining source before the case-insensitive Jison header lexer runs.
      if (line.trimLeft().toLowerCase() != 'mindmap') {
        invalid(lineNumber, tr("Expected a mindmap header"));
      }
      headerSeen = true;
      continue;
    }

    final sourceIndent = _leadingWhitespaceLength(line);
    var body = line.substring(sourceIndent);
    if (body.startsWith(':::')) {
      if (nodes.isEmpty) {
        invalid(lineNumber, tr("Class directive has no preceding node"));
      }
      final value = body.substring(3);
      if (value.isEmpty) {
        invalid(lineNumber, tr("Class directive cannot be empty"));
      }
      nodes.last.className = _sanitizeMermaidText(value);
      continue;
    }

    if (body.toLowerCase().startsWith('::icon(')) {
      if (nodes.isEmpty) {
        invalid(lineNumber, tr("Icon directive has no preceding node"));
      }
      final openLength = '::icon('.length;
      final close = body.indexOf(')', openLength);
      if (close < 0 || body.substring(close + 1).trim().isNotEmpty) {
        invalid(lineNumber, tr("Malformed icon directive"));
      }
      // Mermaid accepts an empty icon directive but its DB ignores the empty
      // value, so preserve that behavior.
      final icon = _sanitizeMermaidText(body.substring(openLength, close));
      if (icon.isNotEmpty) nodes.last.icon = icon;
      continue;
    }

    final opener = _findShapeOpener(body);
    if (opener != null) {
      final (offset, opening, closing, _) = opener;
      final labelStart = offset + opening.length;
      while (!_hasShapeLabelTerminator(body.substring(labelStart), closing) &&
          index + 1 < lines.length) {
        // In Mermaid's NODE lexer, shaped descriptions may span physical
        // lines. Their continuation indentation is part of the description;
        // only the first line determines the node's indentation and source
        // location.
        body = '$body\n${lines[++index]}';
      }
    }
    final parsed = _parseNodeBody(body, lineNumber, invalid);
    if (nodes.isEmpty) {
      rootIndent = sourceIndent;
    }
    final level = sourceIndent - rootIndent;
    while (ancestorStack.isNotEmpty &&
        nodes[ancestorStack.last].level >= level) {
      ancestorStack.removeLast();
    }
    final parentIndex = ancestorStack.isEmpty ? -1 : ancestorStack.last;

    if (nodes.isNotEmpty && parentIndex < 0) {
      throw FormatException(
        tr(
          "There can be only one root. No parent could be found for (\"{0}\")",
          [_sanitizeMermaidText(parsed.label)],
        ),
      );
    }

    final node = _MutableNode(
      id: nodes.length,
      nodeId: _sanitizeMermaidText(parsed.nodeId),
      label: _sanitizeMermaidText(parsed.label),
      level: level,
      sourceIndent: sourceIndent,
      parentId: parentIndex < 0 ? null : nodes[parentIndex].id,
      shape: parsed.shape,
      sourceLine: lineNumber,
    );
    if (parentIndex >= 0) nodes[parentIndex].childIds.add(node.id);
    nodes.add(node);
    ancestorStack.add(node.id);
  }

  if (!headerSeen) {
    throw FormatException(tr("Missing Mermaid mindmap header"));
  }
  if (nodes.isEmpty) {
    throw FormatException(tr("Mindmap must contain a root node"));
  }

  _assignSections(nodes);
  return NativeMermaidMindmapDiagram(
    nodes: nodes.map(
      (node) => NativeMermaidMindmapNode(
        id: node.id,
        nodeId: node.nodeId,
        label: node.label,
        level: node.level,
        sourceIndent: node.sourceIndent,
        parentId: node.parentId,
        childIds: node.childIds,
        shape: node.shape,
        sectionIndex: node.sectionIndex,
        className: node.className,
        icon: node.icon,
        sourceLine: node.sourceLine,
      ),
    ),
  );
}

class _ParsedNodeBody {
  const _ParsedNodeBody({
    required this.nodeId,
    required this.label,
    required this.shape,
  });

  final String nodeId;
  final String label;
  final NativeMermaidMindmapShape shape;
}

_ParsedNodeBody _parseNodeBody(
  String body,
  int lineNumber,
  Never Function(int line, String details) invalid,
) {
  if (body.isEmpty) invalid(lineNumber, tr("Node label cannot be empty"));

  final opener = _findShapeOpener(body);
  if (opener == null) {
    return _ParsedNodeBody(
      nodeId: body,
      label: body,
      shape: NativeMermaidMindmapShape.defaultNode,
    );
  }

  final (offset, opening, closing, shape) = opener;
  final sourceId = body.substring(0, offset);
  final labelStart = offset + opening.length;
  final rawLabel = body.substring(labelStart);
  final parsedLabel = _parseShapeLabel(rawLabel, closing);
  if (parsedLabel == null) {
    invalid(
      lineNumber,
      tr("Malformed {0} node; expected closing delimiter \"{1}\"", [
        shape.name,
        closing,
      ]),
    );
  }
  if (parsedLabel.isEmpty) {
    invalid(lineNumber, tr("Node label cannot be empty"));
  }
  if (sourceId.isEmpty) {
    return _ParsedNodeBody(
      nodeId: parsedLabel,
      label: parsedLabel,
      shape: shape,
    );
  }
  return _ParsedNodeBody(nodeId: sourceId, label: parsedLabel, shape: shape);
}

(int, String, String, NativeMermaidMindmapShape)? _findShapeOpener(
  String body,
) {
  const openers = <(String, String, NativeMermaidMindmapShape)>[
    ('((', '))', NativeMermaidMindmapShape.circle),
    ('{{', '}}', NativeMermaidMindmapShape.hexagon),
    ('))', '((', NativeMermaidMindmapShape.bang),
    ('[', ']', NativeMermaidMindmapShape.rectangle),
    ('(', ')', NativeMermaidMindmapShape.roundedRectangle),
    (')', '(', NativeMermaidMindmapShape.cloud),
  ];
  for (var offset = 0; offset < body.length; offset++) {
    for (final (opening, closing, shape) in openers) {
      if (body.startsWith(opening, offset)) {
        return (offset, opening, closing, shape);
      }
    }
  }
  return null;
}

String? _parseShapeLabel(String source, String closing) {
  String label;
  String remainder;
  if (source.startsWith('"`')) {
    final end = source.indexOf('`"', 2);
    if (end < 0) return null;
    label = source.substring(2, end);
    remainder = source.substring(end + 2);
  } else if (source.startsWith('"')) {
    final end = source.indexOf('"', 1);
    if (end < 0) return null;
    label = source.substring(1, end);
    remainder = source.substring(end + 1);
  } else {
    final end = source.indexOf(closing);
    if (end < 0) return null;
    label = source.substring(0, end);
    remainder = source.substring(end);
  }
  if (!remainder.startsWith(closing)) return null;
  if (remainder.substring(closing.length).trim().isNotEmpty) return null;
  return label;
}

bool _hasShapeLabelTerminator(String source, String closing) {
  if (source.startsWith('"`')) return source.indexOf('`"', 2) >= 0;
  if (source.startsWith('"')) return source.indexOf('"', 1) >= 0;
  return source.contains(closing);
}

int _leadingWhitespaceLength(String line) {
  var count = 0;
  while (count < line.length && RegExp(r'^\s$').hasMatch(line[count])) {
    count++;
  }
  return count;
}

void _assignSections(List<_MutableNode> nodes) {
  if (nodes.isEmpty) return;
  nodes.first.sectionIndex = null;
  for (var index = 0; index < nodes.first.childIds.length; index++) {
    final childId = nodes.first.childIds[index];
    _assignSectionToSubtree(nodes, childId, index % 11);
  }
}

void _assignSectionToSubtree(
  List<_MutableNode> nodes,
  int nodeId,
  int section,
) {
  final node = nodes[nodeId];
  node.sectionIndex = section;
  for (final childId in node.childIds) {
    _assignSectionToSubtree(nodes, childId, section);
  }
}

/// Applies the native safe-HTML policy to a Mermaid label or decoration.
///
/// Mermaid uses DOMPurify directly. The native version shares the app's
/// generated tag/attribute allowlists and HTML5 parser, removes forbidden
/// content and unsafe URIs, and preserves allowed inline markup. This is
/// intentionally documented as a safe subset, since sanitizer serialization
/// and the complete DOMPurify allowlist are not byte-identical.
String _sanitizeMermaidText(String value) {
  if (value.isEmpty || !value.contains('<')) return value;
  final fragment = html.parseFragment(value);
  void clean(dom.Node parent) {
    for (final child in parent.nodes.toList()) {
      if (child is dom.Comment) {
        child.remove();
        continue;
      }
      if (child is! dom.Element) continue;
      final tag = child.localName?.toLowerCase() ?? '';
      if (nativeHtmlForbiddenContents.contains(tag)) {
        child.remove();
        continue;
      }
      if (!nativeHtmlTags.contains(tag)) {
        clean(child);
        final position = parent.nodes.indexOf(child);
        parent.nodes.insertAll(position, child.nodes.toList());
        child.remove();
        continue;
      }
      for (final key in child.attributes.keys.toList()) {
        final name = '$key'.toLowerCase();
        final attributeValue = child.attributes[key] ?? '';
        if (!nativeHtmlAttributes.contains(name) &&
            !name.startsWith('data-') &&
            !name.startsWith('aria-')) {
          child.attributes.remove(key);
          continue;
        }
        if (name.startsWith('data-') ||
            name.startsWith('aria-') ||
            nativeHtmlUriSafeAttributes.contains(name)) {
          continue;
        }
        final normalized = attributeValue.replaceAll(
          RegExp(
            r'[\x00-\x20\x7f-\x9f\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]',
          ),
          '',
        );
        final safeScheme = RegExp(
          r'^(?:(?:(?:f|ht)tps?|mailto|tel|callto|sms|cid|xmpp|matrix):|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))',
          caseSensitive: false,
        ).hasMatch(normalized);
        final dataImage =
            const {'src', 'href', 'xlink:href'}.contains(name) &&
            const {'img', 'image', 'source'}.contains(tag) &&
            normalized.startsWith('data:image/');
        if (normalized.isNotEmpty && !safeScheme && !dataImage) {
          child.attributes.remove(key);
        }
      }
      clean(child);
    }
  }

  clean(fragment);
  return fragment.outerHtml;
}

class _MutableNode {
  _MutableNode({
    required this.id,
    required this.nodeId,
    required this.label,
    required this.level,
    required this.sourceIndent,
    required this.parentId,
    required this.shape,
    required this.sourceLine,
  });

  final int id;
  final String nodeId;
  final String label;
  final int level;
  final int sourceIndent;
  final int? parentId;
  final NativeMermaidMindmapShape shape;
  final int sourceLine;
  final childIds = <int>[];
  String? className;
  String? icon;
  int? sectionIndex;
}
