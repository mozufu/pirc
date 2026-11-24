import '../render_l10n.dart';
import 'journey_model.dart';

/// Parses the bounded Mermaid 11.17.2 user-journey grammar used by the native
/// renderer. It supports the source header, title/accessibility metadata,
/// sections and scored tasks with optional comma-separated actors.
///
/// Init directives, semicolon-separated task statements and non-numeric scores
/// are rejected explicitly. The Jison parser accepts some malformed score
/// strings as NaN; those diagrams produce invalid SVG coordinates and are not
/// represented as drawable native charts.
NativeMermaidJourneyDiagram parseNativeMermaidJourney(String source) {
  final normalized = source.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (normalized.length > 50000) {
    throw FormatException(
      tr("Mermaid journey exceeds the default 50000 character limit"),
    );
  }
  final sections = <NativeMermaidJourneySection>[];
  final tasks = <NativeMermaidJourneyTask>[];
  final actors = <String>{};
  var title = '';
  var accessibleTitle = '';
  var accessibleDescription = '';
  var currentSection = '';
  var headerSeen = false;

  Never invalid(int line, String message) => throw FormatException(
    tr("Parse error on line {0}: {1}", [line, message]),
  );

  final lines = normalized.split('\n');
  for (var index = 0; index < lines.length; index++) {
    final lineNumber = index + 1;
    final sourceLine = lines[index];
    final line = sourceLine.trimLeft();
    if (line.trim().isEmpty) continue;
    if (line.startsWith('%%{')) {
      invalid(lineNumber, tr("Journey init directives are not supported"));
    }
    if (line.startsWith('#') ||
        (line.startsWith('%') && !line.startsWith('%{'))) {
      continue;
    }

    final header = RegExp(
      r'^journey\b',
      caseSensitive: false,
    ).matchAsPrefix(line);
    if (header != null) {
      if (headerSeen) {
        invalid(lineNumber, tr("Unexpected second journey header"));
      }
      if (line.substring(header.end).trim().isNotEmpty) {
        invalid(lineNumber, tr("Unexpected text after journey header"));
      }
      headerSeen = true;
      continue;
    }
    if (!headerSeen) invalid(lineNumber, tr("Expected journey header"));

    if (RegExp(r'^title\s', caseSensitive: false).hasMatch(line)) {
      if (line.contains(';')) {
        invalid(
          lineNumber,
          tr("Semicolon-separated statements are unsupported"),
        );
      }
      final token = _beforeComment(line);
      // The pinned parser's action uses substr(6), preserving extra spaces.
      title = token.length > 6 ? token.substring(6) : '';
      continue;
    }

    final accTitle = RegExp(
      r'^accTitle\s*:\s*',
      caseSensitive: false,
    ).matchAsPrefix(line);
    if (accTitle != null) {
      accessibleTitle = _beforeComment(line.substring(accTitle.end)).trim();
      continue;
    }

    final accDescription = RegExp(
      r'^accDescr\s*:\s*',
      caseSensitive: false,
    ).matchAsPrefix(line);
    if (accDescription != null) {
      accessibleDescription = _beforeComment(
        line.substring(accDescription.end),
      ).trim();
      continue;
    }
    final accDescriptionBlock = RegExp(
      r'^accDescr\s*\{\s*',
      caseSensitive: false,
    ).matchAsPrefix(line);
    if (accDescriptionBlock != null) {
      final descriptionLines = <String>[];
      var foundEnd = false;
      final firstRemainder = line.substring(accDescriptionBlock.end);
      final firstClose = firstRemainder.indexOf('}');
      if (firstClose >= 0) {
        descriptionLines.add(firstRemainder.substring(0, firstClose));
        foundEnd = true;
      } else {
        if (firstRemainder.isNotEmpty) descriptionLines.add(firstRemainder);
        while (++index < lines.length) {
          final blockLine = lines[index];
          final close = blockLine.indexOf('}');
          if (close >= 0) {
            descriptionLines.add(blockLine.substring(0, close));
            foundEnd = true;
            break;
          }
          descriptionLines.add(blockLine);
        }
      }
      if (!foundEnd) invalid(lineNumber, tr("Unterminated accDescr block"));
      accessibleDescription = descriptionLines
          .join('\n')
          .trim()
          .replaceAll(RegExp(r'\n\s+'), '\n');
      continue;
    }

    if (RegExp(r'^section\s', caseSensitive: false).hasMatch(line)) {
      if (line.contains(';')) {
        invalid(
          lineNumber,
          tr("Semicolon-separated statements are unsupported"),
        );
      }
      final token = _beforeComment(line);
      if (token.contains(':')) {
        invalid(lineNumber, tr("Section names cannot contain a colon"));
      }
      // The pinned Jison action uses substr(8), preserving extra spaces.
      currentSection = token.length > 8 ? token.substring(8) : '';
      sections.add(
        NativeMermaidJourneySection(
          index: sections.length,
          name: currentSection,
          sourceLine: lineNumber,
        ),
      );
      continue;
    }

    if (line.contains(';')) {
      invalid(lineNumber, tr("Semicolon-separated statements are unsupported"));
    }
    final taskLine = _beforeComment(line);
    final colon = taskLine.indexOf(':');
    if (colon <= 0) invalid(lineNumber, tr("Expected a scored task"));
    final label = taskLine.substring(0, colon);
    if (label.trim().isEmpty) invalid(lineNumber, tr("Task label is empty"));
    final values = taskLine.substring(colon + 1).split(':');
    final scoreText = values.first.trim();
    final score = _number(scoreText);
    if (score == null || !score.isFinite) {
      invalid(lineNumber, tr("Task score must be a finite number"));
    }
    final taskActors = values.length > 1
        ? values[1].split(',').map((actor) => actor.trim()).toList()
        : const <String>[];
    if (taskActors.any((actor) => actor.isEmpty)) {
      invalid(lineNumber, tr("Task actor names cannot be empty"));
    }
    actors.addAll(taskActors);
    tasks.add(
      NativeMermaidJourneyTask(
        index: tasks.length,
        label: label,
        sectionName: currentSection,
        score: score,
        sourceLine: lineNumber,
        actors: taskActors,
      ),
    );
  }

  if (!headerSeen) {
    throw FormatException(tr("Missing Mermaid journey header"));
  }
  final sortedActors = actors.toList()..sort();
  return NativeMermaidJourneyDiagram(
    title: title,
    accessibleTitle: accessibleTitle,
    accessibleDescription: accessibleDescription,
    sections: sections,
    tasks: tasks,
    actors: sortedActors,
  );
}

String _beforeComment(String value) {
  var end = value.length;
  final hash = value.indexOf('#');
  if (hash >= 0 && hash < end) end = hash;
  return value.substring(0, end);
}

double? _number(String value) {
  if (value.isEmpty) return 0;
  final parsed = double.tryParse(value);
  if (parsed != null) return parsed;
  final lower = value.toLowerCase();
  if (lower.startsWith('0x')) {
    final integer = int.tryParse(value.substring(2), radix: 16);
    return integer?.toDouble();
  }
  if (lower.startsWith('0b')) {
    final integer = int.tryParse(value.substring(2), radix: 2);
    return integer?.toDouble();
  }
  if (lower.startsWith('0o')) {
    final integer = int.tryParse(value.substring(2), radix: 8);
    return integer?.toDouble();
  }
  return null;
}
