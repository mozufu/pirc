import '../render_l10n.dart';
import 'package:flutter/foundation.dart';

import 'state_style.dart';

/// Flattened stateDiagram-v2 graph plus metadata and nested regions.
@immutable
class MermaidStateDiagramModel {
  const MermaidStateDiagramModel({
    required this.direction,
    required this.nodes,
    required this.edges,
    required this.styleClasses,
    this.regions = const {},
    this.title = '',
    this.description = '',
    this.accessibleTitle = '',
    this.accessibleDescription = '',
  });

  final String direction;
  final List<MermaidStateNode> nodes;
  final List<MermaidStateEdge> edges;
  final Map<String, MermaidStateStyleClass> styleClasses;
  final Map<String, List<MermaidStateRegion>> regions;
  final String title;
  final String description;
  final String accessibleTitle;
  final String accessibleDescription;

  MermaidStateNode? node(String id) {
    for (final item in nodes) {
      if (item.id == id) return item;
    }
    return null;
  }
}

/// A state, pseudo-state, note, or composite node.
@immutable
class MermaidStateNode {
  const MermaidStateNode({
    required this.id,
    required this.label,
    required this.shape,
    required this.type,
    required this.isGroup,
    this.parentId,
    this.description,
    this.descriptions = const [],
    this.classes = const [],
    this.styles = const [],
    this.note,
    this.noteSide,
    this.direction,
    this.children = const [],
  });

  final String id;
  final String label;
  final String shape;
  final String type;
  final bool isGroup;
  final String? parentId;
  final String? description;
  final List<String> descriptions;
  final List<String> classes;
  final List<String> styles;
  final String? note;
  final String? noteSide;
  final String? direction;
  final List<MermaidStateNode> children;

  bool get isStart => shape == 'stateStart';
  bool get isEnd => shape == 'stateEnd';
}

/// Directed transition. Note connectors have arrowhead 'none'.
@immutable
class MermaidStateEdge {
  const MermaidStateEdge({
    required this.id,
    required this.start,
    required this.end,
    required this.label,
    this.arrowhead = 'normal',
  });

  final String id;
  final String start;
  final String end;
  final String? label;
  final String arrowhead;
}

/// One parallel region within a composite state.
@immutable
class MermaidStateRegion {
  const MermaidStateRegion({
    required this.id,
    required this.direction,
    required this.nodes,
    required this.edges,
  });

  final String id;
  final String direction;
  final List<MermaidStateNode> nodes;
  final List<MermaidStateEdge> edges;
}

/// Mermaid classDef rules, kept as ordered CSS declaration strings.
@immutable
class MermaidStateStyleClass {
  const MermaidStateStyleClass({
    required this.id,
    this.styles = const [],
    this.textStyles = const [],
  });

  final String id;
  final List<String> styles;
  final List<String> textStyles;
}

/// Parses pinned Mermaid 11.17.2 stateDiagram-v2 syntax into a native model.
MermaidStateDiagramModel parseNativeMermaidStateDiagram(String source) {
  if (source.length > 50000) {
    throw FormatException(tr("State diagram exceeds 50000 characters"));
  }
  return _StateDiagramParser(source).parse();
}

class _MutableNode {
  _MutableNode({
    required this.id,
    required this.label,
    required this.shape,
    required this.type,
    required this.isGroup,
    this.parentId,
    this.description,
    this.labelIsExplicit = false,
    this.direction,
  });

  final String id;
  String label;
  String shape;
  String type;
  bool isGroup;
  String? parentId;
  String? description;
  bool labelIsExplicit;
  String? note;
  String? noteSide;
  String? direction;
  final List<String> descriptions = [];
  final List<String> classes = [];
  final List<String> styles = [];
  _Scope? childScope;
}

class _Scope {
  _Scope(this.owner, this.direction);
  final _MutableNode? owner;
  String direction;
  final List<_MutableNode> nodes = [];
  final Map<String, _MutableNode> byId = {};
  final List<MermaidStateEdge> edges = [];
  final List<int> separators = [];
}

class _Declaration {
  const _Declaration(
    this.id,
    this.label,
    this.type,
    this.group,
    this.description,
    this.labelIsExplicit,
  );
  final String id, label, type;
  final bool group;
  final String? description;
  final bool labelIsExplicit;
}

class _Transition {
  const _Transition(this.from, this.to, this.label);
  final String from, to, label;
}

class _StateDiagramParser {
  _StateDiagramParser(String source)
    : lines = source
          .replaceAll('\r\n', '\n')
          .replaceAll('\r', '\n')
          .split('\n');

  final List<String> lines;
  final Map<String, _MutableNode> allNodes = {};
  final List<MermaidStateEdge> allEdges = [];
  final Map<String, MermaidStateStyleClass> styleClasses = {};
  final _Scope root = _Scope(null, 'TB');
  int index = 0;
  int edgeCount = 0;
  int dividerCount = 0;
  bool hasHeader = false;
  String title = '';
  String description = '';
  String accessibleTitle = '';
  String accessibleDescription = '';

  Never fail(int line, String message) => throw FormatException(
    tr("Invalid stateDiagram-v2 at line {0}: {1}", [line, message]),
  );

  MermaidStateDiagramModel parse() {
    readScope(root, false);
    if (!hasHeader) {
      throw FormatException(tr("Expected stateDiagram-v2 header"));
    }
    final regions = <String, List<MermaidStateRegion>>{};
    MermaidStateNode freeze(_MutableNode node) {
      final children =
          node.childScope?.nodes.map(freeze).toList() ??
          const <MermaidStateNode>[];
      return MermaidStateNode(
        id: node.id,
        label: node.label,
        shape: node.shape,
        type: node.type,
        isGroup: node.isGroup,
        parentId: node.parentId,
        description: node.description,
        descriptions: List.unmodifiable(node.descriptions),
        classes: List.unmodifiable(node.classes),
        styles: List.unmodifiable(node.styles),
        note: node.note,
        noteSide: node.noteSide,
        direction: node.direction,
        children: List.unmodifiable(children),
      );
    }

    for (final node in allNodes.values) {
      const suffix = '----parent';
      if (node.shape != 'noteGroup' || !node.id.endsWith(suffix)) continue;
      final subjectId = node.id.substring(0, node.id.length - suffix.length);
      final subject = allNodes[subjectId];
      if (subject == null) continue;
      node.classes
        ..clear()
        ..addAll(subject.classes);
      node.styles
        ..clear()
        ..addAll(subject.styles);
    }

    final flattened = <MermaidStateNode>[];
    void flatten(_Scope scope) {
      for (final node in scope.nodes) {
        flattened.add(freeze(node));
        if (node.childScope != null) flatten(node.childScope!);
        final childScope = node.childScope;
        if (childScope != null) {
          final dividers = childScope.nodes
              .where((n) => n.shape == 'divider')
              .toList();
          if (dividers.isNotEmpty) {
            regions[node.id] = List.unmodifiable(
              dividers.map((divider) {
                final regionScope = divider.childScope;
                return MermaidStateRegion(
                  id: divider.id,
                  direction: regionScope?.direction ?? childScope.direction,
                  nodes: List.unmodifiable(
                    regionScope?.nodes.map(freeze) ??
                        const <MermaidStateNode>[],
                  ),
                  edges: List.unmodifiable(
                    regionScope?.edges ?? const <MermaidStateEdge>[],
                  ),
                );
              }),
            );
          }
        }
      }
    }

    flatten(root);
    if (flattened.isEmpty) {
      throw FormatException(tr("State diagram has no states"));
    }
    return MermaidStateDiagramModel(
      direction: root.direction,
      nodes: List.unmodifiable(flattened),
      edges: List.unmodifiable(allEdges),
      styleClasses: Map.unmodifiable(styleClasses),
      regions: Map.unmodifiable(regions),
      title: title,
      description: description,
      accessibleTitle: accessibleTitle,
      accessibleDescription: accessibleDescription,
    );
  }

  void readScope(_Scope scope, bool nested) {
    while (index < lines.length) {
      final lineNumber = index + 1;
      var line = stripComment(lines[index++]).trim();
      if (line.isEmpty) continue;
      if (line.startsWith('%%{')) {
        fail(lineNumber, tr("configuration directives are unsupported"));
      }
      if (line == 'stateDiagram-v2') {
        if (hasHeader || nested) fail(lineNumber, tr("unexpected header"));
        hasHeader = true;
        continue;
      }
      if (!hasHeader) fail(lineNumber, tr("expected stateDiagram-v2 header"));
      final parts = splitSemicolons(line);
      if (parts.length > 1) {
        for (var i = parts.length - 1; i > 0; i--) {
          lines.insert(index, parts[i]);
        }
        line = parts.first;
      }
      if (line == '}') {
        if (!nested) fail(lineNumber, tr("unmatched closing brace"));
        return;
      }
      if (line == '--') {
        if (!nested || scope.owner == null) {
          fail(lineNumber, tr("parallel separator must be inside a state"));
        }
        if (scope.separators.isNotEmpty &&
            scope.separators.last == scope.nodes.length) {
          fail(lineNumber, tr("parallel regions cannot be empty"));
        }
        scope.separators.add(scope.nodes.length);
        continue;
      }

      final dir = RegExp(
        r'^direction\s+(TB|BT|LR|RL)\s*$',
        caseSensitive: false,
      ).firstMatch(line);
      if (dir != null) {
        scope.direction = dir[1]!.toUpperCase();
        if (scope.owner != null) scope.owner!.direction = scope.direction;
        continue;
      }
      if (parseMetadata(line, lineNumber)) continue;
      if (parseClassDef(line, lineNumber)) continue;
      if (parseClass(line, scope, lineNumber)) continue;
      if (parseStyle(line, scope, lineNumber)) continue;
      if (parseNote(line, scope, lineNumber)) continue;

      final declaration = parseDeclaration(line);
      if (declaration != null) {
        final node = ensure(
          scope,
          declaration.id,
          declaration.label,
          declaration.type,
          declared: true,
          labelIsExplicit: declaration.labelIsExplicit,
        );
        if (declaration.description != null) {
          appendDescription(node, declaration.description!);
        }
        if (declaration.group) {
          if (node.childScope != null) {
            fail(lineNumber, tr("state {0} already has a body", [node.id]));
          }
          node.isGroup = true;
          node.shape = 'roundedWithTitle';
          node.childScope = _Scope(node, scope.direction);
          readScope(node.childScope!, true);
          finishScope(node.childScope!, lineNumber);
        }
        continue;
      }

      final transition = parseTransition(line);
      if (transition != null) {
        if (transition.from.isEmpty || transition.to.isEmpty) {
          fail(lineNumber, tr("transition needs two endpoints"));
        }
        final from = endpoint(scope, transition.from, true, lineNumber);
        final to = endpoint(scope, transition.to, false, lineNumber);
        final edge = MermaidStateEdge(
          id: 'edge${edgeCount++}',
          start: from.id,
          end: to.id,
          label: transition.label,
        );
        scope.edges.add(edge);
        allEdges.add(edge);
        continue;
      }
      if (parseDescription(line, scope)) continue;
      final bareIds = line.split(RegExp(r'\s+'));
      if (bareIds.length > 1 && bareIds.every(isId)) {
        for (final id in bareIds) {
          ensure(scope, id, id, 'default', declared: true);
        }
        continue;
      }
      if (isId(line)) {
        ensure(scope, unquote(line), unquote(line), 'default', declared: true);
        continue;
      }
      fail(lineNumber, tr("unsupported statement: {0}", [line]));
    }
    if (nested) fail(lines.length, tr("unclosed state body"));
  }

  void finishScope(_Scope scope, int line) {
    if (scope.separators.isEmpty) return;
    if (scope.separators.last == scope.nodes.length) {
      fail(line, tr("parallel region is empty"));
    }
    final bounds = <int>[0, ...scope.separators, scope.nodes.length];
    final originals = List<_MutableNode>.from(scope.nodes);
    final originalEdges = List<MermaidStateEdge>.from(scope.edges);
    final wrappers = <_MutableNode>[];
    final members = <Set<String>>[];
    for (var r = 0; r < bounds.length - 1; r++) {
      final children = originals.sublist(bounds[r], bounds[r + 1]);
      if (children.isEmpty) fail(line, tr("parallel region is empty"));
      members.add(children.map((node) => node.id).toSet());
      final id = 'divider-id-${++dividerCount}';
      final divider = ensure(
        scope,
        id,
        '',
        'divider',
        declared: false,
        group: true,
        shape: 'divider',
      );
      final childScope = _Scope(divider, scope.direction);
      childScope.nodes.addAll(children);
      for (final child in children) {
        child.parentId = divider.id;
        childScope.byId[child.id] = child;
      }
      divider.childScope = childScope;
      wrappers.add(divider);
    }
    for (final edge in originalEdges) {
      for (var r = 0; r < wrappers.length; r++) {
        if (members[r].contains(edge.start) && members[r].contains(edge.end)) {
          wrappers[r].childScope!.edges.add(edge);
          scope.edges.remove(edge);
          break;
        }
      }
    }
    scope.nodes
      ..clear()
      ..addAll(wrappers);
    scope.byId
      ..clear()
      ..addEntries(wrappers.map((node) => MapEntry(node.id, node)));
  }

  _MutableNode endpoint(_Scope scope, String raw, bool isSource, int line) {
    final token = raw.trim();
    if (token == '[*]') {
      final prefix = scope.owner?.id ?? 'root';
      final id = '${prefix}_${isSource ? 'start' : 'end'}';
      return ensure(scope, id, id, isSource ? 'start' : 'end', declared: false);
    }
    if (!isId(token) && !isQuoted(token)) {
      fail(line, tr("invalid state identifier: {0}", [token]));
    }
    final id = unquote(token);
    return ensure(scope, id, id, 'default', declared: false);
  }

  _MutableNode ensure(
    _Scope scope,
    String id,
    String label,
    String type, {
    required bool declared,
    String? description,
    bool labelIsExplicit = false,
    bool group = false,
    String? shape,
  }) {
    final key = id.trim();
    if (key.isEmpty) throw FormatException(tr("State id is empty"));
    final existing = scope.byId[key];
    if (existing != null) {
      if (declared) {
        if (label != key || existing.label == existing.id) {
          existing.label = label;
        }
        if (labelIsExplicit) existing.labelIsExplicit = true;
        if (group) {
          existing.isGroup = true;
          existing.shape = shape ?? 'roundedWithTitle';
          existing.direction = scope.direction;
        }
      }
      return existing;
    }
    if (allNodes.containsKey(key)) {
      throw FormatException(
        tr("Duplicate state id in nested scopes: {0}", [key]),
      );
    }
    final node = _MutableNode(
      id: key,
      label: label,
      shape: shape ?? shapeFor(type, group: group),
      type: type,
      isGroup: group,
      parentId: scope.owner?.id,
      description: description,
      labelIsExplicit: labelIsExplicit,
      direction: group ? scope.direction : null,
    );
    scope.nodes.add(node);
    scope.byId[key] = node;
    allNodes[key] = node;
    return node;
  }

  String shapeFor(String type, {bool group = false}) {
    if (group) return 'roundedWithTitle';
    switch (type) {
      case 'start':
        return 'stateStart';
      case 'end':
        return 'stateEnd';
      case 'join':
        return 'join';
      case 'choice':
        return 'choice';
      case 'fork':
        return 'fork';
      case 'divider':
        return 'divider';
      default:
        return 'rect';
    }
  }

  bool parseMetadata(String line, int lineNumber) {
    final a = RegExp(
      r'^accTitle\s*:\s*(.*)$',
      caseSensitive: false,
    ).firstMatch(line);
    if (a != null) {
      accessibleTitle = unquote(a[1]!.trim());
      return true;
    }
    final b = RegExp(
      r'^accDescr\s*:\s*(.*)$',
      caseSensitive: false,
    ).firstMatch(line);
    if (b != null) {
      accessibleDescription = unquote(b[1]!.trim());
      return true;
    }
    if (RegExp(r'^accDescr\s*\{\s*$', caseSensitive: false).hasMatch(line)) {
      final values = <String>[];
      var closed = false;
      while (index < lines.length) {
        final next = lines[index++].trim();
        if (next == '}') {
          closed = true;
          break;
        }
        values.add(next);
      }
      if (!closed) fail(lineNumber, tr("unclosed accDescr block"));
      accessibleDescription = values.join('\n');
      return true;
    }
    return false;
  }

  bool parseClassDef(String line, int lineNumber) {
    final match = RegExp(
      r'^classDef\s+([A-Za-z_][\w-]*)\s+(.+?)\s*;?$',
      caseSensitive: false,
    ).firstMatch(line);
    if (match == null) return false;
    final styles = splitStyleList(match[2]!, lineNumber);
    if (styles.isEmpty) fail(lineNumber, tr("classDef has no declarations"));
    final textStyles = <String>[];
    for (final style in styles) {
      final pair = style.split(':');
      if (pair.length < 2) {
        fail(lineNumber, tr("invalid style declaration: {0}", [style]));
      }
      final key = pair.first.trim();
      final value = pair.skip(1).join(':').trim();
      validateStyle(key, value, lineNumber);
      if (key == 'color') textStyles.add('fill:$value');
    }
    styleClasses[match[1]!] = MermaidStateStyleClass(
      id: match[1]!,
      styles: List.unmodifiable(styles),
      textStyles: List.unmodifiable(textStyles),
    );
    return true;
  }

  bool parseClass(String line, _Scope scope, int lineNumber) {
    final match = RegExp(
      r'^class\s+([^ ]+)\s+(.+?)\s*;?$',
      caseSensitive: false,
    ).firstMatch(line);
    if (match == null) return false;
    final ids = match[1]!.split(',').map(unquote);
    final names = match[2]!
        .split(RegExp(r'[\s,]+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (names.isEmpty) fail(lineNumber, tr("class statement has no class"));
    for (final id in ids) {
      final node = ensure(scope, id, id, 'default', declared: false);
      for (final name in names) {
        if (!node.classes.contains(name)) node.classes.add(name);
      }
    }
    return true;
  }

  bool parseStyle(String line, _Scope scope, int lineNumber) {
    final match = RegExp(
      r'^style\s+([^ ]+)\s+(.+?)\s*;?$',
      caseSensitive: false,
    ).firstMatch(line);
    if (match == null) return false;
    final styles = splitStyleList(match[2]!, lineNumber);
    if (styles.isEmpty) fail(lineNumber, tr("style has no declarations"));
    for (final style in styles) {
      final pair = style.split(':');
      if (pair.length < 2) {
        fail(lineNumber, tr("invalid style declaration: {0}", [style]));
      }
      validateStyle(
        pair.first.trim(),
        pair.skip(1).join(':').trim(),
        lineNumber,
      );
    }
    for (final id in match[1]!.split(',').map(unquote)) {
      ensure(scope, id, id, 'default', declared: false).styles.addAll(styles);
    }
    return true;
  }

  void validateStyle(String key, String value, int lineNumber) {
    const keys = {'fill', 'stroke', 'color', 'stroke-width'};
    if (!keys.contains(key)) {
      fail(lineNumber, tr("unsupported state style property: {0}", [key]));
    }
    if (value.isEmpty) {
      fail(lineNumber, tr("empty value for style property: {0}", [key]));
    }
    if (key == 'stroke-width') {
      final width = RegExp(
        r'^([0-9]+(?:\.[0-9]+)?)(?:px)?$',
        caseSensitive: false,
      ).firstMatch(value);
      final parsed = width == null ? null : double.tryParse(width[1]!);
      if (parsed == null || !parsed.isFinite) {
        fail(lineNumber, tr("unsupported stroke-width value: {0}", [value]));
      }
      return;
    }
    if (parseNativeMermaidStateColor(value) == null) {
      fail(lineNumber, tr("unsupported state color: {0}", [value]));
    }
  }

  List<String> splitStyleList(String source, int lineNumber) {
    final result = <String>[];
    var start = 0;
    var depth = 0;
    for (var i = 0; i < source.length; i++) {
      if (source[i] == '(') {
        depth++;
      } else if (source[i] == ')') {
        depth--;
        if (depth < 0) fail(lineNumber, tr("unbalanced style value"));
      } else if (source[i] == ',' && depth == 0) {
        final declaration = source.substring(start, i).trim();
        if (declaration.isNotEmpty) result.add(declaration);
        start = i + 1;
      }
    }
    if (depth != 0) fail(lineNumber, tr("unbalanced style value"));
    final tail = source.substring(start).trim();
    if (tail.isNotEmpty) result.add(tail);
    return result;
  }

  bool parseNote(String line, _Scope scope, int lineNumber) {
    final match = RegExp(
      r'^note\s+(left|right)\s+of\s+(.+?)(?:\s*:\s*(.*))?$',
      caseSensitive: false,
    ).firstMatch(line);
    if (match == null) return false;
    final side = match[1]!.toLowerCase();
    final subjectId = unquote(match[2]!.trim());
    var text = match[3]?.trim() ?? '';
    if (text.isEmpty) {
      final noteLines = <String>[];
      var closed = false;
      while (index < lines.length) {
        final next = stripComment(lines[index++]).trim();
        if (next.toLowerCase() == 'end note') {
          closed = true;
          break;
        }
        noteLines.add(next);
      }
      if (!closed) fail(lineNumber, tr("unclosed note"));
      text = noteLines.join('\n').trim();
    }
    final subject = ensure(
      scope,
      subjectId,
      subjectId,
      'default',
      declared: false,
    );
    subject.note = text;
    final groupId = '${subject.id}----parent';
    final noteId = '${subject.id}----note-1';
    final group = ensure(
      scope,
      groupId,
      text,
      'default',
      declared: false,
      group: true,
      shape: 'noteGroup',
    );
    group.noteSide = side;
    group.direction = scope.direction;
    group.classes
      ..clear()
      ..addAll(subject.classes);
    group.styles
      ..clear()
      ..addAll(subject.styles);
    group.childScope ??= _Scope(group, scope.direction);
    final note = ensure(
      group.childScope!,
      noteId,
      text,
      'note',
      declared: false,
      shape: 'note',
    );
    note.noteSide = side;
    final edge = MermaidStateEdge(
      id: '${subject.id}-$noteId',
      start: subject.id,
      end: noteId,
      label: null,
      arrowhead: 'none',
    );
    scope.edges.add(edge);
    allEdges.add(edge);
    edgeCount++;
    return true;
  }

  bool parseDescription(String line, _Scope scope) {
    final match = RegExp(r'^(.+?)\s*:\s*(.+)$').firstMatch(line);
    if (match == null) return false;
    final rawId = match[1]!.trim();
    if (!isId(rawId) && !isQuoted(rawId)) return false;
    final id = unquote(rawId);
    final text = unquote(match[2]!.trim());
    final node = ensure(scope, id, id, 'default', declared: true);
    appendDescription(node, text);
    return true;
  }

  void appendDescription(_MutableNode node, String text) {
    if (!node.labelIsExplicit && node.descriptions.isEmpty) {
      node.label = text;
      node.labelIsExplicit = true;
      return;
    }
    node.descriptions.add(text);
    node.description = node.descriptions.join('\n');
    if (node.type == 'default' && !node.isGroup) {
      node.shape = 'rectWithTitle';
    }
  }

  _Declaration? parseDeclaration(String line) {
    final match = RegExp(
      r'^state\s+(.+?)(\s*\{)?\s*$',
      caseSensitive: false,
    ).firstMatch(line);
    if (match == null) return null;
    var value = match[1]!.trim();
    final opens = match[2] != null;
    String? desc;
    final colon = colonOutsideQuotes(value);
    if (colon >= 0) {
      desc = unquote(value.substring(colon + 1).trim());
      value = value.substring(0, colon).trim();
    }
    final alias = RegExp(
      r'^\x22((?:[^\x22\\]|\\.)*)\x22\s+as\s+([A-Za-z0-9_][\w.-]*)$',
      caseSensitive: false,
    ).firstMatch(value);
    if (alias != null) {
      return _Declaration(
        alias[2]!,
        unescape(alias[1]!),
        'default',
        opens,
        desc,
        true,
      );
    }
    final typed = RegExp(
      r'^(.*?)\s*(?:<<\s*(choice|fork|join)\s*>>|\[\[\s*(choice|fork|join)\s*\]\])$',
      caseSensitive: false,
    ).firstMatch(value);
    if (typed != null) {
      final id = unquote(typed[1]!.trim());
      if (!isId(id)) return null;
      return _Declaration(
        id,
        id,
        (typed[2] ?? typed[3]!).toLowerCase(),
        opens,
        desc,
        false,
      );
    }
    final id = unquote(value);
    if (!isId(id)) return null;
    return _Declaration(id, id, 'default', opens, desc, false);
  }

  _Transition? parseTransition(String line) {
    final arrow = line.indexOf('-->');
    if (arrow < 0) return null;
    final from = line.substring(0, arrow).trim();
    final right = line.substring(arrow + 3).trim();
    if (from.isEmpty || right.isEmpty) return const _Transition('', '', '');
    final colon = colonOutsideQuotes(right);
    final to = (colon < 0 ? right : right.substring(0, colon)).trim();
    final label = colon < 0 ? '' : unquote(right.substring(colon + 1).trim());
    if (to.isEmpty ||
        (!isId(from) && from != '[*]' && !isQuoted(from)) ||
        (!isId(to) && to != '[*]' && !isQuoted(to))) {
      return const _Transition('', '', '');
    }
    return _Transition(from, to, label);
  }

  bool isId(String value) =>
      RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.-]*$').hasMatch(value.trim());

  bool isQuoted(String value) {
    final text = value.trim();
    return text.length >= 2 &&
        text.codeUnitAt(0) == 34 &&
        text.codeUnitAt(text.length - 1) == 34;
  }

  String unquote(String value) {
    final text = value.trim();
    if (isQuoted(text)) return unescape(text.substring(1, text.length - 1));
    if (text.length >= 2 &&
        text.codeUnitAt(0) == 39 &&
        text.codeUnitAt(text.length - 1) == 39) {
      return text.substring(1, text.length - 1);
    }
    return text;
  }

  String unescape(String value) =>
      value.replaceAll(r'\"', '"').replaceAll(r'\\', r'\');

  int colonOutsideQuotes(String value) {
    var quoted = false;
    var escaped = false;
    for (var i = 0; i < value.length; i++) {
      final c = value[i];
      if (escaped) {
        escaped = false;
      } else if (quoted && c == r'\') {
        escaped = true;
      } else if (c == '"') {
        quoted = !quoted;
      } else if (!quoted && c == ':') {
        return i;
      }
    }
    return -1;
  }

  String stripComment(String line) {
    var quoted = false;
    var escaped = false;
    for (var i = 0; i + 1 < line.length; i++) {
      final c = line[i];
      if (escaped) {
        escaped = false;
      } else if (quoted && c == r'\') {
        escaped = true;
      } else if (c == '"') {
        quoted = !quoted;
      } else if (!quoted && line.startsWith('%%', i)) {
        if (line.startsWith('%%{', i)) return line.trim();
        return line.substring(0, i);
      }
    }
    return line;
  }

  List<String> splitSemicolons(String line) {
    final result = <String>[];
    var quoted = false;
    var start = 0;
    for (var i = 0; i < line.length; i++) {
      if (line[i] == '"') quoted = !quoted;
      if (!quoted && line[i] == ';') {
        final part = line.substring(start, i).trim();
        if (part.isNotEmpty) result.add(part);
        start = i + 1;
      }
    }
    final tail = line.substring(start).trim();
    if (tail.isNotEmpty) result.add(tail);
    return result.isEmpty ? [line] : result;
  }
}
