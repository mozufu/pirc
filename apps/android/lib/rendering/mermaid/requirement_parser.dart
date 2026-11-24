import '../render_l10n.dart';
import 'requirement_model.dart';

/// Parses the Mermaid 11.17.2 requirementDiagram grammar into its database
/// model. Unsupported statements and malformed values throw [FormatException]
/// instead of being skipped.
NativeRequirementDiagram parseNativeMermaidRequirement(String source) {
  if (source.length > 50000) {
    throw FormatException(tr("Requirement diagram exceeds 50000 characters"));
  }

  final lines = source
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  final requirements = <String, _MutableRequirement>{};
  final elements = <String, _MutableRequirement>{};
  final relations = <NativeRequirementRelation>[];
  final classStyles = <String, List<String>>{};
  var headerSeen = false;
  String? direction = 'TB';
  String? accTitle;
  String? accDescription;

  Never invalid(int line, String details) => throw FormatException(
    tr("Invalid Mermaid requirement diagram at line {0}: {1}", [line, details]),
  );

  void assignClasses(
    Iterable<_MutableRequirement> targets,
    Iterable<String> names,
  ) {
    for (final node in targets) {
      for (final name in names) {
        node.classes.add(name);
        node.cssStyles.addAll(classStyles[name] ?? const []);
      }
    }
  }

  void defineClass(String name, List<String> styles, int line) {
    if (name.isEmpty) invalid(line, tr("Class name cannot be empty"));
    final accumulated = classStyles.putIfAbsent(name, () => <String>[]);
    accumulated.addAll(styles);
    for (final node in [...requirements.values, ...elements.values]) {
      if (node.classes.contains(name)) {
        // Mermaid's DB applies only the newly declared styles when a class is
        // redefined, even though the class itself retains all declarations.
        node.cssStyles.addAll(styles.expand(_splitCssStyle));
      }
    }
  }

  for (var index = 0; index < lines.length; index++) {
    final lineNumber = index + 1;
    final rawLine = lines[index];
    final trimmed = rawLine.trim();
    if (trimmed.isEmpty) continue;

    if (trimmed.startsWith('%%{')) {
      invalid(
        lineNumber,
        tr("Mermaid configuration directives are unsupported"),
      );
    }
    if (_isComment(trimmed)) continue;

    if (!headerSeen) {
      if (trimmed.toLowerCase() != 'requirementdiagram') {
        invalid(lineNumber, tr("Expected a requirementDiagram header"));
      }
      headerSeen = true;
      continue;
    }

    final accTitleMatch = RegExp(
      r'^accTitle\s*:\s*(.*)$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (accTitleMatch != null) {
      accTitle = accTitleMatch.group(1)!.trim();
      continue;
    }

    final accDescriptionMatch = RegExp(
      r'^accDescr\s*:\s*(.*)$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (accDescriptionMatch != null) {
      accDescription = accDescriptionMatch.group(1)!.trim();
      continue;
    }

    final accDescriptionBlock = RegExp(
      r'^accDescr\s*\{(.*)$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (accDescriptionBlock != null) {
      final parts = <String>[];
      var remainder = accDescriptionBlock.group(1)!;
      var closed = false;
      while (true) {
        final close = remainder.indexOf('}');
        if (close >= 0) {
          if (remainder.substring(close + 1).trim().isNotEmpty) {
            invalid(
              lineNumber,
              tr("Unexpected text after accDescr closing brace"),
            );
          }
          parts.add(remainder.substring(0, close));
          closed = true;
          break;
        }
        parts.add(remainder);
        if (index + 1 >= lines.length) break;
        remainder = lines[++index];
      }
      if (!closed) invalid(lineNumber, tr("Unclosed accDescr block"));
      accDescription = parts.join('\n').trim();
      continue;
    }

    final directionMatch = RegExp(
      r'^direction\s+(TB|BT|LR|RL)$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (directionMatch != null) {
      direction = directionMatch.group(1)!.toUpperCase();
      continue;
    }
    if (RegExp(r'^direction(?:\s|$)', caseSensitive: false).hasMatch(trimmed)) {
      invalid(lineNumber, tr("Direction must be TB, BT, LR, or RL"));
    }

    _NodeHeader? requirementHeader;
    for (final keyword in _requirementTypes.keys) {
      requirementHeader = _parseNodeHeader(
        trimmed,
        lineNumber,
        keyword,
        invalid,
      );
      if (requirementHeader != null) break;
    }
    if (requirementHeader != null) {
      final values = _readNodeBody(
        lines,
        index,
        lineNumber,
        _NodeKind.requirement,
        invalid,
      );
      index = values.lastLineIndex;
      if (!requirements.containsKey(requirementHeader.name)) {
        requirements[requirementHeader.name] = _MutableRequirement(
          name: requirementHeader.name,
          type: requirementHeader.type,
          requirementId: values.requirementId,
          text: values.text,
          risk: values.risk,
          verifyMethod: values.verifyMethod,
        );
        if (requirements.length + elements.length > 512) {
          invalid(
            lineNumber,
            tr("Native requirement diagrams support at most 512 nodes"),
          );
        }
      }
      final node = requirements[requirementHeader.name];
      if (node != null) assignClasses([node], requirementHeader.classes);
      continue;
    }

    final elementHeader = _parseNodeHeader(
      trimmed,
      lineNumber,
      'element',
      invalid,
    );
    if (elementHeader != null) {
      final values = _readNodeBody(
        lines,
        index,
        lineNumber,
        _NodeKind.element,
        invalid,
      );
      index = values.lastLineIndex;
      if (!elements.containsKey(elementHeader.name)) {
        elements[elementHeader.name] = _MutableRequirement(
          name: elementHeader.name,
          type: values.elementType,
          docRef: values.docRef,
          isElement: true,
        );
        if (requirements.length + elements.length > 512) {
          invalid(
            lineNumber,
            tr("Native requirement diagrams support at most 512 nodes"),
          );
        }
      }
      final node = elements[elementHeader.name];
      if (node != null) assignClasses([node], elementHeader.classes);
      continue;
    }

    final classDef = _parseNamedStatement(
      trimmed,
      'classDef',
      lineNumber,
      invalid,
    );
    if (classDef != null) {
      final names = _parseNameList(classDef.targets, lineNumber, invalid);
      final styles = _parseStyles(classDef.remainder, lineNumber, invalid);
      for (final name in names) {
        defineClass(name, styles, lineNumber);
      }
      continue;
    }

    final classStatement = _parseNamedStatement(
      trimmed,
      'class',
      lineNumber,
      invalid,
    );
    if (classStatement != null) {
      final targets = _parseNameList(
        classStatement.targets,
        lineNumber,
        invalid,
      );
      final names = _parseNameList(
        classStatement.remainder,
        lineNumber,
        invalid,
      );
      final matching = <_MutableRequirement>[];
      for (final name in targets) {
        final node = requirements[name] ?? elements[name];
        if (node != null) matching.add(node);
      }
      assignClasses(matching, names);
      continue;
    }

    final styleStatement = _parseNamedStatement(
      trimmed,
      'style',
      lineNumber,
      invalid,
    );
    if (styleStatement != null) {
      final targets = _parseNameList(
        styleStatement.targets,
        lineNumber,
        invalid,
      );
      final styles = _parseStyles(
        styleStatement.remainder,
        lineNumber,
        invalid,
      );
      for (final name in targets) {
        final node = requirements[name] ?? elements[name];
        if (node == null) break;
        node.cssStyles.addAll(styles.expand(_splitCssStyle));
      }
      continue;
    }
    if (RegExp(
      r'^(classDef|class|style)(?:\s|$)',
      caseSensitive: false,
    ).hasMatch(trimmed)) {
      invalid(lineNumber, tr("Malformed class or style statement"));
    }

    final relation = _parseRelation(trimmed, lineNumber, invalid);
    if (relation != null) {
      if (relations.length >= 1024) {
        invalid(
          lineNumber,
          tr("Native requirement diagrams support at most 1024 relations"),
        );
      }
      relations.add(relation);
      continue;
    }

    invalid(lineNumber, tr("Unsupported requirementDiagram statement"));
  }

  if (!headerSeen) {
    throw FormatException(tr("Missing Mermaid requirementDiagram header"));
  }

  return NativeRequirementDiagram(
    direction: direction,
    title: null,
    accTitle: accTitle,
    accDescription: accDescription,
    requirements: requirements.values.map((node) => node.freeze()),
    elements: elements.values.map((node) => node.freeze()),
    relations: relations,
    classDefinitions: classStyles,
  );
}

enum _NodeKind { requirement, element }

class _NodeHeader {
  const _NodeHeader({
    required this.name,
    required this.type,
    required this.classes,
  });

  final String name;
  final String type;
  final List<String> classes;
}

_NodeHeader? _parseNodeHeader(
  String line,
  int lineNumber,
  String keyword,
  Never Function(int, String) invalid,
) {
  final open = _findOutsideQuotes(line, '{');
  if (open < 0) return null;
  if (line.substring(open + 1).trim().isNotEmpty) {
    invalid(lineNumber, tr("Unexpected text after node opening brace"));
  }

  final beforeBrace = line.substring(0, open).trimRight();
  final keywordMatch = RegExp(
    '^${RegExp.escape(keyword)}\\s+(.+)\$',
    caseSensitive: false,
  ).firstMatch(beforeBrace);
  if (keywordMatch == null) return null;
  final matchedKeyword = keywordMatch.group(0)!.split(RegExp(r'\s+')).first;
  final type = keyword.toLowerCase() == 'element'
      ? ''
      : _requirementTypes[matchedKeyword.toLowerCase()];

  var rest = keywordMatch.group(1)!.trim();
  final classSeparator = _findOutsideQuotes(rest, ':::');
  var classes = const <String>[];
  if (classSeparator >= 0) {
    final classSource = rest.substring(classSeparator + 3).trim();
    if (classSource.isEmpty) {
      invalid(lineNumber, tr("Inline class list cannot be empty"));
    }
    classes = _parseNameList(classSource, lineNumber, invalid);
    rest = rest.substring(0, classSeparator).trimRight();
  }

  final name = _parseIdentifier(rest, lineNumber, invalid);
  if (name.isEmpty) invalid(lineNumber, tr("Node name cannot be empty"));
  if (type == null) invalid(lineNumber, tr("Unsupported requirement type"));
  return _NodeHeader(name: name, type: type, classes: classes);
}

class _NodeValues {
  const _NodeValues({
    required this.lastLineIndex,
    this.requirementId = '',
    this.text = '',
    this.risk = '',
    this.verifyMethod = '',
    this.elementType = '',
    this.docRef = '',
  });

  final int lastLineIndex;
  final String requirementId;
  final String text;
  final String risk;
  final String verifyMethod;
  final String elementType;
  final String docRef;
}

class _NamedStatement {
  const _NamedStatement(this.targets, this.remainder);

  final String targets;
  final String remainder;
}

_NamedStatement? _parseNamedStatement(
  String source,
  String keyword,
  int line,
  Never Function(int, String) invalid,
) {
  final prefix = RegExp('^${RegExp.escape(keyword)}\\s+', caseSensitive: false);
  final match = prefix.firstMatch(source);
  if (match == null) return null;
  final tail = source.substring(match.end);
  final split = _firstWhitespaceOutsideQuotes(tail);
  if (split <= 0 || split == tail.length - 1) {
    invalid(line, tr("{0} statement must have targets and a value", [keyword]));
  }
  return _NamedStatement(
    tail.substring(0, split).trim(),
    tail.substring(split).trim(),
  );
}

int _firstWhitespaceOutsideQuotes(String source) {
  var inQuotes = false;
  for (var index = 0; index < source.length; index++) {
    if (source[index] == '"') inQuotes = !inQuotes;
    if (!inQuotes && RegExp(r'\s').hasMatch(source[index])) {
      var previous = index - 1;
      while (previous >= 0 && RegExp(r'\s').hasMatch(source[previous])) {
        previous--;
      }
      var next = index + 1;
      while (next < source.length && RegExp(r'\s').hasMatch(source[next])) {
        next++;
      }
      if ((previous >= 0 && source[previous] == ',') ||
          (next < source.length && source[next] == ',')) {
        continue;
      }
      return index;
    }
  }
  return -1;
}

_NodeValues _readNodeBody(
  List<String> lines,
  int headerIndex,
  int headerLine,
  _NodeKind kind,
  Never Function(int, String) invalid,
) {
  var requirementId = '';
  var text = '';
  var risk = '';
  var verifyMethod = '';
  var elementType = '';
  var docRef = '';
  final seen = <String>{};

  for (var index = headerIndex + 1; index < lines.length; index++) {
    final lineNumber = index + 1;
    final raw = lines[index];
    final trimmed = raw.trim();
    if (trimmed.startsWith('%%{')) {
      invalid(
        lineNumber,
        tr("Mermaid configuration directives are unsupported"),
      );
    }
    if (_isComment(trimmed) || trimmed.isEmpty) continue;
    if (trimmed == '}') {
      return _NodeValues(
        lastLineIndex: index,
        requirementId: requirementId,
        text: text,
        risk: risk,
        verifyMethod: verifyMethod,
        elementType: elementType,
        docRef: docRef,
      );
    }

    final field = RegExp(r'^([A-Za-z]+)\s*:\s*(.*)$').firstMatch(trimmed);
    if (field == null) {
      invalid(lineNumber, tr("Expected a field or closing brace"));
    }
    final key = field.group(1)!.toLowerCase();
    final first = seen.add(key);
    final value = _parseFieldValue(field.group(2)!, lineNumber, invalid);
    if (kind == _NodeKind.requirement) {
      switch (key) {
        case 'id':
          if (first) requirementId = value;
          break;
        case 'text':
          if (first) text = value;
          break;
        case 'risk':
          if (field.group(2)!.trim().startsWith('"')) {
            invalid(lineNumber, 'Risk values must be Low, Medium, or High');
          }
          final parsed = _parseEnum(
            value,
            _riskLevels,
            'risk',
            lineNumber,
            invalid,
          );
          if (first) risk = parsed;
          break;
        case 'verifymethod':
          if (field.group(2)!.trim().startsWith('"')) {
            invalid(
              lineNumber,
              'verifyMethod must be Analysis, Demonstration, Inspection, or Test',
            );
          }
          final parsed = _parseEnum(
            value,
            _verifyMethods,
            'verifyMethod',
            lineNumber,
            invalid,
          );
          if (first) verifyMethod = parsed;
          break;
        default:
          invalid(
            lineNumber,
            tr("Unsupported requirement field \"{0}\"", [key]),
          );
      }
    } else {
      switch (key) {
        case 'type':
          if (first) elementType = value;
          break;
        case 'docref':
          if (first) docRef = value;
          break;
        default:
          invalid(lineNumber, tr("Unsupported element field \"{0}\"", [key]));
      }
    }
  }
  invalid(headerLine, tr("Unclosed node definition"));
}

NativeRequirementRelation? _parseRelation(
  String source,
  int lineNumber,
  Never Function(int, String) invalid,
) {
  var cursor = 0;
  final left = _readIdentifier(source, cursor, lineNumber, invalid);
  if (left == null) return null;
  cursor = left.end;
  cursor = _skipWhitespace(source, cursor);

  final reverse = source.startsWith('<-', cursor);
  if (reverse) {
    cursor += 2;
  } else if (source.startsWith('-', cursor)) {
    cursor++;
  } else {
    return null;
  }
  cursor = _skipWhitespace(source, cursor);

  final relationType = _readKeyword(source, cursor, _relationshipTypes);
  if (relationType == null) {
    invalid(lineNumber, tr("Unknown relationship type"));
  }
  cursor = _skipWhitespace(source, relationType.end);

  if (reverse) {
    if (!source.startsWith('-', cursor) || source.startsWith('->', cursor)) {
      invalid(lineNumber, 'Reverse relationships must use "<- type - name"');
    }
    cursor++;
  } else {
    if (!source.startsWith('->', cursor)) {
      invalid(lineNumber, 'Relationships must use "name - type -> name"');
    }
    cursor += 2;
  }
  cursor = _skipWhitespace(source, cursor);
  final right = _readIdentifier(source, cursor, lineNumber, invalid);
  if (right == null) invalid(lineNumber, tr("Relationship has no destination"));
  if (source.substring(right.end).trim().isNotEmpty) {
    invalid(lineNumber, tr("Unexpected text after relationship destination"));
  }

  return NativeRequirementRelation(
    type: relationType.value.toLowerCase(),
    from: reverse ? right.value : left.value,
    to: reverse ? left.value : right.value,
  );
}

class _IdentifierRead {
  const _IdentifierRead(this.value, this.end);
  final String value;
  final int end;
}

_IdentifierRead? _readIdentifier(
  String source,
  int start,
  int lineNumber,
  Never Function(int, String) invalid,
) {
  var cursor = _skipWhitespace(source, start);
  if (cursor >= source.length) return null;
  if (source[cursor] == '"') {
    final end = source.indexOf('"', cursor + 1);
    if (end < 0) invalid(lineNumber, tr("Unclosed quoted identifier"));
    final value = source.substring(cursor + 1, end);
    if (value.isEmpty) invalid(lineNumber, tr("Identifier cannot be empty"));
    return _IdentifierRead(value, end + 1);
  }

  final match = RegExp(
    r'^\w[^:,{}<>\-=]*',
  ).firstMatch(source.substring(cursor));
  if (match == null) return null;
  final value = match.group(0)!.trimRight();
  if (value.isEmpty) return null;
  return _IdentifierRead(value, cursor + match.group(0)!.length);
}

_IdentifierRead? _readKeyword(
  String source,
  int start,
  Iterable<String> values,
) {
  for (final value in values) {
    if (source.substring(start).toLowerCase().startsWith(value.toLowerCase())) {
      final end = start + value.length;
      if (end == source.length || !RegExp(r'\w').hasMatch(source[end])) {
        return _IdentifierRead(value, end);
      }
    }
  }
  return null;
}

int _skipWhitespace(String source, int index) {
  while (index < source.length && RegExp(r'\s').hasMatch(source[index])) {
    index++;
  }
  return index;
}

String _parseIdentifier(
  String source,
  int line,
  Never Function(int, String) invalid,
) {
  final trimmed = source.trim();
  if (trimmed.isEmpty) return '';
  if (trimmed.startsWith('"')) {
    if (trimmed.length < 2 || !trimmed.endsWith('"')) {
      invalid(line, tr("Unclosed quoted name"));
    }
    final inner = trimmed.substring(1, trimmed.length - 1);
    if (inner.contains('"')) invalid(line, tr("Unexpected quote in name"));
    if (inner.isEmpty) invalid(line, tr("Name cannot be empty"));
    return inner;
  }
  if (!RegExp(r'^\w[^:,{}<>\-=]*$').hasMatch(trimmed)) {
    invalid(
      line,
      tr("Invalid unquoted name; quote names containing punctuation"),
    );
  }
  return trimmed;
}

List<String> _parseNameList(
  String source,
  int line,
  Never Function(int, String) invalid,
) {
  final names = _splitCommaList(
    source,
    line,
    invalid,
  ).map((part) => _parseIdentifier(part, line, invalid)).toList();
  if (names.any((name) => name.isEmpty)) {
    invalid(line, tr("Name list contains an empty value"));
  }
  return names;
}

List<String> _splitCommaList(
  String source,
  int line,
  Never Function(int, String) invalid,
) {
  final values = <String>[];
  var inQuotes = false;
  var start = 0;
  for (var index = 0; index < source.length; index++) {
    if (source[index] == '"') inQuotes = !inQuotes;
    if (source[index] == ',' && !inQuotes) {
      values.add(source.substring(start, index).trim());
      start = index + 1;
    }
  }
  if (inQuotes) invalid(line, tr("Unclosed quoted value"));
  values.add(source.substring(start).trim());
  if (values.any((value) => value.isEmpty)) {
    invalid(line, tr("Comma-separated list contains an empty value"));
  }
  return values;
}

List<String> _parseStyles(
  String source,
  int line,
  Never Function(int, String) invalid,
) {
  final styles = _splitCommaList(
    source,
    line,
    invalid,
  ).map(_normalizeCssStyle).toList();
  if (_hasUnsupportedStyleCharacters(source)) {
    invalid(line, tr("CSS style contains characters unsupported by Mermaid"));
  }
  for (final style in styles) {
    for (final declaration in _splitOutsideQuotes(style, ';')) {
      if (declaration.trim().isEmpty) continue;
      final colon = declaration.indexOf(':');
      if (colon <= 0 || colon == declaration.length - 1) {
        invalid(
          line,
          tr("CSS style must be a non-empty property:value declaration"),
        );
      }
      final property = declaration.substring(0, colon).trim();
      final value = declaration.substring(colon + 1).trim();
      if (!RegExp(r'^(?:--)?[A-Za-z_][\w-]*$').hasMatch(property) ||
          value.isEmpty ||
          RegExp(r'[{}<>\r\n]').hasMatch(value)) {
        invalid(
          line,
          tr("Invalid CSS style declaration \"{0}\"", [declaration]),
        );
      }
    }
  }
  return styles;
}

List<String> _splitCssStyle(String style) => style.split(',');

bool _hasUnsupportedStyleCharacters(String source) {
  var inQuotes = false;
  for (var index = 0; index < source.length; index++) {
    final character = source[index];
    if (character == '"') {
      inQuotes = !inQuotes;
      continue;
    }
    if (inQuotes || RegExp(r'[\w\s:;%,#-]').hasMatch(character)) continue;
    return true;
  }
  return false;
}

String _normalizeCssStyle(String source) {
  final result = StringBuffer();
  var inQuotes = false;
  for (final character in source.split('')) {
    if (character == '"') {
      inQuotes = !inQuotes;
      continue;
    }
    if (!inQuotes && RegExp(r'\s').hasMatch(character)) continue;
    result.write(character);
  }
  return result.toString();
}

List<String> _splitOutsideQuotes(String source, String separator) {
  final values = <String>[];
  var inQuotes = false;
  var start = 0;
  for (var index = 0; index < source.length; index++) {
    if (source[index] == '"') inQuotes = !inQuotes;
    if (!inQuotes && source.startsWith(separator, index)) {
      values.add(source.substring(start, index));
      start = index + separator.length;
    }
  }
  values.add(source.substring(start));
  return values;
}

String _parseFieldValue(
  String source,
  int line,
  Never Function(int, String) invalid,
) {
  final value = source.trim();
  if (value.startsWith('"')) {
    if (value.length < 2 || !value.endsWith('"')) {
      invalid(line, tr("Unclosed quoted field value"));
    }
    final inner = value.substring(1, value.length - 1);
    if (inner.contains('"')) {
      invalid(line, tr("Unexpected quote in field value"));
    }
    return inner;
  }
  if (value.isEmpty) return '';
  if (!RegExp(r'^\w[^:,{}<>\-=]*$').hasMatch(value)) {
    invalid(
      line,
      tr("Invalid unquoted field value; quote values containing punctuation"),
    );
  }
  return value;
}

String _parseEnum(
  String value,
  Map<String, String> choices,
  String field,
  int line,
  Never Function(int, String) invalid,
) {
  final result = choices[value.toLowerCase()];
  if (result == null) {
    invalid(line, tr("Invalid {0} value \"{1}\"", [field, value]));
  }
  return result;
}

int _findOutsideQuotes(String source, String needle) {
  var inQuotes = false;
  for (var index = 0; index <= source.length - needle.length; index++) {
    if (source[index] == '"') inQuotes = !inQuotes;
    if (!inQuotes && source.startsWith(needle, index)) return index;
  }
  return -1;
}

bool _isComment(String line) => line.startsWith('#') || line.startsWith('%');

const _requirementTypes = <String, String>{
  'requirement': 'Requirement',
  'functionalrequirement': 'Functional Requirement',
  'interfacerequirement': 'Interface Requirement',
  'performancerequirement': 'Performance Requirement',
  'physicalrequirement': 'Physical Requirement',
  'designconstraint': 'Design Constraint',
};

const _riskLevels = <String, String>{
  'low': 'Low',
  'medium': 'Medium',
  'high': 'High',
};

const _verifyMethods = <String, String>{
  'analysis': 'Analysis',
  'demonstration': 'Demonstration',
  'inspection': 'Inspection',
  'test': 'Test',
};

const _relationshipTypes = <String>[
  'contains',
  'copies',
  'derives',
  'satisfies',
  'verifies',
  'refines',
  'traces',
];

class _MutableRequirement {
  _MutableRequirement({
    required this.name,
    this.type = '',
    this.requirementId = '',
    this.text = '',
    this.risk = '',
    this.verifyMethod = '',
    this.docRef = '',
    this.isElement = false,
  });

  final String name;
  final String type;
  final String requirementId;
  final String text;
  final String risk;
  final String verifyMethod;
  final String docRef;
  final bool isElement;
  final List<String> cssStyles = [];
  final List<String> classes = ['default'];

  NativeRequirementNode freeze() => NativeRequirementNode(
    name: name,
    type: type,
    requirementId: requirementId,
    text: text,
    risk: risk,
    verifyMethod: verifyMethod,
    docRef: docRef,
    isElement: isElement,
    cssStyles: cssStyles,
    classes: classes,
  );
}
