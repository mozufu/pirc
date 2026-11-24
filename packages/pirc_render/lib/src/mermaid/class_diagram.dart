import '../render_l10n.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// One class member as Mermaid's class DB interprets it.
class NativeMermaidClassMember {
  const NativeMermaidClassMember({
    required this.text,
    required this.id,
    required this.visibility,
    required this.memberType,
    required this.classifier,
    this.parameters = '',
    this.returnType = '',
  });

  /// Mermaid's escaped DB form, including the backslash before visibility.
  final String text;
  final String id;
  final String visibility;
  final String memberType;
  final String classifier;
  final String parameters;
  final String returnType;

  bool get isMethod => memberType == 'method';
  bool get isStatic => classifier == r'$';
  bool get isAbstract => classifier == '*';

  String get displayText {
    var value = text.startsWith(r'\') ? text.substring(1) : text;
    return value.replaceAll('&lt;', '<').replaceAll('&gt;', '>');
  }
}

/// A class node produced by the native-supported Mermaid parser.
class NativeMermaidClassNode {
  const NativeMermaidClassNode({
    required this.id,
    required this.label,
    required this.text,
    required this.genericType,
    required this.members,
    required this.methods,
    required this.annotations,
    this.namespace,
  });

  final String id;
  final String label;

  /// Mermaid DB text (generic type is HTML-escaped in this field).
  final String text;
  final String genericType;
  final List<NativeMermaidClassMember> members;
  final List<NativeMermaidClassMember> methods;
  final List<String> annotations;
  final String? namespace;

  String get displayLabel =>
      genericType.isEmpty ? label : '$label<$genericType>';
}

/// A Mermaid relation marker at one end of an edge.
enum NativeMermaidClassMarker {
  none,
  aggregation,
  composition,
  dependency,
  extension,
  lollipop,
}

extension NativeMermaidClassMarkerName on NativeMermaidClassMarker {
  String get dbName => switch (this) {
    NativeMermaidClassMarker.none => 'none',
    NativeMermaidClassMarker.aggregation => 'aggregation',
    NativeMermaidClassMarker.composition => 'composition',
    NativeMermaidClassMarker.dependency => 'dependency',
    NativeMermaidClassMarker.extension => 'extension',
    NativeMermaidClassMarker.lollipop => 'lollipop',
  };
}

/// One class relation, retaining Mermaid's start/end marker placement.
class NativeMermaidClassRelation {
  const NativeMermaidClassRelation({
    required this.start,
    required this.end,
    required this.startMarker,
    required this.endMarker,
    required this.pattern,
    this.startMultiplicity = '',
    this.endMultiplicity = '',
    this.label = '',
    this.isNoteLink = false,
  });

  final String start;
  final String end;
  final NativeMermaidClassMarker startMarker;
  final NativeMermaidClassMarker endMarker;

  /// solid for --, dashed for .., dotted for note connectors.
  final String pattern;
  final String startMultiplicity;
  final String endMultiplicity;
  final String label;
  final bool isNoteLink;

  String get from => start;
  String get to => end;
  bool get dotted => pattern != 'solid';
}

/// An explicit namespace from a class diagram.
class NativeMermaidClassNamespace {
  const NativeMermaidClassNamespace({
    required this.id,
    required this.label,
    this.parent,
  });

  final String id;
  final String label;
  final String? parent;
}

/// A note associated with a class.
class NativeMermaidClassNote {
  const NativeMermaidClassNote({
    required this.id,
    required this.classId,
    required this.text,
  });

  final String id;
  final String classId;
  final String text;
}

/// Synchronous parse result for the supported Mermaid class diagram grammar.
class NativeMermaidClassDiagramData {
  const NativeMermaidClassDiagramData({
    required this.classes,
    required this.relations,
    required this.direction,
    required this.namespaces,
    required this.notes,
  });

  final List<NativeMermaidClassNode> classes;
  final List<NativeMermaidClassRelation> relations;

  /// Mermaid direction token: TB, BT, LR, or RL.
  final String direction;
  final List<NativeMermaidClassNamespace> namespaces;
  final List<NativeMermaidClassNote> notes;

  String get semanticsLabel {
    final pieces = <String>[tr("Class diagram")];
    if (classes.isNotEmpty) {
      pieces.add(
        'Classes: ${classes.map((node) => node.displayLabel).join(', ')}',
      );
    }
    if (relations.isNotEmpty) {
      pieces.add(
        'Relations: ${relations.where((edge) => !edge.isNoteLink).map((edge) {
          final text = edge.label.isEmpty ? '' : ': ${edge.label}';
          return '${edge.start} to ${edge.end}$text';
        }).join('; ')}',
      );
    }
    if (notes.isNotEmpty) {
      pieces.add(
        'Notes: ${notes.map((note) => '${note.classId}: ${note.text}').join('; ')}',
      );
    }
    final value = pieces.join('. ');
    return value.length <= 4000 ? value : '${value.substring(0, 3997)}...';
  }
}

class _MutableClassNode {
  _MutableClassNode(this.id, this.namespace)
    : label = id,
      genericType = '',
      members = <NativeMermaidClassMember>[],
      methods = <NativeMermaidClassMember>[],
      annotations = <String>[];

  final String id;
  final String? namespace;
  String label;
  String genericType;
  final List<NativeMermaidClassMember> members;
  final List<NativeMermaidClassMember> methods;
  final List<String> annotations;

  NativeMermaidClassNode freeze() => NativeMermaidClassNode(
    id: id,
    label: label,
    text: genericType.isEmpty
        ? label
        : '$label&lt;${genericType.replaceAll('<', '&lt;').replaceAll('>', '&gt;')}&gt;',
    genericType: genericType,
    members: List.unmodifiable(members),
    methods: List.unmodifiable(methods),
    annotations: List.unmodifiable(annotations),
    namespace: namespace,
  );
}

class _ParsedIdentifier {
  const _ParsedIdentifier(this.id, this.genericType, this.end);
  final String id;
  final String genericType;
  final int end;
}

class _ParsedQuote {
  const _ParsedQuote(this.value, this.end);
  final String value;
  final int end;
}

class _ParsedMember {
  const _ParsedMember({
    required this.id,
    required this.visibility,
    required this.memberType,
    required this.classifier,
    required this.parameters,
    required this.returnType,
  });

  final String id;
  final String visibility;
  final String memberType;
  final String classifier;
  final String parameters;
  final String returnType;

  NativeMermaidClassMember freeze() {
    final visible = visibility.isEmpty ? '' : r'\' + visibility;
    final raw = memberType == 'method'
        ? '$id($parameters)${returnType.isEmpty ? '' : ' : $returnType'}'
        : id;
    final escaped = raw.replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    return NativeMermaidClassMember(
      text: visible + escaped,
      id: id,
      visibility: visibility,
      memberType: memberType,
      classifier: classifier,
      parameters: parameters,
      returnType: returnType,
    );
  }
}

Never _classDiagramError(int line, String details) {
  throw FormatException(
    tr("Invalid Mermaid class diagram at line {0}: {1}", [line, details]),
  );
}

int _skipSpace(String value, int from) {
  var index = from;
  while (index < value.length && value[index].trim().isEmpty) {
    index++;
  }
  return index;
}

_ParsedQuote? _readClassQuote(String value, int from) {
  final index = _skipSpace(value, from);
  if (index >= value.length || (value[index] != '"' && value[index] != "'")) {
    return null;
  }
  final quote = value[index];
  final result = StringBuffer();
  var cursor = index + 1;
  while (cursor < value.length) {
    final char = value[cursor];
    if (char == r'\') {
      if (cursor + 1 >= value.length) return null;
      result.write(value[cursor + 1]);
      cursor += 2;
    } else if (char == quote) {
      return _ParsedQuote(result.toString(), cursor + 1);
    } else {
      result.write(char);
      cursor++;
    }
  }
  return null;
}

_ParsedIdentifier? _readClassIdentifier(String value, int from) {
  var index = _skipSpace(value, from);
  if (index >= value.length) return null;
  String id;
  if (value[index] == '"' || value[index] == "'") {
    final quoted = _readClassQuote(value, index);
    if (quoted == null || quoted.value.isEmpty) return null;
    id = quoted.value;
    index = quoted.end;
  } else {
    final match = RegExp(
      r'^[A-Za-z0-9_\u0080-\uFFFF][A-Za-z0-9_.\u0080-\uFFFF]*',
    ).firstMatch(value.substring(index));
    if (match == null) return null;
    id = match.group(0)!;
    index += id.length;
  }

  var genericType = '';
  if (index < value.length && value[index] == '~') {
    final close = value.indexOf('~', index + 1);
    if (close < 0) return null;
    genericType = value.substring(index + 1, close).trim();
    if (genericType.isEmpty) return null;
    if (genericType.contains('\n') || genericType.contains('\r')) return null;
    index = close + 1;
  }
  return _ParsedIdentifier(id, genericType, index);
}

String _convertMemberGenerics(String value) {
  return value.replaceAllMapped(
    RegExp(r'~([^~\r\n]+)~'),
    (match) => '<${match.group(1)!.trim()}>',
  );
}

String _trimClassComment(String line, int lineNumber) {
  var quote = '';
  var escaped = false;
  for (var index = 0; index + 1 < line.length; index++) {
    final char = line[index];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (quote.isNotEmpty) {
      if (char.codeUnitAt(0) == 92) {
        escaped = true;
      } else if (char == quote) {
        quote = '';
      }
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
      continue;
    }
    if (line.startsWith('%%', index)) {
      if (line.startsWith('%%{', index)) {
        _classDiagramError(
          lineNumber,
          tr("Mermaid directives are not supported natively"),
        );
      }
      return line.substring(0, index).trimRight();
    }
  }
  return line;
}

void _appendClassMember(_MutableClassNode node, String input, int lineNumber) {
  final member = input.trim();
  if (member.isEmpty) return;
  if (member.startsWith('<<') && member.endsWith('>>')) {
    final annotation = member.substring(2, member.length - 2).trim();
    if (annotation.isEmpty) {
      _classDiagramError(lineNumber, tr("Empty class annotation"));
    }
    node.annotations.add(annotation);
    return;
  }

  final visibility = member.startsWith(RegExp(r'[#+~\-]'))
      ? member.substring(0, 1)
      : '';
  var remainder = visibility.isEmpty ? member : member.substring(1);
  remainder = _convertMemberGenerics(remainder).trim();

  // Mermaid decides a member is a method when it contains a closing paren.
  final closeParen = remainder.lastIndexOf(')');
  if (closeParen > 0 && remainder.substring(0, closeParen).contains('(')) {
    final openParen = remainder.lastIndexOf('(', closeParen);
    var classifier = '';
    var returnType = remainder.substring(closeParen + 1).trim();
    if (returnType.endsWith('*') || returnType.endsWith(r'$')) {
      classifier = returnType.substring(returnType.length - 1);
      returnType = returnType.substring(0, returnType.length - 1).trimRight();
    }
    if (openParen <= 0) {
      _classDiagramError(lineNumber, tr("Malformed class method"));
    }
    final id = remainder.substring(0, openParen).trim();
    final parameters = remainder.substring(openParen + 1, closeParen).trim();
    if (id.isEmpty) _classDiagramError(lineNumber, tr("Method name is empty"));
    node.methods.add(
      _ParsedMember(
        id: _convertMemberGenerics(id),
        visibility: visibility,
        memberType: 'method',
        classifier: classifier,
        parameters: _convertMemberGenerics(parameters),
        returnType: _convertMemberGenerics(returnType),
      ).freeze(),
    );
    return;
  }

  var classifier = '';
  if (remainder.endsWith('*') || remainder.endsWith(r'$')) {
    classifier = remainder.substring(remainder.length - 1);
    remainder = remainder.substring(0, remainder.length - 1).trimRight();
  }
  if (remainder.isEmpty) {
    _classDiagramError(lineNumber, tr("Attribute name is empty"));
  }
  node.members.add(
    _ParsedMember(
      id: remainder,
      visibility: visibility,
      memberType: 'attribute',
      classifier: classifier,
      parameters: '',
      returnType: '',
    ).freeze(),
  );
}

List<String> _splitClassMembers(String value, int lineNumber) {
  final result = <String>[];
  final current = StringBuffer();
  var depth = 0;
  var quote = '';
  var escaped = false;
  for (final char in value.split('')) {
    if (escaped) {
      current.write(char);
      escaped = false;
      continue;
    }
    if (quote.isNotEmpty) {
      current.write(char);
      if (char == r'\') {
        escaped = true;
      } else if (char == quote) {
        quote = '';
      }
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
      current.write(char);
    } else if (char == '(' || char == '<' || char == '~') {
      depth++;
      current.write(char);
    } else if ((char == ')' || char == '>' || char == '~') && depth > 0) {
      depth--;
      current.write(char);
    } else if (char == ';' && depth == 0) {
      result.add(current.toString());
      current.clear();
    } else {
      current.write(char);
    }
  }
  if (quote.isNotEmpty) {
    _classDiagramError(lineNumber, tr("Unclosed quote in member"));
  }
  result.add(current.toString());
  return result;
}

NativeMermaidClassMarker _markerFor(String marker, int lineNumber) {
  return switch (marker.trim()) {
    '' => NativeMermaidClassMarker.none,
    '*' => NativeMermaidClassMarker.composition,
    'o' => NativeMermaidClassMarker.aggregation,
    '<|' || '|>' => NativeMermaidClassMarker.extension,
    '<' || '>' => NativeMermaidClassMarker.dependency,
    '()' => NativeMermaidClassMarker.lollipop,
    _ => throw FormatException(
      tr(
        "Invalid Mermaid class diagram at line {0}: unsupported relation marker {1}",
        [lineNumber, marker],
      ),
    ),
  };
}

class _ParsedRelationOperator {
  const _ParsedRelationOperator(
    this.startMarker,
    this.endMarker,
    this.pattern,
    this.end,
  );
  final NativeMermaidClassMarker startMarker;
  final NativeMermaidClassMarker endMarker;
  final String pattern;
  final int end;
}

_ParsedRelationOperator? _readRelationOperator(
  String value,
  int from,
  int lineNumber,
) {
  final start = _skipSpace(value, from);
  var split = -1;
  var separator = '';
  for (final candidate in ['--', '..']) {
    final at = value.indexOf(candidate, start);
    if (at >= 0 && (split < 0 || at < split)) {
      split = at;
      separator = candidate;
    }
  }
  if (split < 0) return null;

  final prefix = value.substring(start, split).trim();
  final suffix = value.substring(split + separator.length);
  final marker = _readMarkerPrefix(suffix);
  final suffixStart = suffix.length - suffix.trimLeft().length;
  final suffixEnd = suffixStart + marker.$1.length;
  return _ParsedRelationOperator(
    _markerFor(prefix, lineNumber),
    _markerFor(marker.$1, lineNumber),
    separator == '--' ? 'solid' : 'dashed',
    split + separator.length + suffixEnd,
  );
}

(String, int) _readMarkerPrefix(String value) {
  final trimmed = value.trimLeft();
  final offset = value.length - trimmed.length;
  for (final marker in ['<|', '|>', '()', '*', 'o', '>', '<']) {
    if (!trimmed.startsWith(marker)) continue;
    if (marker == 'o' &&
        trimmed.length > 1 &&
        trimmed.substring(1, 2).trim().isNotEmpty) {
      continue;
    }
    return (marker, offset + marker.length);
  }
  return ('', offset);
}

void _parseClassRelation(
  String line,
  int lineNumber,
  _MutableClassNode Function(String, String, int) ensureClass,
  List<NativeMermaidClassRelation> relations,
) {
  final left = _readClassIdentifier(line, 0);
  if (left == null) {
    _classDiagramError(lineNumber, tr("Expected class name"));
  }
  final leftNode = ensureClass(left.id, left.genericType, lineNumber);
  var index = _skipSpace(line, left.end);

  var startMultiplicity = '';
  final firstQuote = _readClassQuote(line, index);
  if (firstQuote != null) {
    startMultiplicity = firstQuote.value;
    index = _skipSpace(line, firstQuote.end);
  }
  final operator = _readRelationOperator(line, index, lineNumber);
  if (operator == null) {
    _classDiagramError(lineNumber, tr("Unknown class statement"));
  }
  index = _skipSpace(line, operator.end);

  var endMultiplicity = '';
  final secondQuote = _readClassQuote(line, index);
  if (secondQuote != null) {
    endMultiplicity = secondQuote.value;
    index = _skipSpace(line, secondQuote.end);
  }
  final right = _readClassIdentifier(line, index);
  if (right == null) {
    _classDiagramError(lineNumber, tr("Expected class name after relation"));
  }
  ensureClass(right.id, right.genericType, lineNumber);
  index = _skipSpace(line, right.end);

  var label = '';
  if (index < line.length) {
    if (line[index] != ':') {
      _classDiagramError(
        lineNumber,
        tr("Unexpected text after class relation"),
      );
    }
    label = line.substring(index + 1).trim();
  }
  relations.add(
    NativeMermaidClassRelation(
      start: leftNode.id,
      end: right.id,
      startMarker: operator.startMarker,
      endMarker: operator.endMarker,
      pattern: operator.pattern,
      startMultiplicity: startMultiplicity,
      endMultiplicity: endMultiplicity,
      label: label,
    ),
  );
}

/// Parses classDiagram/classDiagram-v2 syntax synchronously and fails closed
/// for statements that the native class renderer does not understand.
NativeMermaidClassDiagramData parseNativeMermaidClassDiagram(String source) {
  if (source.length > 50000) {
    throw FormatException(tr("Class diagram exceeds 50000 characters"));
  }
  final lines = source
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  final classes = <String, _MutableClassNode>{};
  final relations = <NativeMermaidClassRelation>[];
  final namespaces = <String, NativeMermaidClassNamespace>{};
  final notes = <NativeMermaidClassNote>[];
  final namespaceStack = <String>[];
  String? bodyClass;
  var headerFound = false;
  var noteIndex = 0;
  var parsedDirection = 'TB';

  _MutableClassNode ensureClass(String id, String genericType, int lineNumber) {
    if (id.isEmpty) {
      _classDiagramError(lineNumber, tr("Class name cannot be empty"));
    }
    final node = classes.putIfAbsent(
      id,
      () => _MutableClassNode(
        id,
        namespaceStack.isEmpty ? null : namespaceStack.join('.'),
      ),
    );
    if (node.genericType.isEmpty && genericType.isNotEmpty) {
      node.genericType = genericType;
    }
    return node;
  }

  void addMembers(_MutableClassNode node, String values, int lineNumber) {
    for (final member in _splitClassMembers(values, lineNumber)) {
      _appendClassMember(node, member, lineNumber);
    }
  }

  late void Function(String statement, int lineNumber) processStatement;

  processStatement = (String rawStatement, int lineNumber) {
    final statement = rawStatement.trim();
    if (statement.isEmpty) return;

    final namespaceMatch = RegExp(
      r'^namespace\s+([A-Za-z0-9_.\-\u0080-\uFFFF]+)\s*\{\s*$',
      caseSensitive: false,
    ).firstMatch(statement);
    if (namespaceMatch != null) {
      final id = namespaceMatch.group(1)!;
      final parent = namespaceStack.isEmpty ? null : namespaceStack.join('.');
      namespaces.putIfAbsent(
        id,
        () => NativeMermaidClassNamespace(
          id: id,
          label: id.split('.').last,
          parent: parent,
        ),
      );
      namespaceStack.add(id);
      return;
    }

    if (statement == '}') {
      if (namespaceStack.isEmpty) {
        _classDiagramError(lineNumber, tr("Unexpected closing brace"));
      }
      namespaceStack.removeLast();
      return;
    }

    final directionMatch = RegExp(
      r'^direction\s+(TB|BT|LR|RL)\s*$',
      caseSensitive: false,
    ).firstMatch(statement);
    if (directionMatch != null) {
      parsedDirection = directionMatch.group(1)!.toUpperCase();
      return;
    }

    final noteMatch = RegExp(
      r'^note\s+for\s+',
      caseSensitive: false,
    ).firstMatch(statement);
    if (noteMatch != null) {
      final target = _readClassIdentifier(statement, noteMatch.end);
      if (target == null) {
        _classDiagramError(
          lineNumber,
          tr("Expected class name after note for"),
        );
      }
      final classNode = ensureClass(target.id, target.genericType, lineNumber);
      final noteStart = _skipSpace(statement, target.end);
      var noteText = '';
      final quote = _readClassQuote(statement, noteStart);
      if (quote != null) {
        noteText = quote.value;
        if (statement.substring(_skipSpace(statement, quote.end)).isNotEmpty) {
          _classDiagramError(lineNumber, tr("Unexpected text after note"));
        }
      } else if (noteStart < statement.length && statement[noteStart] == ':') {
        noteText = statement.substring(noteStart + 1).trim();
      } else {
        _classDiagramError(lineNumber, tr("Expected quoted note text"));
      }
      final noteId = 'note$noteIndex';
      noteIndex++;
      notes.add(
        NativeMermaidClassNote(
          id: noteId,
          classId: classNode.id,
          text: noteText,
        ),
      );
      relations.add(
        NativeMermaidClassRelation(
          start: noteId,
          end: classNode.id,
          startMarker: NativeMermaidClassMarker.none,
          endMarker: NativeMermaidClassMarker.none,
          pattern: 'dotted',
          isNoteLink: true,
        ),
      );
      return;
    }

    if (RegExp(
      r'^(style|classDef|cssClass|click|href|link|callback)\b',
      caseSensitive: false,
    ).hasMatch(statement)) {
      _classDiagramError(
        lineNumber,
        tr("Styling and clickable class directives are not supported natively"),
      );
    }

    if (RegExp(r'^class\s+', caseSensitive: false).hasMatch(statement)) {
      final start = RegExp(
        r'^class\s+',
        caseSensitive: false,
      ).firstMatch(statement)!.end;
      final parsed = _readClassIdentifier(statement, start);
      if (parsed == null) {
        _classDiagramError(lineNumber, tr("Expected class name"));
      }
      final node = ensureClass(parsed.id, parsed.genericType, lineNumber);
      var index = _skipSpace(statement, parsed.end);

      if (index < statement.length && statement[index] == '[') {
        final label = _readClassQuote(statement, index + 1);
        if (label == null) {
          _classDiagramError(lineNumber, tr("Expected quoted class label"));
        }
        index = _skipSpace(statement, label.end);
        if (index >= statement.length || statement[index] != ']') {
          _classDiagramError(
            lineNumber,
            tr("Expected closing bracket after class label"),
          );
        }
        node.label = label.value;
        index = _skipSpace(statement, index + 1);
      }
      final remainder = statement.substring(index).trim();
      if (remainder.startsWith('<<') && remainder.endsWith('>>')) {
        final annotation = remainder.substring(2, remainder.length - 2).trim();
        if (annotation.isEmpty) {
          _classDiagramError(lineNumber, tr("Empty class annotation"));
        }
        node.annotations.add(annotation);
        return;
      }
      if (remainder.startsWith(':')) {
        addMembers(node, remainder.substring(1), lineNumber);
        return;
      }
      if (remainder.isEmpty) return;
      if (!remainder.startsWith('{')) {
        _classDiagramError(
          lineNumber,
          tr("Unsupported class declaration suffix"),
        );
      }
      final content = remainder.substring(1);
      final closing = content.indexOf('}');
      if (closing >= 0) {
        addMembers(node, content.substring(0, closing), lineNumber);
        final trailing = content.substring(closing + 1).trim();
        if (trailing.isNotEmpty) processStatement(trailing, lineNumber);
      } else {
        addMembers(node, content, lineNumber);
        bodyClass = node.id;
      }
      return;
    }

    if (statement.startsWith('note ')) {
      _classDiagramError(
        lineNumber,
        tr("Only notes of the form note for Class are supported"),
      );
    }

    final id = _readClassIdentifier(statement, 0);
    if (id != null) {
      final separator = _skipSpace(statement, id.end);
      if (separator < statement.length && statement[separator] == ':') {
        final node = ensureClass(id.id, id.genericType, lineNumber);
        addMembers(node, statement.substring(separator + 1), lineNumber);
        return;
      }
    }

    _parseClassRelation(statement, lineNumber, ensureClass, relations);
  };

  for (var index = 0; index < lines.length; index++) {
    var line = lines[index].trim();
    if (line.isEmpty) continue;
    if (line.startsWith('%%{')) {
      _classDiagramError(
        index + 1,
        tr("Mermaid directives are not supported natively"),
      );
    }
    if (line.startsWith('%%')) continue;
    line = _trimClassComment(line, index + 1).trim();
    if (line.isEmpty) continue;

    if (!headerFound) {
      if (line != 'classDiagram' && line != 'classDiagram-v2') {
        _classDiagramError(
          index + 1,
          tr("Expected classDiagram or classDiagram-v2 header"),
        );
      }
      headerFound = true;
      continue;
    }

    if (bodyClass != null) {
      final close = line.indexOf('}');
      final node = classes[bodyClass];
      if (node == null) {
        _classDiagramError(index + 1, tr("Class block lost its owner"));
      }
      if (close < 0) {
        addMembers(node, line, index + 1);
      } else {
        addMembers(node, line.substring(0, close), index + 1);
        bodyClass = null;
        final trailing = line.substring(close + 1).trim();
        if (trailing.isNotEmpty) processStatement(trailing, index + 1);
      }
      continue;
    }
    processStatement(line, index + 1);
  }

  if (!headerFound) _classDiagramError(1, tr("Missing class diagram header"));
  if (bodyClass != null) {
    _classDiagramError(lines.length, tr("Unclosed class body"));
  }
  if (namespaceStack.isNotEmpty) {
    _classDiagramError(lines.length, tr("Unclosed namespace"));
  }

  return NativeMermaidClassDiagramData(
    classes: List.unmodifiable(classes.values.map((node) => node.freeze())),
    relations: List.unmodifiable(relations),
    direction: parsedDirection,
    namespaces: List.unmodifiable(namespaces.values),
    notes: List.unmodifiable(notes),
  );
}

/// A laid out class box.
class NativeMermaidClassNodeLayout {
  const NativeMermaidClassNodeLayout({
    required this.node,
    required this.bounds,
    required this.headerHeight,
    required this.attributeStart,
    required this.methodStart,
  });

  final NativeMermaidClassNode node;
  final Rect bounds;
  final double headerHeight;
  final double attributeStart;
  final double methodStart;
}

/// A laid out note box.
class NativeMermaidClassNoteLayout {
  const NativeMermaidClassNoteLayout({
    required this.note,
    required this.bounds,
  });
  final NativeMermaidClassNote note;
  final Rect bounds;
}

/// Layout information for one rendered relationship.
class NativeMermaidClassEdgeLayout {
  const NativeMermaidClassEdgeLayout({
    required this.relation,
    required this.path,
    required this.labelCenter,
    required this.startLabelCenter,
    required this.endLabelCenter,
  });

  final NativeMermaidClassRelation relation;
  final Path path;
  final Offset labelCenter;
  final Offset startLabelCenter;
  final Offset endLabelCenter;
}

/// A namespace backdrop surrounding its classes.
class NativeMermaidClassNamespaceLayout {
  const NativeMermaidClassNamespaceLayout({
    required this.namespace,
    required this.bounds,
  });
  final NativeMermaidClassNamespace namespace;
  final Rect bounds;
}

/// The measurable output of [layoutNativeMermaidClassDiagram].
class NativeMermaidClassDiagramLayout {
  NativeMermaidClassDiagramLayout({
    required this.diagram,
    required this.size,
    required Iterable<NativeMermaidClassNodeLayout> nodes,
    required Iterable<NativeMermaidClassNoteLayout> notes,
    required Iterable<NativeMermaidClassEdgeLayout> edges,
    required Iterable<NativeMermaidClassNamespaceLayout> namespaces,
    required this.fontFamily,
  }) : nodes = List.unmodifiable(nodes),
       notes = List.unmodifiable(notes),
       edges = List.unmodifiable(edges),
       namespaces = List.unmodifiable(namespaces);

  final NativeMermaidClassDiagramData diagram;
  final Size size;
  final List<NativeMermaidClassNodeLayout> nodes;
  final List<NativeMermaidClassNoteLayout> notes;
  final List<NativeMermaidClassEdgeLayout> edges;
  final List<NativeMermaidClassNamespaceLayout> namespaces;
  final String? fontFamily;

  Rect? boundsForClass(String id) {
    for (final node in nodes) {
      if (node.node.id == id) return node.bounds;
    }
    return null;
  }
}

/// Measures and places native class boxes, notes, namespaces, and connectors.
///
/// Directed components are ranked with a cycle-safe SCC condensation. Member
/// row sizes and labeled edge spacing follow the pinned Mermaid 11.17.2 class
/// renderer defaults (13 px text, 19.5 px rows, 50 px rank separation).
NativeMermaidClassDiagramLayout layoutNativeMermaidClassDiagram(
  NativeMermaidClassDiagramData diagram, {
  TextStyle? inheritedTextStyle,
  String? fontFamily,
}) {
  final resolvedFamily = fontFamily ?? inheritedTextStyle?.fontFamily;
  final textStyle = inheritedTextStyle ?? const TextStyle();
  final family = resolvedFamily;
  final ids = diagram.classes.map((node) => node.id).toList();
  final nodesById = {for (final node in diagram.classes) node.id: node};

  final measured = <String, _ClassBoxMetrics>{};
  for (final node in diagram.classes) {
    measured[node.id] = _measureClassBox(node, family, textStyle);
  }

  final classEdges = diagram.relations
      .where(
        (edge) =>
            !edge.isNoteLink &&
            nodesById.containsKey(edge.start) &&
            nodesById.containsKey(edge.end),
      )
      .toList(growable: false);
  final adjacency = <String, List<String>>{
    for (final id in ids) id: <String>[],
  };
  for (final edge in classEdges) {
    adjacency[edge.start]!.add(edge.end);
  }

  final components = _classScc(ids, adjacency);
  final componentOf = <String, int>{};
  for (var index = 0; index < components.length; index++) {
    for (final id in components[index]) {
      componentOf[id] = index;
    }
  }
  final dag = List.generate(components.length, (_) => <int>{});
  final indegree = List.filled(components.length, 0);
  for (final edge in classEdges) {
    final from = componentOf[edge.start]!;
    final to = componentOf[edge.end]!;
    if (from != to && dag[from].add(to)) indegree[to]++;
  }

  final localRank = <String, int>{};
  final componentDepth = List<int>.filled(components.length, 1);
  for (
    var componentIndex = 0;
    componentIndex < components.length;
    componentIndex++
  ) {
    final component = components[componentIndex];
    final queue = <String>[component.first];
    localRank[component.first] = 0;
    for (var cursor = 0; cursor < queue.length; cursor++) {
      final id = queue[cursor];
      for (final to in adjacency[id]!) {
        if (componentOf[to] == componentIndex && !localRank.containsKey(to)) {
          localRank[to] = localRank[id]! + 1;
          queue.add(to);
        }
      }
    }
    var maxDepth = 0;
    for (final id in component) {
      localRank.putIfAbsent(id, () => 0);
      maxDepth = math.max(maxDepth, localRank[id]!).toInt();
    }
    componentDepth[componentIndex] = maxDepth + 1;
  }

  final ready = <int>[
    for (var index = 0; index < indegree.length; index++)
      if (indegree[index] == 0) index,
  ];
  final componentBase = List<int>.filled(components.length, 0);
  for (var cursor = 0; cursor < ready.length; cursor++) {
    final from = ready[cursor];
    for (final to in dag[from]) {
      componentBase[to] = math
          .max(componentBase[to], componentBase[from] + componentDepth[from])
          .toInt();
      if (--indegree[to] == 0) ready.add(to);
    }
  }
  final rank = <String, int>{
    for (final id in ids) id: componentBase[componentOf[id]!] + localRank[id]!,
  };

  final noClassRelations = classEdges.isEmpty;
  final hasNamespaceCluster = diagram.namespaces.isNotEmpty;
  final oneNamespace =
      diagram.classes.isNotEmpty &&
      diagram.classes.first.namespace != null &&
      diagram.classes.every(
        (node) => node.namespace == diagram.classes.first.namespace,
      );
  if (oneNamespace &&
      (diagram.direction == 'TB' || diagram.direction == 'BT')) {
    // Mermaid arranges children of one namespace in its own left-to-right
    // rank, even when the diagram direction is top-to-bottom.
    for (final id in ids) {
      rank[id] = 0;
    }
  } else if (noClassRelations &&
      !hasNamespaceCluster &&
      (diagram.direction == 'TB' || diagram.direction == 'BT')) {
    // Dagre preserves source order as a vertical list for disconnected class
    // boxes in the default class diagram direction.
    for (var index = 0; index < ids.length; index++) {
      rank[ids[index]] = index;
    }
  } else if (noClassRelations &&
      (diagram.direction == 'TB' || diagram.direction == 'BT') &&
      diagram.classes.every((node) => node.namespace != null)) {
    final byNamespace = <String, List<String>>{};
    for (final node in diagram.classes) {
      (byNamespace[node.namespace!] ??= <String>[]).add(node.id);
    }
    var next = 0;
    for (final group in byNamespace.values) {
      for (final id in group) {
        rank[id] = next;
      }
      next++;
    }
  }

  final sideNotesByClass = <String, List<NativeMermaidClassNote>>{};
  final noteMetrics = <String, Size>{
    for (final note in diagram.notes)
      note.id: _measureNote(note.text, family, textStyle),
  };
  if (diagram.direction == 'TB' || diagram.direction == 'BT') {
    for (final note in diagram.notes) {
      if (classEdges.any(
        (edge) => edge.start == note.classId || edge.end == note.classId,
      )) {
        (sideNotesByClass[note.classId] ??= <NativeMermaidClassNote>[]).add(
          note,
        );
      }
    }
  }

  final layers = <int, List<String>>{};
  for (final id in ids) {
    (layers[rank[id]!] ??= <String>[]).add(id);
  }
  final rankValues = layers.keys.toList()..sort();
  final vertical = diagram.direction == 'TB' || diagram.direction == 'BT';
  final depthSizes = <int, double>{};
  final crossSizes = <int, double>{};
  var crossMaximum = 0.0;
  final siblingGap = oneNamespace && vertical ? 100.0 : 50.0;
  for (final layerRank in rankValues) {
    final layer = layers[layerRank]!;
    var depth = 0.0;
    var cross = 0.0;
    for (final id in layer) {
      final size = measured[id]!.size;
      depth = math.max(depth, vertical ? size.height : size.width).toDouble();
      cross += vertical ? size.width : size.height;
    }
    cross += siblingGap * math.max(0, layer.length - 1);
    for (final id in layer) {
      for (final note
          in sideNotesByClass[id] ?? const <NativeMermaidClassNote>[]) {
        cross += noteMetrics[note.id]!.width + 50;
      }
    }
    depthSizes[layerRank] = depth;
    crossSizes[layerRank] = cross;
    crossMaximum = math.max(crossMaximum, cross).toDouble();
  }

  final rankGap = <int, double>{};
  for (final layerRank in rankValues) {
    var extra = 0.0;
    for (final edge in classEdges.where(
      (edge) =>
          rank[edge.start] == layerRank &&
          rank[edge.end]! > layerRank &&
          edge.label.isNotEmpty,
    )) {
      final label = _classTextPainter(
        edge.label,
        _classLabelStyle(family, textStyle, bold: false),
      )..layout();
      extra = math.max(extra, vertical ? label.height : label.width).toDouble();
      label.dispose();
    }
    rankGap[layerRank] = 50 + extra;
  }

  var depthExtent = 16.0;
  final maxRank = rankValues.isEmpty ? -1 : rankValues.last;
  final centersAlong = <int, double>{};
  var depthCursor = 8.0;
  for (var layerRank = 0; layerRank <= maxRank; layerRank++) {
    final depth = depthSizes[layerRank] ?? 0;
    centersAlong[layerRank] = depthCursor + depth / 2;
    depthCursor += depth;
    if (layerRank < maxRank) {
      depthCursor += rankGap[layerRank] ?? 50;
    }
  }
  depthExtent = depthCursor + 8;

  final centers = <String, Offset>{};
  final noteBounds = <String, Rect>{};
  for (final layerRank in rankValues) {
    final layer = layers[layerRank]!;
    final crossSize = crossSizes[layerRank]!;
    var crossCursor = 8 + (crossMaximum - crossSize) / 2;
    for (final id in layer) {
      for (final note
          in sideNotesByClass[id] ?? const <NativeMermaidClassNote>[]) {
        final noteSize = noteMetrics[note.id]!;
        final noteCenter = Offset(
          crossCursor + noteSize.width / 2,
          centersAlong[layerRank]!,
        );
        noteBounds[note.id] = Rect.fromCenter(
          center: noteCenter,
          width: noteSize.width,
          height: noteSize.height,
        );
        crossCursor += noteSize.width + 50;
      }
      final size = measured[id]!.size;
      final crossDimension = vertical ? size.width : size.height;
      final crossCenter = crossCursor + crossDimension / 2;
      final alongCenter = centersAlong[layerRank]!;
      final point = switch (diagram.direction) {
        'BT' => Offset(crossCenter, depthExtent - alongCenter),
        'RL' => Offset(depthExtent - alongCenter, crossCenter),
        'LR' => Offset(alongCenter, crossCenter),
        _ => Offset(crossCenter, alongCenter),
      };
      centers[id] = point;
      crossCursor += crossDimension + siblingGap;
    }
  }

  // Align a singleton parent rank with the mean cross-axis position of its
  // immediate later-rank children, as the class dagre layout does.
  for (final layerRank in rankValues.reversed) {
    final layer = layers[layerRank]!;
    if (layer.length != 1) continue;
    final id = layer.single;
    if ((sideNotesByClass[id] ?? const <NativeMermaidClassNote>[]).isNotEmpty) {
      continue;
    }
    final childCenters = classEdges
        .where((edge) => edge.start == id && rank[edge.end]! > layerRank)
        .map((edge) => centers[edge.end]!)
        .toList(growable: false);
    if (childCenters.isEmpty) continue;
    final average =
        childCenters
            .map((point) => vertical ? point.dx : point.dy)
            .reduce((a, b) => a + b) /
        childCenters.length;
    final previous = centers[id]!;
    centers[id] = vertical
        ? Offset(average, previous.dy)
        : Offset(previous.dx, average);
  }

  final classBounds = <String, Rect>{
    for (final node in diagram.classes)
      node.id: Rect.fromCenter(
        center: centers[node.id]!,
        width: measured[node.id]!.size.width,
        height: measured[node.id]!.size.height,
      ),
  };

  for (var index = 0; index < diagram.notes.length; index++) {
    final note = diagram.notes[index];
    if ((sideNotesByClass[note.classId] ?? const <NativeMermaidClassNote>[])
        .any((sideNote) => sideNote.id == note.id)) {
      continue;
    }
    final anchor = classBounds[note.classId];
    if (anchor == null) continue;
    final size = noteMetrics[note.id]!;
    final targetHasEdges = classEdges.any(
      (edge) => edge.start == note.classId || edge.end == note.classId,
    );
    Rect bounds;
    if (targetHasEdges && vertical) {
      bounds = Rect.fromCenter(
        center: Offset(anchor.left - 50 - size.width / 2, anchor.center.dy),
        width: size.width,
        height: size.height,
      );
    } else {
      bounds = Rect.fromCenter(
        center: Offset(anchor.center.dx, anchor.top - 32 - size.height / 2),
        width: size.width,
        height: size.height,
      );
    }
    // Multiple notes on one class are placed progressively to the left.
    if (targetHasEdges && vertical && index > 0) {
      bounds = bounds.shift(Offset(-index * (size.width + 24), 0));
    }
    noteBounds[note.id] = bounds;
  }

  var extents = Rect.zero;
  var hasExtent = false;
  void include(Rect rect) {
    extents = hasExtent ? extents.expandToInclude(rect) : rect;
    hasExtent = true;
  }

  final rawNamespaceBounds = <String, Rect>{};
  for (final namespace in diagram.namespaces) {
    final members = diagram.classes
        .where(
          (node) =>
              node.namespace == namespace.id &&
              classBounds.containsKey(node.id),
        )
        .map((node) => classBounds[node.id]!)
        .toList(growable: false);
    if (members.isEmpty) continue;
    final memberBounds = members.reduce((a, b) => a.expandToInclude(b));
    final groupBounds = Rect.fromLTRB(
      memberBounds.left - 40,
      memberBounds.top - 35,
      memberBounds.right + 40,
      memberBounds.bottom + 35,
    );
    rawNamespaceBounds[namespace.id] = groupBounds;
    include(groupBounds);
  }
  for (final rect in classBounds.values) {
    include(rect);
  }
  for (final rect in noteBounds.values) {
    include(rect);
  }
  if (!hasExtent) {
    extents = const Rect.fromLTWH(0, 0, 0, 0);
  }
  final dx = 8 - extents.left;
  final dy = 8 - extents.top;
  for (final id in classBounds.keys.toList()) {
    classBounds[id] = classBounds[id]!.shift(Offset(dx, dy));
  }
  for (final id in noteBounds.keys.toList()) {
    noteBounds[id] = noteBounds[id]!.shift(Offset(dx, dy));
  }
  extents = extents.shift(Offset(dx, dy));
  final size = Size(extents.right + 8, extents.bottom + 8);

  final edgeLayouts = <NativeMermaidClassEdgeLayout>[];
  for (final relation in diagram.relations) {
    final from = noteBounds[relation.start] ?? classBounds[relation.start];
    final to = noteBounds[relation.end] ?? classBounds[relation.end];
    if (from == null || to == null) continue;
    final path = _classRelationPath(from, to, relation, diagram.direction);
    final metrics = path.computeMetrics().toList(growable: false);
    final metric = metrics.isEmpty ? null : metrics.first;
    final length = metric?.length ?? 0;
    final middle =
        metric?.getTangentForOffset(length / 2)?.position ??
        Offset(
          (from.center.dx + to.center.dx) / 2,
          (from.center.dy + to.center.dy) / 2,
        );
    final startPoint =
        metric?.getTangentForOffset(math.min(length, 18))?.position ??
        from.center;
    final endPoint =
        metric?.getTangentForOffset(math.max(0, length - 18))?.position ??
        to.center;
    edgeLayouts.add(
      NativeMermaidClassEdgeLayout(
        relation: relation,
        path: path,
        labelCenter: middle,
        startLabelCenter: startPoint,
        endLabelCenter: endPoint,
      ),
    );
  }

  final nodeLayouts = <NativeMermaidClassNodeLayout>[
    for (final node in diagram.classes)
      NativeMermaidClassNodeLayout(
        node: node,
        bounds: classBounds[node.id]!,
        headerHeight: measured[node.id]!.headerHeight,
        attributeStart: measured[node.id]!.attributeStart,
        methodStart: measured[node.id]!.methodStart,
      ),
  ];
  final noteLayouts = <NativeMermaidClassNoteLayout>[
    for (final note in diagram.notes)
      if (noteBounds.containsKey(note.id))
        NativeMermaidClassNoteLayout(note: note, bounds: noteBounds[note.id]!),
  ];

  final namespaceLayouts = <NativeMermaidClassNamespaceLayout>[
    for (final namespace in diagram.namespaces)
      if (rawNamespaceBounds.containsKey(namespace.id))
        NativeMermaidClassNamespaceLayout(
          namespace: namespace,
          bounds: rawNamespaceBounds[namespace.id]!.shift(Offset(dx, dy)),
        ),
  ];

  return NativeMermaidClassDiagramLayout(
    diagram: diagram,
    size: size,
    nodes: nodeLayouts,
    notes: noteLayouts,
    edges: edgeLayouts,
    namespaces: namespaceLayouts,
    fontFamily: family,
  );
}

class _ClassBoxMetrics {
  const _ClassBoxMetrics({
    required this.size,
    required this.headerHeight,
    required this.attributeStart,
    required this.methodStart,
  });

  final Size size;
  final double headerHeight;
  final double attributeStart;
  final double methodStart;
}

TextStyle _classLabelStyle(
  String? family,
  TextStyle inherited, {
  bool bold = false,
  bool italic = false,
  bool underline = false,
}) {
  return TextStyle(
    fontFamily: family,
    fontSize: 13,
    height: 1.5,
    letterSpacing: 0,
    color: inherited.color,
    fontWeight: bold ? FontWeight.w700 : FontWeight.normal,
    fontStyle: italic ? FontStyle.italic : FontStyle.normal,
    decoration: underline ? TextDecoration.underline : TextDecoration.none,
  );
}

TextPainter _classTextPainter(
  String value,
  TextStyle style, {
  TextAlign align = TextAlign.left,
}) {
  return TextPainter(
    text: TextSpan(text: value.isEmpty ? ' ' : value, style: style),
    textDirection: TextDirection.ltr,
    textAlign: align,
  );
}

_ClassBoxMetrics _measureClassBox(
  NativeMermaidClassNode node,
  String? family,
  TextStyle inherited,
) {
  double measure(String text, {bool bold = false, bool italic = false}) {
    final painter = _classTextPainter(
      text,
      _classLabelStyle(family, inherited, bold: bold, italic: italic),
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  final annotation = node.annotations.isEmpty ? null : node.annotations.first;
  final headerHalf =
      math.max(
        measure(node.displayLabel, bold: true),
        annotation == null ? 0.0 : measure('«$annotation»'),
      ) /
      2;
  var bodyWidth = 0.0;
  for (final member in [...node.members, ...node.methods]) {
    bodyWidth = math.max(
      bodyWidth,
      measure(member.displayText, italic: member.isAbstract),
    );
  }
  // shapeUtil.ts measures the union before classBox.ts repositions labels:
  // centered header groups extend left of zero, while body groups start at
  // zero. classBox then adds 12px padding on each side of that union.
  final width = headerHalf + math.max(headerHalf, bodyWidth) + 24;
  final headerHeight = 43.5 + (annotation == null ? 0 : 19.5);

  final attributeRows = node.members.length;
  final methodRows = node.methods.length;
  final attributeHeight = attributeRows > 0
      ? 24 + 19.5 * attributeRows
      : methodRows > 0
      ? 24.0
      : 18.0;
  final methodHeight = methodRows > 0
      ? 24 + 19.5 * methodRows + (attributeRows == 0 ? 6 : 0)
      : attributeRows > 0
      ? 24.0
      : 18.0;
  return _ClassBoxMetrics(
    size: Size(width, headerHeight + attributeHeight + methodHeight),
    headerHeight: headerHeight,
    attributeStart: headerHeight,
    methodStart: headerHeight + attributeHeight,
  );
}

Size _measureNote(String text, String? family, TextStyle inherited) {
  final painter = _classTextPainter(text, _classLabelStyle(family, inherited))
    ..layout();
  final lines = math.max(1, text.split('\n').length);
  final size = Size(painter.width + 12, math.max(31.5, 19.5 * lines + 12));
  painter.dispose();
  return size;
}

List<List<String>> _classScc(
  List<String> nodes,
  Map<String, List<String>> adjacency,
) {
  var nextIndex = 0;
  final indices = <String, int>{};
  final low = <String, int>{};
  final stack = <String>[];
  final onStack = <String>{};
  final components = <List<String>>[];
  void visit(String id) {
    indices[id] = nextIndex;
    low[id] = nextIndex;
    nextIndex++;
    stack.add(id);
    onStack.add(id);
    for (final target in adjacency[id]!) {
      if (!indices.containsKey(target)) {
        visit(target);
        low[id] = math.min(low[id]!, low[target]!).toInt();
      } else if (onStack.contains(target)) {
        low[id] = math.min(low[id]!, indices[target]!).toInt();
      }
    }
    if (low[id] == indices[id]) {
      final component = <String>[];
      late String current;
      do {
        current = stack.removeLast();
        onStack.remove(current);
        component.add(current);
      } while (current != id);
      components.add(component);
    }
  }

  for (final id in nodes) {
    if (!indices.containsKey(id)) visit(id);
  }
  return components;
}

Path _classRelationPath(
  Rect start,
  Rect end,
  NativeMermaidClassRelation edge,
  String direction,
) {
  final vector = end.center - start.center;
  if (vector.distance < 0.01) {
    return Path()
      ..moveTo(start.center.dx, start.center.dy)
      ..lineTo(start.center.dx + 24, start.center.dy + 24);
  }
  final from = _classRectIntersection(start, vector);
  final to = _classRectIntersection(end, -vector);
  final verticalRank = direction == 'TB' || direction == 'BT';
  final sameRank = verticalRank
      ? (start.center.dy - end.center.dy).abs() < 1
      : (start.center.dx - end.center.dx).abs() < 1;
  if (sameRank) {
    final movesAcross = vector.dx.abs() >= vector.dy.abs();
    final sign = movesAcross
        ? (vector.dx >= 0 ? 1.0 : -1.0)
        : (vector.dy >= 0 ? 1.0 : -1.0);
    final offset = movesAcross ? Offset(0, sign * 30) : Offset(sign * 30, 0);
    return Path()
      ..moveTo(from.dx, from.dy)
      ..cubicTo(
        from.dx + offset.dx,
        from.dy + offset.dy,
        to.dx - offset.dx,
        to.dy - offset.dy,
        to.dx,
        to.dy,
      );
  }
  final control1 = Offset(
    from.dx + (to.dx - from.dx) * 0.42,
    from.dy + (to.dy - from.dy) * 0.42,
  );
  final control2 = Offset(
    from.dx + (to.dx - from.dx) * 0.58,
    from.dy + (to.dy - from.dy) * 0.58,
  );
  return Path()
    ..moveTo(from.dx, from.dy)
    ..cubicTo(control1.dx, control1.dy, control2.dx, control2.dy, to.dx, to.dy);
}

Offset _classRectIntersection(Rect rect, Offset direction) {
  final dx = direction.dx == 0 && direction.dy == 0 ? 1.0 : direction.dx;
  final dy = direction.dx == 0 && direction.dy == 0 ? 0.0 : direction.dy;
  final sx = dx == 0 ? double.infinity : rect.width / 2 / dx.abs();
  final sy = dy == 0 ? double.infinity : rect.height / 2 / dy.abs();
  final scale = math.min(sx, sy);
  return rect.center + Offset(dx * scale, dy * scale);
}

/// Native Flutter renderer for parsed Mermaid class diagrams.
class NativeMermaidClassDiagram extends StatelessWidget {
  const NativeMermaidClassDiagram({
    super.key,
    required this.source,
    required this.dark,
  });

  final String source;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    final inherited = DefaultTextStyle.of(context).style;
    final diagram = parseNativeMermaidClassDiagram(source);
    final layout = layoutNativeMermaidClassDiagram(
      diagram,
      inheritedTextStyle: inherited,
      fontFamily: inherited.fontFamily,
    );
    final chart = SizedBox(
      key: const ValueKey('native-mermaid-class-diagram'),
      width: layout.size.width,
      height: layout.size.height,
      child: CustomPaint(painter: _NativeMermaidClassPainter(layout, dark)),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final Widget fitted =
            constraints.hasBoundedWidth &&
                constraints.maxWidth < layout.size.width
            ? FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.topLeft,
                child: chart,
              )
            : Align(alignment: Alignment.topCenter, child: chart);
        return Semantics(
          image: true,
          label: diagram.semanticsLabel,
          child: fitted,
        );
      },
    );
  }
}

class _NativeMermaidClassPainter extends CustomPainter {
  const _NativeMermaidClassPainter(this.layout, this.dark);
  final NativeMermaidClassDiagramLayout layout;
  final bool dark;

  Color get line => dark ? const Color(0xffd3d3d3) : const Color(0xff81858c);
  Color get classFill =>
      dark ? const Color(0xff1f2020) : const Color(0xffedf3fe);
  Color get classBorder =>
      dark ? const Color(0xffcccccc) : const Color(0xff4176e6);
  Color get ink => dark ? const Color(0xffe0dfdf) : const Color(0xff0f1115);
  Color get namespaceFill =>
      dark ? const Color(0xff474949) : const Color(0xfff9fafb);
  Color get namespaceBorder =>
      dark ? const Color(0x40ffffff) : const Color(0xffe1e1e1);
  Color get noteFill =>
      dark ? const Color(0xff474949) : const Color(0xfffff5ad);
  Color get noteBorder =>
      dark ? const Color(0xff2f2f2f) : const Color(0xffe4db95);

  TextPainter _painter(
    String text, {
    bool bold = false,
    bool italic = false,
    bool underline = false,
    Color? color,
    TextAlign align = TextAlign.left,
  }) {
    return _classTextPainter(
      text,
      TextStyle(
        fontFamily: layout.fontFamily,
        fontSize: 13,
        height: 1.5,
        letterSpacing: 0,
        color: color ?? ink,
        fontWeight: bold ? FontWeight.w700 : FontWeight.normal,
        fontStyle: italic ? FontStyle.italic : FontStyle.normal,
        decoration: underline ? TextDecoration.underline : TextDecoration.none,
      ),
      align: align,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final group in layout.namespaces) {
      canvas.drawRect(group.bounds, Paint()..color = namespaceFill);
      canvas.drawRect(
        group.bounds,
        Paint()
          ..color = namespaceBorder
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      final label = _painter(
        group.namespace.label,
        bold: true,
        align: TextAlign.center,
      )..layout();
      label.paint(
        canvas,
        Offset(group.bounds.center.dx - label.width / 2, group.bounds.top + 4),
      );
      label.dispose();
    }

    for (final edge in layout.edges) {
      _paintClassEdge(canvas, edge);
    }

    for (final note in layout.notes) {
      final rect = note.bounds;
      canvas.drawRect(rect, Paint()..color = noteFill);
      canvas.drawRect(
        rect,
        Paint()
          ..color = noteBorder
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3,
      );
      final lines = note.note.text.split('\n');
      final height = lines.length * 19.5;
      var y = rect.center.dy - height / 2;
      for (final lineText in lines) {
        final text = _painter(
          lineText,
          align: TextAlign.center,
          color: dark ? const Color(0xffb8b6b6) : const Color(0xff333333),
        )..layout();
        text.paint(canvas, Offset(rect.center.dx - text.width / 2, y));
        y += 19.5;
        text.dispose();
      }
    }

    for (final node in layout.nodes) {
      _paintClassBox(canvas, node);
    }
  }

  void _paintClassBox(Canvas canvas, NativeMermaidClassNodeLayout item) {
    final rect = item.bounds;
    canvas.drawRect(rect, Paint()..color = classFill);
    final borderPaint = Paint()
      ..color = classBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(rect, borderPaint);

    final separatorYs = <double>[
      rect.top + item.headerHeight,
      rect.top + item.methodStart,
    ];
    if (item.node.members.isNotEmpty && item.node.methods.isNotEmpty) {
      separatorYs.insert(1, rect.top + item.methodStart);
    }
    for (final y in separatorYs.toSet()) {
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), borderPaint);
    }

    final annotations = item.node.annotations.take(1).toList();
    var headerY = rect.top + 14.25;
    for (final annotation in annotations) {
      final painter = _painter('«$annotation»', align: TextAlign.center)
        ..layout();
      painter.paint(
        canvas,
        Offset(rect.center.dx - painter.width / 2, headerY),
      );
      headerY += 19.5;
      painter.dispose();
    }
    final title = _painter(
      item.node.displayLabel,
      bold: true,
      align: TextAlign.center,
    )..layout();
    title.paint(
      canvas,
      Offset(
        rect.center.dx - title.width / 2,
        rect.top + 14.25 + annotations.length * 19.5,
      ),
    );
    title.dispose();

    var attributeY = rect.top + item.attributeStart + 14.25;
    for (final member in item.node.members) {
      _paintMember(canvas, member, rect.left + 12, attributeY);
      attributeY += 19.5;
    }
    // textHelper uses GAP/2 (6px) for empty members when placing methods;
    // the divider itself measures the actual empty group's zero height.
    var methodY =
        rect.top +
        item.methodStart +
        14.25 +
        (item.node.members.isEmpty ? 6 : 0);
    for (final member in item.node.methods) {
      _paintMember(canvas, member, rect.left + 12, methodY);
      methodY += 19.5;
    }
  }

  void _paintMember(
    Canvas canvas,
    NativeMermaidClassMember member,
    double x,
    double y,
  ) {
    final painter = _painter(
      member.displayText,
      italic: member.isAbstract,
      underline: member.isStatic,
    )..layout();
    painter.paint(canvas, Offset(x, y));
    painter.dispose();
  }

  void _paintClassEdge(Canvas canvas, NativeMermaidClassEdgeLayout item) {
    final relation = item.relation;
    final paint = Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.butt;
    final metrics = item.path.computeMetrics().toList(growable: false);
    double clearance(NativeMermaidClassMarker marker) => switch (marker) {
      NativeMermaidClassMarker.extension ||
      NativeMermaidClassMarker.composition ||
      NativeMermaidClassMarker.aggregation => 17,
      NativeMermaidClassMarker.lollipop => 12,
      NativeMermaidClassMarker.dependency => 5,
      NativeMermaidClassMarker.none => 0,
    };
    // Hollow markers are transparent in SVG; shorten the connector instead
    // of letting its stroke run through the marker's interior.
    final linePath = Path();
    for (final metric in metrics) {
      final start = math.min(metric.length, clearance(relation.startMarker));
      final end = math.max(
        start,
        metric.length - clearance(relation.endMarker),
      );
      linePath.addPath(metric.extractPath(start, end), Offset.zero);
    }
    _drawClassPath(
      canvas,
      linePath,
      paint,
      relation.pattern == 'dashed' || relation.pattern == 'dotted',
    );
    if (metrics.isNotEmpty) {
      final metric = metrics.first;
      final startTangent = metric.getTangentForOffset(0);
      final endTangent = metric.getTangentForOffset(metric.length);
      final pathStart = startTangent?.position;
      final pathEnd = endTangent?.position;
      if (pathStart != null) {
        _paintRelationMarker(
          canvas,
          pathStart,
          -startTangent!.vector,
          relation.startMarker,
          start: true,
        );
      }
      if (pathEnd != null) {
        _paintRelationMarker(
          canvas,
          pathEnd,
          endTangent!.vector,
          relation.endMarker,
          start: false,
        );
      }
    }
    if (relation.label.isNotEmpty) {
      _paintEdgeText(canvas, relation.label, item.labelCenter);
    }
    if (relation.startMultiplicity.isNotEmpty) {
      _paintEdgeText(canvas, relation.startMultiplicity, item.startLabelCenter);
    }
    if (relation.endMultiplicity.isNotEmpty) {
      _paintEdgeText(canvas, relation.endMultiplicity, item.endLabelCenter);
    }
  }

  void _drawClassPath(Canvas canvas, Path path, Paint paint, bool dashed) {
    if (!dashed) {
      canvas.drawPath(path, paint);
      return;
    }
    for (final metric in path.computeMetrics()) {
      var offset = 0.0;
      var draw = true;
      while (offset < metric.length) {
        final segmentEnd = math.min(offset + (draw ? 5.0 : 4.0), metric.length);
        if (draw) {
          canvas.drawPath(metric.extractPath(offset, segmentEnd), paint);
        }
        offset = segmentEnd;
        draw = !draw;
      }
    }
  }

  void _paintEdgeText(Canvas canvas, String label, Offset center) {
    final painter = _painter(label, align: TextAlign.center)..layout();
    final bounds = Rect.fromCenter(
      center: center,
      width: painter.width + 4,
      height: painter.height + 2,
    );
    canvas.drawRect(bounds, Paint()..color = dark ? classFill : Colors.white);
    painter.paint(
      canvas,
      Offset(center.dx - painter.width / 2, center.dy - painter.height / 2),
    );
    painter.dispose();
  }

  void _paintRelationMarker(
    Canvas canvas,
    Offset tip,
    Offset direction,
    NativeMermaidClassMarker marker, {
    required bool start,
  }) {
    if (marker == NativeMermaidClassMarker.none) return;
    final unitLength = direction.distance;
    if (unitLength == 0) return;
    final unit = direction / unitLength;
    final normal = Offset(-unit.dy, unit.dx);
    // Pinned markers.js uses a 17×12 extension/diamond and a 9×12 barb.
    final length = marker == NativeMermaidClassMarker.dependency ? 9.0 : 17.0;
    const halfWidth = 6.0;
    final base = tip - unit * length;
    final left = base + normal * halfWidth;
    final right = base - normal * halfWidth;
    final outline = Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    if (marker == NativeMermaidClassMarker.extension) {
      final triangle = Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(left.dx, left.dy)
        ..lineTo(right.dx, right.dy)
        ..close();
      canvas.drawPath(triangle, outline);
      return;
    }
    if (marker == NativeMermaidClassMarker.composition ||
        marker == NativeMermaidClassMarker.aggregation) {
      final center = tip - unit * (start ? 8 : 9);
      final nearLeft = center + normal * 6;
      final far = tip - unit * 17;
      final nearRight = center - normal * 6;
      final diamond = Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(nearLeft.dx, nearLeft.dy)
        ..lineTo(far.dx, far.dy)
        ..lineTo(nearRight.dx, nearRight.dy)
        ..close();
      if (marker == NativeMermaidClassMarker.composition) {
        canvas.drawPath(diamond, Paint()..color = line);
      }
      canvas.drawPath(diamond, outline);
      return;
    }
    if (marker == NativeMermaidClassMarker.lollipop) {
      canvas.drawCircle(tip - unit * 6, 6, outline);
      return;
    }
    final barb = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(left.dx, left.dy)
      ..lineTo((tip - unit * 4).dx, (tip - unit * 4).dy)
      ..lineTo(right.dx, right.dy)
      ..close();
    canvas.drawPath(barb, Paint()..color = line);
    canvas.drawPath(barb, outline);
  }

  @override
  bool shouldRepaint(covariant _NativeMermaidClassPainter oldDelegate) =>
      oldDelegate.layout != layout || oldDelegate.dark != dark;
}
