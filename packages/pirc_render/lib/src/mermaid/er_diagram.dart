import '../render_l10n.dart';

class NativeMermaidErAttribute {
  const NativeMermaidErAttribute({
    required this.type,
    required this.name,
    this.keys = const <String>[],
    this.comment = '',
  });
  final String type;
  final String name;
  final List<String> keys;
  final String comment;
}

class NativeMermaidErEntity {
  const NativeMermaidErEntity({
    required this.id,
    required this.name,
    required this.label,
    required this.alias,
    required this.attributes,
  });
  final String id;
  final String name;
  final String label;
  final String alias;
  final List<NativeMermaidErAttribute> attributes;
  String get displayLabel => alias.isNotEmpty ? alias : label;
}

class NativeMermaidErRelationship {
  const NativeMermaidErRelationship({
    required this.entityA,
    required this.roleA,
    required this.entityB,
    required this.cardA,
    required this.cardB,
    required this.relType,
  });
  final String entityA;
  final String roleA;
  final String entityB;
  final String cardA;
  final String cardB;
  final String relType;
  String get pattern => relType == 'IDENTIFYING' ? 'solid' : 'dashed';
}

class NativeMermaidErDiagramData {
  const NativeMermaidErDiagramData({
    required this.entities,
    required this.relationships,
    required this.direction,
    required this.accessibleTitle,
    required this.accessibleDescription,
  });
  final List<NativeMermaidErEntity> entities;
  final List<NativeMermaidErRelationship> relationships;
  final String direction;
  final String accessibleTitle;
  final String accessibleDescription;

  String get semanticsLabel {
    final parts = <String>[tr("Entity relationship diagram")];
    if (entities.isNotEmpty) {
      parts.add(
        'Entities: ${entities.map((item) => item.displayLabel).join(', ')}',
      );
    }
    if (relationships.isNotEmpty) {
      final names = <String, String>{
        for (final entity in entities) entity.id: entity.displayLabel,
      };
      parts.add(
        'Relationships: ${relationships.map((edge) {
          final role = edge.roleA.isEmpty ? '' : ': ${edge.roleA}';
          return '${names[edge.entityA] ?? edge.entityA} relates to '
              '${names[edge.entityB] ?? edge.entityB}$role';
        }).join('; ')}',
      );
    }
    if (accessibleTitle.isNotEmpty) parts.add('Title: $accessibleTitle');
    if (accessibleDescription.isNotEmpty) {
      parts.add('Description: $accessibleDescription');
    }
    final value = parts.join('. ');
    return value.length <= 4000 ? value : '${value.substring(0, 3997)}...';
  }
}

class _ErEntityBuilder {
  _ErEntityBuilder(this.name, int index, [this.alias = ''])
    : id = 'entity-$name-$index';
  final String name;
  final String id;
  String alias;
  final List<NativeMermaidErAttribute> attributes = [];
  NativeMermaidErEntity freeze() => NativeMermaidErEntity(
    id: id,
    name: name,
    label: name,
    alias: alias,
    attributes: List.unmodifiable(attributes),
  );
}

class _Token {
  const _Token(this.text, this.end);
  final String text;
  final int end;
}

class _Relation {
  const _Relation(
    this.left,
    this.cardB,
    this.right,
    this.cardA,
    this.op,
    this.role,
  );
  final String left;
  final String cardB;
  final String right;
  final String cardA;
  final String op;
  final String role;
}

NativeMermaidErDiagramData parseNativeMermaidErDiagram(String source) {
  if (source.length > 50000) {
    throw FormatException(tr("ER diagram exceeds 50000 characters"));
  }
  final lines = source
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  final entities = <String, _ErEntityBuilder>{};
  final edges = <NativeMermaidErRelationship>[];
  var hasHeader = false;
  var direction = 'TB';
  var accTitle = '';
  var accDescription = '';
  var inDescription = false;
  _ErEntityBuilder? activeEntity;

  Never invalid(int line, String message) => throw FormatException(
    tr("Invalid Mermaid ER diagram at line {0}: {1}", [line, message]),
  );

  _ErEntityBuilder ensure(String name, [String alias = '']) {
    final old = entities[name];
    if (old != null) {
      if (old.alias.isEmpty && alias.isNotEmpty) old.alias = alias;
      return old;
    }
    if (name.isEmpty) throw FormatException(tr("Empty ER entity name"));
    final value = _ErEntityBuilder(name, entities.length, alias);
    entities[name] = value;
    return value;
  }

  for (var i = 0; i < lines.length; i++) {
    final number = i + 1;
    final line = _stripErComment(
      lines[i],
      number,
      allowUnclosedQuote: inDescription,
    ).trim();
    if (line.isEmpty) continue;
    if (inDescription) {
      if (line == '}') {
        inDescription = false;
      } else {
        accDescription = accDescription.isEmpty
            ? line
            : '$accDescription\n$line';
      }
      continue;
    }
    if (_outside(line, ';') >= 0) {
      invalid(
        number,
        tr("Unquoted semicolons are not supported by the pinned ER grammar"),
      );
    }
    if (!hasHeader) {
      if (line.toLowerCase() != 'erdiagram') {
        invalid(number, tr("Expected erDiagram header"));
      }
      hasHeader = true;
      continue;
    }
    if (line.startsWith('%%{')) {
      invalid(number, tr("Mermaid directives are unsupported"));
    }

    if (activeEntity != null) {
      if (line == '}') {
        activeEntity = null;
        continue;
      }
      final endBrace = _outside(line, '}');
      if (endBrace >= 0) {
        final value = line.substring(0, endBrace).trim();
        if (value.isNotEmpty) {
          for (final part in _splitAttributes(value)) {
            activeEntity.attributes.add(_parseAttribute(part, number));
          }
        }
        if (line.substring(endBrace + 1).trim().isNotEmpty) {
          invalid(number, tr("Unexpected text after entity block"));
        }
        activeEntity = null;
      } else {
        for (final part in _splitAttributes(line)) {
          activeEntity.attributes.add(_parseAttribute(part, number));
        }
      }
      continue;
    }

    final title = RegExp(
      r'^accTitle\s*:\s*(.*)$',
      caseSensitive: false,
    ).firstMatch(line);
    if (title != null) {
      if (accTitle.isNotEmpty) invalid(number, tr("Duplicate accTitle"));
      accTitle = _unquote(title.group(1)!.trim());
      continue;
    }
    if (RegExp(r'^accDescr\s*\{\s*$', caseSensitive: false).hasMatch(line)) {
      if (accDescription.isNotEmpty) invalid(number, tr("Duplicate accDescr"));
      inDescription = true;
      continue;
    }
    final descr = RegExp(
      r'^accDescr\s*:\s*(.*)$',
      caseSensitive: false,
    ).firstMatch(line);
    if (descr != null) {
      if (accDescription.isNotEmpty) invalid(number, tr("Duplicate accDescr"));
      accDescription = _unquote(descr.group(1)!.trim());
      continue;
    }
    final dir = RegExp(
      r'^direction\s+(TB|TD|BT|LR|RL)$',
      caseSensitive: false,
    ).firstMatch(line);
    if (dir != null) {
      direction = dir.group(1)!.toUpperCase();
      if (direction == 'TD') direction = 'TB';
      continue;
    }
    if (RegExp(
      r'^(?:direction|accTitle|accDescr)\b',
      caseSensitive: false,
    ).hasMatch(line)) {
      invalid(number, tr("Malformed direction or accessibility statement"));
    }

    final open = _outside(line, '{');
    final name = _readName(line, 0);
    if (name != null) {
      var cursor = name.end;
      while (cursor < line.length && line[cursor].trim().isEmpty) {
        cursor++;
      }
      var alias = '';
      if (cursor < line.length && line[cursor] == '[') {
        final close = _outside(line, ']', cursor + 1);
        if (close < 0) invalid(number, tr("Unclosed entity alias"));
        alias = _unquote(line.substring(cursor + 1, close).trim());
        if (alias.isEmpty) invalid(number, tr("Empty entity alias"));
        cursor = close + 1;
      }
      final headerEnd = open < 0 ? line.length : open;
      while (cursor < headerEnd && line[cursor].trim().isEmpty) {
        cursor++;
      }
      if (cursor == headerEnd) {
        if (open < 0) {
          ensure(name.text, alias);
          continue;
        }
        final entity = ensure(name.text, alias);
        final rest = line.substring(open + 1);
        final close = _outside(rest, '}');
        if (close < 0) {
          if (rest.trim().isNotEmpty) {
            for (final part in _splitAttributes(rest)) {
              entity.attributes.add(_parseAttribute(part, number));
            }
          }
          activeEntity = entity;
        } else {
          final inside = rest.substring(0, close).trim();
          if (inside.isNotEmpty) {
            for (final part in _splitAttributes(inside)) {
              entity.attributes.add(_parseAttribute(part, number));
            }
          }
          if (rest.substring(close + 1).trim().isNotEmpty) {
            invalid(number, tr("Unexpected text after entity block"));
          }
        }
        continue;
      }
    }

    final relation = _parseRelation(line);
    if (relation == null) {
      invalid(number, tr("Unsupported ER statement: {0}", [line]));
    }
    final left = ensure(relation.left);
    final right = ensure(relation.right);
    edges.add(
      NativeMermaidErRelationship(
        entityA: left.id,
        roleA: relation.role,
        entityB: right.id,
        cardA: relation.cardA,
        cardB: relation.cardB,
        relType: relation.op == '--' ? 'IDENTIFYING' : 'NON_IDENTIFYING',
      ),
    );
  }
  if (!hasHeader) throw FormatException(tr("Expected erDiagram header"));
  if (activeEntity != null) {
    throw FormatException(tr("Unclosed entity block"));
  }
  if (inDescription) throw FormatException(tr("Unclosed accDescr block"));
  return NativeMermaidErDiagramData(
    entities: List.unmodifiable(
      entities.values.map((entity) => entity.freeze()),
    ),
    relationships: List.unmodifiable(edges),
    direction: direction,
    accessibleTitle: accTitle,
    accessibleDescription: accDescription,
  );
}

String _stripErComment(
  String value,
  int lineNumber, {
  bool allowUnclosedQuote = false,
}) {
  var quote = '';
  var escaped = false;
  for (var i = 0; i < value.length; i++) {
    final ch = value[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (quote.isNotEmpty) {
      if (ch == r'\') escaped = true;
      if (ch == quote) quote = '';
    } else if (ch == '"' || ch == "'") {
      quote = ch;
    } else if (value.startsWith('%%', i)) {
      return value.substring(0, i);
    }
  }
  if (quote.isNotEmpty && !allowUnclosedQuote) {
    throw FormatException(tr("Unclosed quoted text at line {0}", [lineNumber]));
  }
  return value;
}

int _outside(String value, String needle, [int start = 0]) {
  var quote = '';
  var escaped = false;
  for (var i = start; i < value.length; i++) {
    final ch = value[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (quote.isNotEmpty) {
      if (ch == r'\') escaped = true;
      if (ch == quote) quote = '';
      continue;
    }
    if (value.startsWith(needle, i)) return i;
    if (ch == '"' || ch == "'") {
      quote = ch;
      continue;
    }
  }
  return -1;
}

_Token? _readName(String text, int start) {
  var i = start;
  while (i < text.length && text[i].trim().isEmpty) {
    i++;
  }
  if (i == text.length) return null;
  final quote = text[i];
  if (quote == '"' || quote == "'") {
    var escaped = false;
    for (var end = i + 1; end < text.length; end++) {
      final ch = text[end];
      if (escaped) {
        escaped = false;
      } else if (ch == r'\') {
        escaped = true;
      } else if (ch == quote) {
        return _Token(
          text
              .substring(i + 1, end)
              .replaceAll(r'\"', '"')
              .replaceAll(r"\'", "'")
              .replaceAll(r'\\', r'\'),
          end + 1,
        );
      }
    }
    return null;
  }
  final match = RegExp(
    r'^[^\s{}\[\]:|]+',
    unicode: true,
  ).firstMatch(text.substring(i));
  return match == null ? null : _Token(match.group(0)!, i + match.end);
}

String _unquote(String text) {
  final value = text.trim();
  if (value.length < 2 ||
      !((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'")))) {
    return value;
  }
  return value
      .substring(1, value.length - 1)
      .replaceAll(r'\"', '"')
      .replaceAll(r"\'", "'")
      .replaceAll(r'\\', r'\');
}

List<String> _splitAttributes(String value) {
  final attributes = <String>[];
  var quote = '';
  var escaped = false;
  var start = 0;
  for (var i = 0; i < value.length; i++) {
    final ch = value[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (quote.isNotEmpty) {
      if (ch == r'\') escaped = true;
      if (ch == quote) quote = '';
      continue;
    }
    if (ch == '"' || ch == "'") {
      quote = ch;
    } else if (ch == ';') {
      final item = value.substring(start, i).trim();
      if (item.isNotEmpty) attributes.add(item);
      start = i + 1;
    }
  }
  final tail = value.substring(start).trim();
  if (tail.isNotEmpty) attributes.add(tail);
  return attributes;
}

NativeMermaidErAttribute _parseAttribute(String line, int number) {
  var text = line.trim();
  var comment = '';
  final quoteIndex = _outside(text, '"');
  if (quoteIndex >= 0) {
    final token = _readName(text, quoteIndex);
    if (token == null || text.substring(token.end).trim().isNotEmpty) {
      throw FormatException(
        tr("Invalid ER attribute comment at line {0}", [number]),
      );
    }
    comment = token.text;
    text = text.substring(0, quoteIndex).trim();
  } else {
    final singleIndex = _outside(text, "'");
    if (singleIndex >= 0) {
      final token = _readName(text, singleIndex);
      if (token == null || text.substring(token.end).trim().isNotEmpty) {
        throw FormatException(
          tr("Invalid ER attribute comment at line {0}", [number]),
        );
      }
      comment = token.text;
      text = text.substring(0, singleIndex).trim();
    }
  }

  final keysMatch = RegExp(
    r'\s+(PK|FK|UK)(?:\s*,\s*(PK|FK|UK))*\s*$',
    caseSensitive: false,
  ).firstMatch(text);
  var keys = <String>[];
  if (keysMatch != null) {
    keys = keysMatch
        .group(0)!
        .trim()
        .split(RegExp(r'\s*,\s*'))
        .map((key) => key.toUpperCase())
        .toList();
    text = text.substring(0, keysMatch.start).trim();
  }
  final divider = text.lastIndexOf(RegExp(r'\s'));
  if (divider < 1 || divider >= text.length - 1) {
    throw FormatException(
      tr("Invalid ER attribute at line {0}: expected a type and name", [
        number,
      ]),
    );
  }
  final type = text.substring(0, divider).trim();
  final name = text.substring(divider).trim();
  if (type.isEmpty || name.isEmpty || name.contains(RegExp(r'\s'))) {
    throw FormatException(tr("Invalid ER attribute at line {0}", [number]));
  }
  return NativeMermaidErAttribute(
    type: type,
    name: name,
    keys: List.unmodifiable(keys),
    comment: comment,
  );
}

_Relation? _parseRelation(String input) {
  final colon = _outside(input, ':');
  final content = (colon < 0 ? input : input.substring(0, colon)).trim();
  final role = colon < 0 ? '' : _unquote(input.substring(colon + 1).trim());
  if (colon >= 0 && role.isEmpty) return null;

  for (final op in const <String>['--', '..', '.-', '-.']) {
    final position = _outside(content, op);
    if (position < 0) continue;
    final left = _cardSuffix(content.substring(0, position).trim());
    final right = _cardPrefix(content.substring(position + op.length).trim());
    if (left != null &&
        right != null &&
        _validEndpoint(left.$1) &&
        _validEndpoint(right.$2)) {
      return _Relation(
        _unquote(left.$1),
        left.$2,
        _unquote(right.$2),
        right.$1,
        op,
        role,
      );
    }
  }

  final to = RegExp(r'\s+to\s+', caseSensitive: false).firstMatch(content);
  if (to == null) return null;
  final leftText = content.substring(0, to.start);
  final left = _wordCardSuffix(leftText);
  final right = _wordCardPrefix(content.substring(to.end));
  if (left == null ||
      right == null ||
      !_validEndpoint(left.$1) ||
      !_validEndpoint(right.$2)) {
    return null;
  }
  return _Relation(
    _unquote(left.$1),
    left.$2,
    _unquote(right.$2),
    right.$1,
    leftText.toLowerCase().contains('optionally') ? '..' : '--',
    role,
  );
}

bool _validEndpoint(String value) =>
    value.isNotEmpty && !value.contains(RegExp(r'[\r\n{}]'));

(String, String)? _cardSuffix(String value) {
  for (final token in const <String>[
    '||',
    '|o',
    'o|',
    'o{',
    '{o',
    '}o',
    'o}',
    '|{',
    '}|',
    '|}',
    '{|',
  ]) {
    if (value.endsWith(token)) {
      return (
        value.substring(0, value.length - token.length).trim(),
        _card(token),
      );
    }
  }
  return null;
}

(String, String)? _cardPrefix(String value) {
  for (final token in const <String>[
    '||',
    '|o',
    'o|',
    'o{',
    '{o',
    '}o',
    'o}',
    '|{',
    '}|',
    '|}',
    '{|',
  ]) {
    if (value.startsWith(token)) {
      return (_card(token), value.substring(token.length).trim());
    }
  }
  return null;
}

String _card(String token) => switch (token) {
  '||' => 'ONLY_ONE',
  '|o' || 'o|' => 'ZERO_OR_ONE',
  'o{' || '{o' || '}o' || 'o}' => 'ZERO_OR_MORE',
  '|{' || '}|' || '|}' || '{|' => 'ONE_OR_MORE',
  _ => throw FormatException(tr("Unsupported ER cardinality {0}", [token])),
};

String? _wordCard(String value) {
  final normalized = value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  if (const {'1', 'one', 'exactly one'}.contains(normalized)) return 'ONLY_ONE';
  if (const {'0', 'zero or one', 'optionally'}.contains(normalized)) {
    return 'ZERO_OR_ONE';
  }
  if (const {
    '0+',
    '0..*',
    'many',
    'many(0)',
    'many(0) optionally',
    'zero or more',
  }.contains(normalized)) {
    return 'ZERO_OR_MORE';
  }
  if (const {'1+', '1..*', 'one or more'}.contains(normalized)) {
    return 'ONE_OR_MORE';
  }
  return null;
}

const _wordCards = <String>[
  'many(0) optionally',
  'zero or more',
  'zero or one',
  'one or more',
  'exactly one',
  'many(0)',
  'optionally',
  '0..*',
  '1..*',
  '0+',
  '1+',
  'many',
  'one',
  '1',
  '0',
];

(String, String)? _wordCardSuffix(String value) {
  final lower = value.toLowerCase();
  for (final card in _wordCards) {
    final match = RegExp(
      r'\s+' + RegExp.escape(card) + r'\s*$',
      caseSensitive: false,
    ).firstMatch(lower);
    if (match != null) {
      return (value.substring(0, match.start).trim(), _wordCard(card)!);
    }
  }
  return null;
}

(String, String)? _wordCardPrefix(String value) {
  final lower = value.toLowerCase();
  for (final card in _wordCards) {
    final match = RegExp(
      r'^\s*' + RegExp.escape(card) + r'\s+',
      caseSensitive: false,
    ).firstMatch(lower);
    if (match != null) {
      return (_wordCard(card)!, value.substring(match.end).trim());
    }
  }
  return null;
}
