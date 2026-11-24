import '../render_l10n.dart';
import 'c4_model.dart';

/// Parses Mermaid 11.17.2 C4 diagrams into a Flutter-independent model.
///
/// Supported statements are the five C4 headers, entities, boundaries,
/// relations, title, layout updates, and the modeled style fields. Unsupported
/// syntax and attributes raise [FormatException] instead of being dropped.
NativeC4Diagram parseNativeMermaidC4(String source, {bool? wrap}) {
  if (source.length > 50000) {
    throw FormatException(tr("C4 diagram exceeds 50000 characters"));
  }
  return _C4Parser(source, wrap: wrap).parse();
}

class _C4Parser {
  _C4Parser(this.source, {bool? wrap})
    : configWrap = wrap ?? true,
      itemWrap = wrap ?? false;

  final String source;
  bool configWrap;
  bool itemWrap;
  int index = 0;
  int line = 1;
  String? kind;
  String? title;
  int shapeInRow = 4;
  int boundaryInRow = 2;

  final List<_ShapeData> shapes = [];
  final List<_BoundaryData> boundaries = [
    _BoundaryData(
      alias: 'global',
      label: 'global',
      type: 'global',
      parentBoundary: '',
      kind: 'global',
      wrap: false,
    ),
  ];
  final List<_RelationData> relations = [];
  final List<String> boundaryStack = ['global'];

  Never _invalid(String message, [int? atLine]) => throw FormatException(
    tr("Invalid Mermaid C4 at line {0}: {1}", [atLine ?? line, message]),
  );

  NativeC4Diagram parse() {
    _skipIgnored();
    if (index >= source.length) {
      throw FormatException(tr("Missing Mermaid C4 header"));
    }
    final headerLine = line;
    final header = _readWord();
    if (!_diagramKinds.contains(header)) {
      _invalid(
        tr(
          "Expected C4Context, C4Container, C4Component, C4Dynamic, or C4Deployment",
        ),
        headerLine,
      );
    }
    kind = header;
    _finishLine(headerLine, allowBlock: false);

    while (true) {
      _skipIgnored();
      if (index >= source.length) break;
      final statementLine = line;
      if (_peek() == '}') {
        index++;
        _finishCurrentStatementLine();
        if (boundaryStack.length == 1) {
          _invalid(tr("Unmatched boundary close"), statementLine);
        }
        boundaryStack.removeLast();
        continue;
      }

      final word = _readWord();
      if (word == 'title') {
        title = _readTitle(statementLine);
        continue;
      }
      if (word == 'direction') {
        _invalid(
          tr("Diagram direction is not supported natively"),
          statementLine,
        );
      }
      if (word == 'accTitle' ||
          word == 'accDescr' ||
          word == 'accDescription') {
        _invalid(
          tr("Accessibility metadata is not supported natively"),
          statementLine,
        );
      }
      if (_entityKinds.containsKey(word)) {
        final args = _readCall(statementLine);
        _finishLine(statementLine, allowBlock: false);
        _addShape(word, args, statementLine);
        continue;
      }
      if (_boundaryKinds.containsKey(word)) {
        final args = _readCall(statementLine);
        final opensBoundary = _finishLine(statementLine, allowBlock: true);
        if (!opensBoundary) {
          _invalid(tr("{0} requires an opening \"{\"", [word]), statementLine);
        }
        _addBoundary(word, args, statementLine);
        continue;
      }
      if (_relationKinds.containsKey(word)) {
        final args = _readCall(statementLine);
        _finishLine(statementLine, allowBlock: false);
        _addRelation(word, args, statementLine);
        continue;
      }
      if (word == 'UpdateElementStyle') {
        final args = _readCall(statementLine);
        _finishLine(statementLine, allowBlock: false);
        _updateElementStyle(args, statementLine);
        continue;
      }
      if (word == 'UpdateRelStyle') {
        final args = _readCall(statementLine);
        _finishLine(statementLine, allowBlock: false);
        _updateRelationStyle(args, statementLine);
        continue;
      }
      if (word == 'UpdateLayoutConfig') {
        final args = _readCall(statementLine);
        _finishLine(statementLine, allowBlock: false);
        _updateLayout(args, statementLine);
        continue;
      }
      _invalid(
        tr("Unsupported or invalid statement \"{0}\"", [word]),
        statementLine,
      );
    }

    if (boundaryStack.length > 1) {
      _invalid(
        tr("Boundary \"{0}\" is missing a closing \"}\"", [boundaryStack.last]),
      );
    }
    final aliases = shapes.map((shape) => shape.alias).toSet();
    for (final relation in relations) {
      if (!aliases.contains(relation.from)) {
        _invalid(
          tr("Relationship references unknown source \"{0}\"", [relation.from]),
        );
      }
      if (!aliases.contains(relation.to)) {
        _invalid(
          tr("Relationship references unknown destination \"{0}\"", [
            relation.to,
          ]),
        );
      }
    }

    return NativeC4Diagram(
      kind: kind!,
      title: title,
      shapes: shapes.map((shape) => shape.toModel()),
      boundaries: boundaries.map((boundary) => boundary.toModel()),
      relations: relations.map((relation) => relation.toModel()),
      shapeInRow: shapeInRow,
      boundaryInRow: boundaryInRow,
      wrap: configWrap,
    );
  }

  static const _diagramKinds = {
    'C4Context',
    'C4Container',
    'C4Component',
    'C4Dynamic',
    'C4Deployment',
  };

  static const _entityKinds = <String, _EntitySpec>{
    'Person': _EntitySpec('person', _EntityFamily.person),
    'Person_Ext': _EntitySpec('external_person', _EntityFamily.person),
    'System': _EntitySpec('system', _EntityFamily.person),
    'SystemDb': _EntitySpec('system_db', _EntityFamily.person),
    'SystemQueue': _EntitySpec('system_queue', _EntityFamily.person),
    'System_Ext': _EntitySpec('external_system', _EntityFamily.person),
    'SystemDb_Ext': _EntitySpec('external_system_db', _EntityFamily.person),
    'SystemQueue_Ext': _EntitySpec(
      'external_system_queue',
      _EntityFamily.person,
    ),
    'Container': _EntitySpec('container', _EntityFamily.typed),
    'ContainerDb': _EntitySpec('container_db', _EntityFamily.typed),
    'ContainerQueue': _EntitySpec('container_queue', _EntityFamily.typed),
    'Container_Ext': _EntitySpec('external_container', _EntityFamily.typed),
    'ContainerDb_Ext': _EntitySpec(
      'external_container_db',
      _EntityFamily.typed,
    ),
    'ContainerQueue_Ext': _EntitySpec(
      'external_container_queue',
      _EntityFamily.typed,
    ),
    'Component': _EntitySpec('component', _EntityFamily.typed),
    'ComponentDb': _EntitySpec('component_db', _EntityFamily.typed),
    'ComponentQueue': _EntitySpec('component_queue', _EntityFamily.typed),
    'Component_Ext': _EntitySpec('external_component', _EntityFamily.typed),
    'ComponentDb_Ext': _EntitySpec(
      'external_component_db',
      _EntityFamily.typed,
    ),
    'ComponentQueue_Ext': _EntitySpec(
      'external_component_queue',
      _EntityFamily.typed,
    ),
  };

  static const _boundaryKinds = <String, _BoundarySpec>{
    'Enterprise_Boundary': _BoundarySpec(
      'enterprise_boundary',
      'ENTERPRISE',
      _BoundaryFamily.group,
    ),
    'System_Boundary': _BoundarySpec(
      'system_boundary',
      'SYSTEM',
      _BoundaryFamily.group,
    ),
    'Boundary': _BoundarySpec('boundary', 'system', _BoundaryFamily.group),
    'Container_Boundary': _BoundarySpec(
      'container_boundary',
      'CONTAINER',
      _BoundaryFamily.group,
    ),
    'Deployment_Node': _BoundarySpec(
      'deployment_node',
      'node',
      _BoundaryFamily.deployment,
      'node',
    ),
    'Node': _BoundarySpec('node', 'node', _BoundaryFamily.deployment, 'node'),
    'Node_L': _BoundarySpec(
      'node_l',
      'node',
      _BoundaryFamily.deployment,
      'nodeL',
    ),
    'Node_R': _BoundarySpec(
      'node_r',
      'node',
      _BoundaryFamily.deployment,
      'nodeR',
    ),
  };

  static const _relationKinds = <String, String>{
    'Rel': 'rel',
    'BiRel': 'birel',
    'Rel_Up': 'rel_u',
    'Rel_U': 'rel_u',
    'Rel_Down': 'rel_d',
    'Rel_D': 'rel_d',
    'Rel_Left': 'rel_l',
    'Rel_L': 'rel_l',
    'Rel_Right': 'rel_r',
    'Rel_R': 'rel_r',
    'Rel_Back': 'rel_b',
    'RelIndex': 'rel',
  };

  String _readWord() {
    _skipHorizontal();
    final start = index;
    while (index < source.length && _isWordChar(source.codeUnitAt(index))) {
      index++;
    }
    if (start == index) _invalid(tr("Expected a statement name"));
    return source.substring(start, index);
  }

  String _readTitle(int statementLine) {
    if (index >= source.length || !_isHorizontal(source.codeUnitAt(index))) {
      _invalid(tr("Expected whitespace after title"), statementLine);
    }
    _skipHorizontal();
    final start = index;
    while (index < source.length && _peek() != '\n' && _peek() != '\r') {
      if (_startsWith('%%')) break;
      if (_peek() == ';') {
        _invalid(tr("Semicolon is not supported in title"), statementLine);
      }
      index++;
    }
    final result = source.substring(start, index).trimRight();
    if (result.isEmpty) _invalid(tr("Title cannot be empty"), statementLine);
    if (_startsWith('%%')) _skipComment();
    _advanceLineEnd(statementLine);
    return result;
  }

  List<_Argument> _readCall(int statementLine) {
    _skipWhitespace();
    if (_peek() != '(') {
      _invalid(tr("Expected \"(\" after statement name"), statementLine);
    }
    index++;
    final args = <_Argument>[];
    _skipWhitespace();
    if (_peek() == ')') {
      index++;
      return args;
    }

    while (true) {
      final argLine = line;
      final raw = StringBuffer();
      var quoted = false;
      var quoteSeen = false;
      while (index < source.length) {
        final c = _peek();
        if (quoted) {
          raw.write(c);
          index++;
          if (c == '"') {
            quoted = false;
          } else if (c == '\n') {
            line++;
          } else if (c == '\r' && _peek() != '\n') {
            line++;
          }
          continue;
        }
        if (quoteSeen &&
            c != ',' &&
            c != ')' &&
            !_isWhitespace(source.codeUnitAt(index))) {
          _invalid(
            tr("Text after a closing quote is not supported by Mermaid C4"),
          );
        }
        if (c == '"') {
          quoted = true;
          quoteSeen = true;
          raw.write(c);
          index++;
          continue;
        }
        if (c == ',' || c == ')') break;
        if (c == '(') {
          _invalid(tr("Nested parentheses are not supported in arguments"));
        }
        if (c == '\n' || c == '\r') {
          _consumeNewline();
          raw.write('\n');
          continue;
        }
        if (_startsWith('%%')) {
          _skipComment();
          raw.write(' ');
          continue;
        }
        if (c == ';') {
          _invalid(tr("Semicolon is not supported in C4 statements"));
        }
        raw.write(c);
        index++;
      }
      if (quoted) _invalid(tr("Unterminated quoted argument"), argLine);
      args.add(_parseArgument(raw.toString(), quoteSeen, argLine));
      if (index >= source.length) {
        _invalid(tr("Unclosed argument list"), statementLine);
      }
      if (_peek() == ')') {
        index++;
        break;
      }
      index++; // comma
      _skipWhitespace();
      if (_peek() == ')') {
        args.add(const _TextArgument(''));
        index++;
        break;
      }
    }
    return args;
  }

  _Argument _parseArgument(String raw, bool quoteSeen, int argLine) {
    final value = raw.trim();
    if (value.isEmpty) return const _TextArgument('');
    final named = RegExp(
      r'^\$?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$',
      dotAll: true,
    ).firstMatch(value);
    if (named != null) {
      final decoded = _decodeValue(named.group(2)!.trim(), argLine);
      return _MapArgument({named.group(1)!: decoded});
    }
    if (quoteSeen) {
      if (!value.startsWith('"') || !value.endsWith('"')) {
        _invalid(
          tr("Quoted argument must occupy the complete argument"),
          argLine,
        );
      }
      return _TextArgument(value.substring(1, value.length - 1));
    }
    return _TextArgument(value);
  }

  String _decodeValue(String raw, int atLine) {
    if (raw.startsWith('"')) {
      if (raw.length < 2 || !raw.endsWith('"')) {
        _invalid(tr("Unterminated quoted attribute value"), atLine);
      }
      return raw.substring(1, raw.length - 1);
    }
    return raw;
  }

  bool _finishLine(int statementLine, {required bool allowBlock}) {
    _skipHorizontal();
    var opensBlock = false;
    if (allowBlock && _peek() == '{') {
      opensBlock = true;
      index++;
      _skipHorizontal();
    }
    if (_startsWith('%%')) _skipComment();
    if (index < source.length && _peek() != '\n' && _peek() != '\r') {
      _invalid(tr("Unexpected text after statement"), statementLine);
    }
    _advanceLineEnd(statementLine);
    return opensBlock;
  }

  void _addShape(String statement, List<_Argument> args, int atLine) {
    final spec = _entityKinds[statement]!;
    if (args.length < 2) {
      _invalid(tr("{0} needs an alias and label", [statement]), atLine);
    }
    final alias = _text(args[0], 'alias', atLine);
    final label = _text(args[1], 'label', atLine);
    String? type;
    String? technology = spec.family == _EntityFamily.typed ? '' : null;
    String? description = '';
    String? backgroundColor;
    String? fontColor;
    String? borderColor;
    String? shadowing;

    void onAttribute(String key, String value) {
      switch (key) {
        case 'descr':
          description = value;
        case 'techn':
          technology = value;
        case 'type':
          type = value;
        case 'bgColor':
          backgroundColor = value;
        case 'fontColor':
          fontColor = value;
        case 'borderColor':
          borderColor = value;
        case 'shadowing':
          shadowing = value;
        case 'shape':
          if (value.isNotEmpty) _unsupportedAttribute(key, atLine);
        default:
          _unsupportedAttribute(key, atLine);
      }
    }

    var position = 2;
    if (spec.family == _EntityFamily.person) {
      if (position < args.length) {
        final argument = args[position++];
        if (argument is _MapArgument) description = null;
        final value = _optionalTextOrAttributes(argument, onAttribute);
        if (value != null) description = value;
      }
    } else {
      if (position < args.length) {
        final argument = args[position++];
        if (argument is _MapArgument) technology = null;
        final value = _optionalTextOrAttributes(argument, onAttribute);
        if (value != null) technology = value;
      }
      if (position < args.length) {
        final argument = args[position++];
        if (argument is _MapArgument) description = null;
        final value = _optionalTextOrAttributes(argument, onAttribute);
        if (value != null) description = value;
      }
    }
    _readAttributeTail(args, position, atLine, const [
      'sprite',
      'tags',
      'link',
    ], onAttribute);

    var shape = shapes.where((item) => item.alias == alias).firstOrNull;
    if (shape == null) {
      shape = _ShapeData(
        alias: alias,
        kind: spec.kind,
        label: label,
        parentBoundary: boundaryStack.last,
        type: type,
        technology: technology,
        description: description,
        wrap: itemWrap,
        backgroundColor: backgroundColor,
        fontColor: fontColor,
        borderColor: borderColor,
        shadowing: shadowing,
      );
      shapes.add(shape);
    } else {
      shape
        ..kind = spec.kind
        ..label = label
        ..parentBoundary = boundaryStack.last
        ..type = type ?? shape.type
        ..technology = technology ?? shape.technology
        ..description = description ?? shape.description
        ..wrap = itemWrap
        ..backgroundColor = backgroundColor ?? shape.backgroundColor
        ..fontColor = fontColor ?? shape.fontColor
        ..borderColor = borderColor ?? shape.borderColor
        ..shadowing = shadowing ?? shape.shadowing;
    }
  }

  void _addBoundary(String statement, List<_Argument> args, int atLine) {
    final spec = _boundaryKinds[statement]!;
    if (args.length < 2) {
      _invalid(tr("{0} needs an alias and label", [statement]), atLine);
    }
    final alias = _text(args[0], 'alias', atLine);
    final label = _text(args[1], 'label', atLine);
    var type = spec.defaultType;
    String? description = spec.family == _BoundaryFamily.deployment ? '' : null;
    String? technology;
    String? backgroundColor;
    String? fontColor;
    String? borderColor;
    String? shadowing;

    void onAttribute(String key, String value) {
      switch (key) {
        case 'type':
          type = value;
        case 'descr':
          description = value;
        case 'techn':
          technology = value;
        case 'bgColor':
          backgroundColor = value;
        case 'fontColor':
          fontColor = value;
        case 'borderColor':
          borderColor = value;
        case 'shadowing':
          shadowing = value;
        case 'shape':
          if (value.isNotEmpty) _unsupportedAttribute(key, atLine);
        default:
          _unsupportedAttribute(key, atLine);
      }
    }

    var position = 2;
    if (spec.family == _BoundaryFamily.deployment) {
      if (position < args.length) {
        type = _readBoundaryType(args[position++], type, onAttribute, atLine);
      }
      if (position < args.length) {
        final argument = args[position++];
        if (argument is _MapArgument) description = null;
        final value = _optionalTextOrAttributes(argument, onAttribute);
        if (value != null) description = value;
      }
      _readAttributeTail(args, position, atLine, const [
        'sprite',
        'tags',
        'link',
      ], onAttribute);
    } else if (statement == 'Boundary') {
      if (position < args.length) {
        type = _readBoundaryType(args[position++], type, onAttribute, atLine);
      }
      _readAttributeTail(args, position, atLine, const [
        'tags',
        'link',
      ], onAttribute);
    } else {
      // Mermaid injects the group type before forwarding source attributes.
      _readAttributeTail(args, position, atLine, const [
        'tags',
        'link',
      ], onAttribute);
    }

    var boundary = boundaries.where((item) => item.alias == alias).firstOrNull;
    if (boundary == null) {
      boundary = _BoundaryData(
        alias: alias,
        label: label,
        type: type,
        parentBoundary: boundaryStack.last,
        kind: spec.kind,
        description: description,
        technology: technology,
        wrap: itemWrap,
        nodeType: spec.nodeType,
        backgroundColor: backgroundColor,
        fontColor: fontColor,
        borderColor: borderColor,
        shadowing: shadowing,
      );
      boundaries.add(boundary);
    } else {
      boundary
        ..label = label
        ..type = type
        ..parentBoundary = boundaryStack.last
        ..kind = spec.kind
        ..description = description ?? boundary.description
        ..technology = technology ?? boundary.technology
        ..wrap = itemWrap
        ..nodeType = spec.nodeType
        ..backgroundColor = backgroundColor ?? boundary.backgroundColor
        ..fontColor = fontColor ?? boundary.fontColor
        ..borderColor = borderColor ?? boundary.borderColor
        ..shadowing = shadowing ?? boundary.shadowing;
    }
    boundaryStack.add(alias);
  }

  String _readBoundaryType(
    _Argument argument,
    String defaultType,
    void Function(String key, String value) onAttribute,
    int atLine,
  ) {
    if (argument is _TextArgument) return argument.value;
    final map = argument as _MapArgument;
    if (map.values.length != 1) {
      _invalid(tr("Boundary type needs one value"), atLine);
    }
    if (map.values.containsKey('type')) return map.values['type']!;
    // A named value in the type slot can populate another DB field but leaves
    // the DB type absent, which this required model field cannot represent.
    final entry = map.values.entries.single;
    onAttribute(entry.key, entry.value);
    _invalid(
      tr("Boundary type is missing after named attribute \"{0}\"", [entry.key]),
      atLine,
    );
  }

  void _addRelation(String statement, List<_Argument> args, int atLine) {
    final relationKind = _relationKinds[statement]!;
    final values = statement == 'RelIndex' ? args.skip(1).toList() : args;
    if (values.length < 3) {
      _invalid(
        tr("{0} needs source, destination, and label", [statement]),
        atLine,
      );
    }
    final from = _text(values[0], tr("source alias"), atLine);
    final to = _text(values[1], tr("destination alias"), atLine);
    final label = _text(values[2], 'label', atLine);
    final technology = values.length > 3
        ? _readRelationField(values[3], 'techn', atLine)
        : '';
    final description = values.length > 4
        ? _readRelationField(values[4], 'descr', atLine)
        : '';
    _readAttributeTail(values, 5, atLine, const [
      'sprite',
      'tags',
      'link',
    ], (_, _) {});

    final existing = relations
        .where((item) => item.from == from && item.to == to)
        .firstOrNull;
    if (existing == null) {
      relations.add(
        _RelationData(
          kind: relationKind,
          from: from,
          to: to,
          label: label,
          technology: technology,
          description: description,
          wrap: itemWrap,
        ),
      );
    } else {
      // The DB reuses the first from/to pair and retains applied style fields.
      existing
        ..kind = relationKind
        ..label = label
        ..technology = technology
        ..description = description
        ..wrap = itemWrap;
    }
  }

  String _readRelationField(
    _Argument argument,
    String expectedAttribute,
    int atLine,
  ) {
    if (argument is _TextArgument) return argument.value;
    final map = argument as _MapArgument;
    if (map.values.length == 1 && map.values.containsKey(expectedAttribute)) {
      return map.values[expectedAttribute]!;
    }
    _unsupportedAttribute(map.values.keys.first, atLine);
  }

  void _readAttributeTail(
    List<_Argument> args,
    int start,
    int atLine,
    List<String> positionalNames,
    void Function(String key, String value) onAttribute,
  ) {
    for (var i = start; i < args.length; i++) {
      final argument = args[i];
      if (argument is _TextArgument) {
        final field = i - start < positionalNames.length
            ? positionalNames[i - start]
            : tr("extra argument");
        _invalid(
          tr("The {0} attribute is not supported natively", [field]),
          atLine,
        );
      }
      final map = argument as _MapArgument;
      for (final entry in map.values.entries) {
        onAttribute(entry.key, entry.value);
      }
    }
  }

  void _updateElementStyle(List<_Argument> args, int atLine) {
    if (args.isEmpty || args.length > 10) {
      _invalid(
        tr("UpdateElementStyle needs an alias and at most nine style values"),
        atLine,
      );
    }
    final alias = _text(args[0], tr("element alias"), atLine);
    final properties = <String, String>{};
    const names = [
      'bgColor',
      'fontColor',
      'borderColor',
      'shadowing',
      'shape',
      'sprite',
      'techn',
      'legendText',
      'legendSprite',
    ];
    for (var i = 1; i < args.length; i++) {
      final argument = args[i];
      if (argument is _MapArgument) {
        properties.addAll(argument.values);
      } else {
        properties[names[i - 1]] = (argument as _TextArgument).value;
      }
    }
    for (final entry in properties.entries) {
      if (const {
        'bgColor',
        'fontColor',
        'borderColor',
        'shadowing',
        'techn',
      }.contains(entry.key)) {
        continue;
      }
      if (entry.key == 'shape' && entry.value.isEmpty) continue;
      _unsupportedAttribute(entry.key, atLine);
    }

    final shape = shapes.where((item) => item.alias == alias).firstOrNull;
    final boundary = shape == null
        ? boundaries.where((item) => item.alias == alias).firstOrNull
        : null;
    if (shape == null && boundary == null) return;
    final _StyleData target = shape ?? boundary!;
    for (final entry in properties.entries) {
      switch (entry.key) {
        case 'bgColor':
          target.backgroundColor = entry.value;
        case 'fontColor':
          target.fontColor = entry.value;
        case 'borderColor':
          target.borderColor = entry.value;
        case 'shadowing':
          target.shadowing = entry.value;
        case 'techn':
          target.technology = entry.value;
      }
    }
  }

  void _updateRelationStyle(List<_Argument> args, int atLine) {
    if (args.length < 2 || args.length > 6) {
      _invalid(
        tr(
          "UpdateRelStyle needs source and destination aliases and at most four style values",
        ),
        atLine,
      );
    }
    final from = _text(args[0], tr("source alias"), atLine);
    final to = _text(args[1], tr("destination alias"), atLine);
    final properties = <String, String>{};
    const names = ['textColor', 'lineColor', 'offsetX', 'offsetY'];
    for (var i = 2; i < args.length; i++) {
      final argument = args[i];
      if (argument is _MapArgument) {
        properties.addAll(argument.values);
      } else {
        properties[names[i - 2]] = (argument as _TextArgument).value;
      }
    }
    for (final key in properties.keys) {
      if (!const {
        'textColor',
        'lineColor',
        'offsetX',
        'offsetY',
      }.contains(key)) {
        _unsupportedAttribute(key, atLine);
      }
    }
    final relation = relations
        .where((item) => item.from == from && item.to == to)
        .firstOrNull;
    if (relation == null) return;
    for (final entry in properties.entries) {
      switch (entry.key) {
        case 'textColor':
          relation.textColor = entry.value;
        case 'lineColor':
          relation.lineColor = entry.value;
        case 'offsetX':
          relation.offsetX = _parseIntPrefix(entry.value, entry.key, atLine);
        case 'offsetY':
          relation.offsetY = _parseIntPrefix(entry.value, entry.key, atLine);
      }
    }
  }

  void _updateLayout(List<_Argument> args, int atLine) {
    if (args.length != 2) {
      _invalid(
        tr("UpdateLayoutConfig needs shapeInRow and boundaryInRow"),
        atLine,
      );
    }
    final shape = _argumentValue(args[0], 'shapeInRow', atLine);
    final boundary = _argumentValue(args[1], 'boundaryInRow', atLine);
    final shapeValue = _parseIntPrefix(shape, 'shapeInRow', atLine);
    final boundaryValue = _parseIntPrefix(boundary, 'boundaryInRow', atLine);
    if (shapeValue != null && shapeValue > 0) shapeInRow = shapeValue;
    if (boundaryValue != null && boundaryValue > 0) {
      boundaryInRow = boundaryValue;
    }
  }

  int? _parseIntPrefix(String value, String field, int atLine) {
    final match = RegExp(r'^\s*([+-]?\d+)').firstMatch(value);
    if (match == null) {
      if (field == 'shapeInRow' || field == 'boundaryInRow') return null;
      _invalid(tr("{0} must begin with an integer", [field]), atLine);
    }
    final parsed = int.tryParse(match.group(1)!);
    if (parsed == null && field != 'shapeInRow' && field != 'boundaryInRow') {
      _invalid(
        tr("{0} is outside the supported integer range", [field]),
        atLine,
      );
    }
    return parsed;
  }

  String _argumentValue(_Argument argument, String field, int atLine) {
    if (argument is _TextArgument) return argument.value;
    final values = (argument as _MapArgument).values;
    if (values.length != 1) {
      _invalid(tr("{0} must have one value", [field]), atLine);
    }
    return values.values.single;
  }

  String _text(_Argument argument, String field, int atLine) {
    if (argument is _MapArgument) {
      _invalid(tr("{0} must be a string", [field]), atLine);
    }
    return (argument as _TextArgument).value;
  }

  String? _optionalTextOrAttributes(
    _Argument argument,
    void Function(String key, String value) onAttribute,
  ) {
    if (argument is _TextArgument) return argument.value;
    for (final entry in (argument as _MapArgument).values.entries) {
      onAttribute(entry.key, entry.value);
    }
    return null;
  }

  Never _unsupportedAttribute(String name, int atLine) => _invalid(
    tr("The \"{0}\" attribute is not supported natively", [name]),
    atLine,
  );

  void _skipIgnored() {
    while (index < source.length) {
      final c = _peek();
      if (_isHorizontal(source.codeUnitAt(index))) {
        index++;
      } else if (c == '\n' || c == '\r') {
        _consumeNewline();
      } else if (_startsWith('%%')) {
        if (_startsWith('%%{')) {
          _readInitDirective();
        } else {
          _skipComment();
        }
      } else {
        break;
      }
    }
  }

  void _skipWhitespace() {
    while (index < source.length && _isWhitespace(source.codeUnitAt(index))) {
      _consumeOneWhitespace();
    }
  }

  void _skipHorizontal() {
    while (index < source.length && _isHorizontal(source.codeUnitAt(index))) {
      index++;
    }
  }

  void _skipComment() {
    if (_startsWith('%%{')) {
      _invalid(tr("Unsupported Mermaid directive"));
    }
    while (index < source.length && _peek() != '\n' && _peek() != '\r') {
      index++;
    }
  }

  void _readInitDirective() {
    final directiveLine = line;
    var end = index;
    while (end < source.length && source[end] != '\n' && source[end] != '\r') {
      end++;
    }
    final compact = source.substring(index, end).replaceAll(RegExp(r'\s+'), '');
    if (compact == '%%{init:{"c4":{"wrap":true}}}%%') {
      configWrap = true;
    } else if (compact == '%%{init:{"c4":{"wrap":false}}}%%') {
      configWrap = false;
    } else {
      _invalid(
        tr("Only the Mermaid init setting c4.wrap is supported natively"),
        directiveLine,
      );
    }
    index = end;
    if (index < source.length) _consumeNewline();
  }

  void _advanceLineEnd(int expectedLine) {
    _skipHorizontal();
    if (index < source.length && _peek() != '\n' && _peek() != '\r') {
      _invalid(tr("Unexpected text after statement"), expectedLine);
    }
    if (index < source.length) _consumeNewline();
  }

  void _finishCurrentStatementLine() {
    _skipHorizontal();
    if (_startsWith('%%')) _skipComment();
    if (index < source.length && _peek() != '\n' && _peek() != '\r') {
      _invalid(tr("Unexpected text after statement"));
    }
    if (index < source.length) _consumeNewline();
  }

  void _consumeNewline() {
    if (_peek() == '\r') {
      index++;
      if (index < source.length && _peek() == '\n') index++;
    } else if (_peek() == '\n') {
      index++;
    }
    line++;
  }

  void _consumeOneWhitespace() {
    if (_peek() == '\r' || _peek() == '\n') {
      _consumeNewline();
    } else {
      index++;
    }
  }

  String _peek() => index < source.length ? source[index] : '\u0000';

  bool _startsWith(String value) => source.startsWith(value, index);

  static bool _isWordChar(int code) =>
      (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      (code >= 48 && code <= 57) ||
      code == 95;

  static bool _isHorizontal(int code) => code == 32 || code == 9 || code == 12;
  static bool _isWhitespace(int code) =>
      _isHorizontal(code) || code == 10 || code == 13;
}

enum _EntityFamily { person, typed }

enum _BoundaryFamily { group, deployment }

class _EntitySpec {
  const _EntitySpec(this.kind, this.family);
  final String kind;
  final _EntityFamily family;
}

class _BoundarySpec {
  const _BoundarySpec(
    this.kind,
    this.defaultType,
    this.family, [
    this.nodeType,
  ]);
  final String kind;
  final String defaultType;
  final _BoundaryFamily family;
  final String? nodeType;
}

sealed class _Argument {
  const _Argument();
}

class _TextArgument extends _Argument {
  const _TextArgument(this.value);
  final String value;
}

class _MapArgument extends _Argument {
  const _MapArgument(this.values);
  final Map<String, String> values;
}

abstract interface class _StyleData {
  String? get backgroundColor;
  set backgroundColor(String? value);
  String? get fontColor;
  set fontColor(String? value);
  String? get borderColor;
  set borderColor(String? value);
  String? get shadowing;
  set shadowing(String? value);
  String? get technology;
  set technology(String? value);
}

class _ShapeData implements _StyleData {
  _ShapeData({
    required this.alias,
    required this.kind,
    required this.label,
    required this.parentBoundary,
    required this.wrap,
    this.type,
    this.technology,
    this.description,
    this.backgroundColor,
    this.fontColor,
    this.borderColor,
    this.shadowing,
  });

  final String alias;
  String kind;
  String label;
  String parentBoundary;
  String? type;
  @override
  String? technology;
  String? description;
  bool wrap;
  @override
  String? backgroundColor;
  @override
  String? fontColor;
  @override
  String? borderColor;
  @override
  String? shadowing;

  NativeC4Shape toModel() => NativeC4Shape(
    alias: alias,
    kind: kind,
    label: label,
    parentBoundary: parentBoundary,
    type: type,
    technology: technology,
    description: description,
    wrap: wrap,
    backgroundColor: backgroundColor,
    fontColor: fontColor,
    borderColor: borderColor,
    shadowing: shadowing,
  );
}

class _BoundaryData implements _StyleData {
  _BoundaryData({
    required this.alias,
    required this.label,
    required this.type,
    required this.parentBoundary,
    required this.kind,
    required this.wrap,
    this.description,
    this.technology,
    this.nodeType,
    this.backgroundColor,
    this.fontColor,
    this.borderColor,
    this.shadowing,
  });

  final String alias;
  String label;
  String type;
  String parentBoundary;
  String kind;
  String? description;
  @override
  String? technology;
  bool wrap;
  String? nodeType;
  @override
  String? backgroundColor;
  @override
  String? fontColor;
  @override
  String? borderColor;
  @override
  String? shadowing;

  NativeC4Boundary toModel() => NativeC4Boundary(
    alias: alias,
    label: label,
    type: type,
    parentBoundary: parentBoundary,
    kind: kind,
    description: description,
    technology: technology,
    wrap: wrap,
    nodeType: nodeType,
    backgroundColor: backgroundColor,
    fontColor: fontColor,
    borderColor: borderColor,
    shadowing: shadowing,
  );
}

class _RelationData {
  _RelationData({
    required this.kind,
    required this.from,
    required this.to,
    required this.label,
    required this.technology,
    required this.description,
    required this.wrap,
  });

  String kind;
  final String from;
  final String to;
  String label;
  String technology;
  String description;
  bool wrap;
  String? textColor;
  String? lineColor;
  int? offsetX;
  int? offsetY;

  NativeC4Relation toModel() => NativeC4Relation(
    kind: kind,
    from: from,
    to: to,
    label: label,
    technology: technology,
    description: description,
    wrap: wrap,
    textColor: textColor,
    lineColor: lineColor,
    offsetX: offsetX,
    offsetY: offsetY,
  );
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
