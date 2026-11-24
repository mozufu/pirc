import '../render_l10n.dart';
import 'dart:convert';

import 'packet_model.dart';

const int _maxPacketSourceLength = 50000;
const int _maxPacketFields = 10000;
const int _maxPacketRows = 10000;
const int _maxPacketBitsPerRow = 256;
const double _maxPacketGeometryValue = 512;

/// Parses the supported static subset of Mermaid 11.17.2 packet diagrams.
///
/// Both `packet` and `packet-beta` use the same pinned grammar. A source-level
/// `init` directive is supported only for a JSON `packet` object containing
/// the seven geometry keys modeled by [NativeMermaidPacketConfig].
NativeMermaidPacketDiagram parseNativeMermaidPacket(String source) {
  if (source.length > _maxPacketSourceLength) {
    throw FormatException(
      tr("Mermaid packet source exceeds the 50,000 character limit"),
    );
  }

  final lines = source
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  final fields = <NativeMermaidPacketField>[];
  final rows = <List<NativeMermaidPacketSegment>>[];
  var word = <NativeMermaidPacketSegment>[];
  var rowNumber = 1;
  var lastBit = -1;
  var sawHeader = false;
  var title = '';
  var accessibleTitle = '';
  var accessibleDescription = '';
  var config = const NativeMermaidPacketConfig();
  var sawInitDirective = false;

  for (var index = 0; index < lines.length; index++) {
    final lineNumber = index + 1;
    final line = lines[index].trim();
    if (line.isEmpty) continue;
    if (line == '---' || line.startsWith('--- ')) {
      throw FormatException(
        tr("Packet YAML frontmatter is unsupported by the native renderer"),
        source,
        lineNumber,
      );
    }
    if (line.startsWith('%%{')) {
      if (sawHeader) {
        throw FormatException(
          tr("Packet init directives must appear before the diagram header"),
          source,
          lineNumber,
        );
      }
      if (sawInitDirective) {
        throw FormatException(
          tr("Only one packet init directive is supported"),
          source,
          lineNumber,
        );
      }
      config = _parsePacketInitDirective(line, config, source, lineNumber);
      sawInitDirective = true;
      continue;
    }
    if (line.startsWith('%%')) continue;

    final statement = _stripPacketComment(lines[index]).trim();
    if (statement.isEmpty) continue;
    if (!sawHeader) {
      if (statement != 'packet' && statement != 'packet-beta') {
        throw FormatException(
          tr("Expected packet or packet-beta header, found: {0}", [statement]),
          source,
          lineNumber,
        );
      }
      sawHeader = true;
      continue;
    }
    if (statement == 'packet' || statement == 'packet-beta') {
      throw FormatException(
        tr("Unexpected second packet header"),
        source,
        lineNumber,
      );
    }

    final titleMatch = RegExp(r'^title(?:[\t ]+(.*))?$').firstMatch(statement);
    if (titleMatch != null) {
      title = (titleMatch[1] ?? '').trim();
      continue;
    }

    final accTitleMatch = RegExp(
      r'^accTitle[\t ]*:[\t ]*(.*)$',
    ).firstMatch(statement);
    if (accTitleMatch != null) {
      accessibleTitle = accTitleMatch[1]!.trim();
      continue;
    }

    final accDescriptionMatch = RegExp(
      r'^accDescr[\t ]*:[\t ]*(.*)$',
    ).firstMatch(statement);
    if (accDescriptionMatch != null) {
      accessibleDescription = accDescriptionMatch[1]!.trim();
      continue;
    }

    final inlineDescription = RegExp(
      r'^accDescr[\t ]*\{(.*)\}[\t ]*$',
    ).firstMatch(statement);
    if (inlineDescription != null) {
      accessibleDescription = inlineDescription[1]!.trim();
      continue;
    }

    if (RegExp(r'^accDescr[\t ]*\{[\t ]*$').hasMatch(statement)) {
      final descriptionLines = <String>[];
      var closed = false;
      while (++index < lines.length) {
        final row = lines[index];
        final close = row.indexOf('}');
        if (close >= 0) {
          descriptionLines.add(row.substring(0, close));
          final trailing = _stripPacketComment(row.substring(close + 1)).trim();
          if (trailing.isNotEmpty) {
            throw FormatException(
              tr("Unexpected text after accDescr block"),
              source,
              index + 1,
            );
          }
          closed = true;
          break;
        }
        descriptionLines.add(row);
      }
      if (!closed) {
        throw FormatException(
          tr("Unclosed accDescr block"),
          source,
          lineNumber,
        );
      }
      accessibleDescription = descriptionLines.join('\n').trim();
      continue;
    }

    final field = _parsePacketField(statement, source, lineNumber);
    if (fields.length >= _maxPacketFields) {
      throw FormatException(
        tr("Mermaid packet exceeds the 10,000 field limit"),
        source,
        lineNumber,
      );
    }

    var start = field.declaredStart ?? lastBit + 1;
    final declaredStart = field.declaredStart;
    if (declaredStart != null && declaredStart != lastBit + 1) {
      throw FormatException(
        tr("Packet field {0} is not contiguous; expected {1}", [
          declaredStart,
          lastBit + 1,
        ]),
        source,
        lineNumber,
      );
    }
    if (field.declaredBits == 0) {
      throw FormatException(
        tr("Packet field {0} is invalid; a field cannot have zero bits", [
          start,
        ]),
        source,
        lineNumber,
      );
    }

    final end = field.declaredEnd ?? start + (field.declaredBits ?? 1) - 1;
    if (end < start) {
      throw FormatException(
        tr("Packet field {0}-{1} is invalid; end must not precede start", [
          start,
          end,
        ]),
        source,
        lineNumber,
      );
    }
    var bitCount = field.declaredBits ?? end - start + 1;
    if (end >= config.bitsPerRow * _maxPacketRows) {
      throw FormatException(
        tr("Mermaid packet exceeds the 10,000 row limit"),
        source,
        lineNumber,
      );
    }

    final fieldIndex = fields.length;
    final parsedField = NativeMermaidPacketField(
      startBit: start,
      endBit: end,
      bits: bitCount,
      label: field.label,
      syntax: field.syntax,
      declaredStart: field.declaredStart,
      declaredEnd: field.declaredEnd,
      declaredBits: field.declaredBits,
    );
    fields.add(parsedField);
    lastBit = end;

    while (rows.length < _maxPacketRows) {
      final rowEndExclusive = rowNumber * config.bitsPerRow;
      if (end + 1 <= rowEndExclusive) {
        word.add(
          NativeMermaidPacketSegment(
            startBit: start,
            endBit: end,
            bits: bitCount,
            label: parsedField.label,
            fieldIndex: fieldIndex,
          ),
        );
        if (end + 1 == rowEndExclusive) {
          rows.add(word);
          word = <NativeMermaidPacketSegment>[];
          rowNumber++;
        }
        break;
      }

      final segmentEnd = rowEndExclusive - 1;
      word.add(
        NativeMermaidPacketSegment(
          startBit: start,
          endBit: segmentEnd,
          // Keep PacketDB's value; it is one less than the inclusive length
          // when a field is split across a row boundary.
          bits: segmentEnd - start,
          label: parsedField.label,
          fieldIndex: fieldIndex,
        ),
      );
      rows.add(word);
      word = <NativeMermaidPacketSegment>[];
      start = rowEndExclusive;
      bitCount = end - start;
      rowNumber++;
    }
  }

  if (!sawHeader) {
    throw FormatException(tr("Expected packet or packet-beta header"));
  }
  if (word.isNotEmpty && rows.length < _maxPacketRows) rows.add(word);

  return NativeMermaidPacketDiagram(
    fields: fields,
    rows: rows.map(NativeMermaidPacketRow.new),
    title: title,
    accessibleTitle: accessibleTitle,
    accessibleDescription: accessibleDescription,
    config: config,
  );
}

NativeMermaidPacketConfig _parsePacketInitDirective(
  String directive,
  NativeMermaidPacketConfig previous,
  String source,
  int lineNumber,
) {
  final match = RegExp(
    r'^%%\{\s*init\s*:\s*(.*)\s*\}%%$',
  ).firstMatch(directive);
  if (match == null) {
    throw FormatException(
      tr("Only JSON packet init directives are supported"),
      source,
      lineNumber,
    );
  }

  Object? decoded;
  try {
    decoded = jsonDecode(match[1]!.trim());
  } on FormatException {
    throw FormatException(
      tr("Packet init directive must contain valid JSON"),
      source,
      lineNumber,
    );
  }
  if (decoded is! Map<String, dynamic>) {
    throw FormatException(
      tr("Packet init directive must be a JSON object"),
      source,
      lineNumber,
    );
  }
  if (decoded.keys.any((key) => key != 'packet')) {
    throw FormatException(
      tr("Packet init directive may only contain the packet object"),
      source,
      lineNumber,
    );
  }
  final packet = decoded['packet'];
  if (packet is! Map<String, dynamic>) {
    throw FormatException(
      tr("Packet init directive requires a packet object"),
      source,
      lineNumber,
    );
  }

  var rowHeight = previous.rowHeight;
  var bitWidth = previous.bitWidth;
  var bitsPerRow = previous.bitsPerRow;
  var showBits = previous.showBits;
  var paddingX = previous.paddingX;
  var paddingY = previous.paddingY;
  var useMaxWidth = previous.useMaxWidth;
  for (final entry in packet.entries) {
    switch (entry.key) {
      case 'bitsPerRow':
        final value = entry.value;
        if (value is! int || value < 1 || value > _maxPacketBitsPerRow) {
          throw FormatException(
            'packet.bitsPerRow must be an integer from 1 to $_maxPacketBitsPerRow',
            source,
            lineNumber,
          );
        }
        bitsPerRow = value;
        break;
      case 'bitWidth':
        bitWidth = _readPacketGeometryNumber(
          entry.value,
          'packet.bitWidth',
          source,
          lineNumber,
          allowZero: false,
        );
        break;
      case 'showBits':
        if (entry.value is! bool) {
          throw FormatException(
            'packet.showBits must be a boolean',
            source,
            lineNumber,
          );
        }
        showBits = entry.value as bool;
        break;
      case 'rowHeight':
        rowHeight = _readPacketGeometryNumber(
          entry.value,
          'packet.rowHeight',
          source,
          lineNumber,
          allowZero: false,
        );
        break;
      case 'paddingX':
        paddingX = _readPacketGeometryNumber(
          entry.value,
          'packet.paddingX',
          source,
          lineNumber,
          allowZero: true,
        );
        break;
      case 'paddingY':
        paddingY = _readPacketGeometryNumber(
          entry.value,
          'packet.paddingY',
          source,
          lineNumber,
          allowZero: true,
        );
        break;
      case 'useMaxWidth':
        if (entry.value is! bool) {
          throw FormatException(
            'packet.useMaxWidth must be a boolean',
            source,
            lineNumber,
          );
        }
        useMaxWidth = entry.value as bool;
        break;
      default:
        throw FormatException(
          tr("Unsupported packet init setting: {0}", [entry.key]),
          source,
          lineNumber,
        );
    }
  }
  if (paddingX >= bitWidth) {
    throw FormatException(
      tr("packet.paddingX must be smaller than packet.bitWidth"),
      source,
      lineNumber,
    );
  }

  return NativeMermaidPacketConfig(
    rowHeight: rowHeight,
    bitWidth: bitWidth,
    bitsPerRow: bitsPerRow,
    showBits: showBits,
    paddingX: paddingX,
    paddingY: paddingY,
    useMaxWidth: useMaxWidth,
    labelFontSize: previous.labelFontSize,
    bitFontSize: previous.bitFontSize,
    titleFontSize: previous.titleFontSize,
  );
}

double _readPacketGeometryNumber(
  Object? value,
  String key,
  String source,
  int lineNumber, {
  required bool allowZero,
}) {
  if (value is! num || !value.toDouble().isFinite) {
    throw FormatException(
      tr("{0} must be a finite number", [key]),
      source,
      lineNumber,
    );
  }
  final number = value.toDouble();
  final minimum = allowZero ? 0 : 0.01;
  if (number < minimum || number > _maxPacketGeometryValue) {
    final range = allowZero
        ? tr("0 to {0}", [_maxPacketGeometryValue])
        : tr("positive and at most {0}", [_maxPacketGeometryValue]);
    throw FormatException(
      tr("{0} must be {1}", [key, range]),
      source,
      lineNumber,
    );
  }
  return number;
}

class _ParsedPacketField {
  const _ParsedPacketField({
    required this.label,
    required this.syntax,
    this.declaredStart,
    this.declaredEnd,
    this.declaredBits,
  });

  final String label;
  final NativeMermaidPacketFieldSyntax syntax;
  final int? declaredStart;
  final int? declaredEnd;
  final int? declaredBits;
}

_ParsedPacketField _parsePacketField(
  String statement,
  String source,
  int lineNumber,
) {
  final match = RegExp(
    r'^(?:(0|[1-9][0-9]*)(?:[\t ]*-[\t ]*(0|[1-9][0-9]*))?|\+[\t ]*(0|[1-9][0-9]*))[\t ]*:[\t ]*(.+)$',
  ).firstMatch(statement);
  if (match == null) {
    throw FormatException(
      tr("Invalid packet field syntax: {0}", [statement]),
      source,
      lineNumber,
    );
  }

  final label = _parsePacketString(match[4]!.trim(), source, lineNumber);
  final start = match[1] == null ? null : int.tryParse(match[1]!);
  final end = match[2] == null ? null : int.tryParse(match[2]!);
  final bits = match[3] == null ? null : int.tryParse(match[3]!);
  if (match[1] != null && start == null ||
      match[2] != null && end == null ||
      match[3] != null && bits == null) {
    throw FormatException(
      tr("Packet bit range is outside the supported integer range"),
      source,
      lineNumber,
    );
  }

  final syntax = bits != null
      ? NativeMermaidPacketFieldSyntax.count
      : end != null
      ? NativeMermaidPacketFieldSyntax.explicitRange
      : NativeMermaidPacketFieldSyntax.explicitBit;
  return _ParsedPacketField(
    label: label,
    syntax: syntax,
    declaredStart: start,
    declaredEnd: end,
    declaredBits: bits,
  );
}

String _parsePacketString(String token, String source, int lineNumber) {
  if (token.length < 2 ||
      (token[0] != '"' && token[0] != "'") ||
      token[token.length - 1] != token[0]) {
    throw FormatException(
      tr("Packet labels must be quoted strings"),
      source,
      lineNumber,
    );
  }

  final quote = token[0];
  final result = StringBuffer();
  for (var index = 1; index < token.length - 1; index++) {
    final char = token[index];
    if (char == quote) {
      throw FormatException(
        tr("Unexpected quote in packet label"),
        source,
        lineNumber,
      );
    }
    if (char != r'\') {
      result.write(char);
      continue;
    }
    if (++index >= token.length - 1) {
      throw FormatException(
        tr("Unterminated packet label escape"),
        source,
        lineNumber,
      );
    }
    final escaped = token[index];
    switch (escaped) {
      case 'n':
        result.write('\n');
        break;
      case 'r':
        result.write('\r');
        break;
      case 't':
        result.write('\t');
        break;
      case 'b':
        result.write('\b');
        break;
      case 'f':
        result.write('\f');
        break;
      case 'v':
        result.write('\v');
        break;
      case '0':
        result.write('\u0000');
        break;
      case 'u':
        if (index + 5 > token.length - 1) {
          throw FormatException(
            'Invalid Unicode escape in packet label',
            source,
            lineNumber,
          );
        }
        final digits = token.substring(index + 1, index + 5);
        final codePoint = int.tryParse(digits, radix: 16);
        if (codePoint == null) {
          throw FormatException(
            'Invalid Unicode escape in packet label',
            source,
            lineNumber,
          );
        }
        result.writeCharCode(codePoint);
        index += 4;
        break;
      default:
        result.write(escaped);
        break;
    }
  }
  return result.toString();
}

String _stripPacketComment(String line) {
  var quote = '';
  var escaped = false;
  for (var index = 0; index < line.length - 1; index++) {
    final char = line[index];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (char == r'\' && quote.isNotEmpty) {
      escaped = true;
      continue;
    }
    if (quote.isEmpty && (char == '"' || char == "'")) {
      quote = char;
      continue;
    }
    if (char == quote && quote.isNotEmpty) {
      quote = '';
      continue;
    }
    if (quote.isEmpty && line.startsWith('%%', index)) {
      return line.substring(0, index);
    }
  }
  return line;
}
