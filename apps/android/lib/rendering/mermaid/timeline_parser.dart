import '../render_l10n.dart';
import 'timeline_model.dart';

/// Parses Mermaid 11.17.2 timeline tokens into a native source-order model.
///
/// The lexer is case-insensitive and accepts `timeline`, `timeline LR`, and
/// `timeline TD`. Mermaid init directives and YAML frontmatter are rejected
/// explicitly: this parser does not consume their config before dispatch.
NativeMermaidTimelineDiagram parseNativeMermaidTimeline(String source) {
  final normalized = source.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final processedForSize = normalized
      .replaceAll(RegExp(r'^\s*%%(?!\{)[^\n]+\n?', multiLine: true), '')
      .trimLeft();
  if (processedForSize.length > 50000) {
    throw FormatException(
      tr("Mermaid timeline exceeds the default 50000 character limit"),
    );
  }
  final parser = _TimelineParser(normalized);
  return parser.parse();
}

class _TimelineParser {
  _TimelineParser(this.source);

  final String source;
  final List<NativeMermaidTimelineSection> sections = [];
  final List<_TimelineTaskBuilder> tasks = [];
  int cursor = 0;
  int line = 1;
  bool headerSeen = false;
  String direction = 'LR';
  String currentSection = '';
  String title = '';
  String accessibleTitle = '';
  String accessibleDescription = '';

  static final _timelineLr = RegExp(
    r'timeline[ \t]+LR\b',
    caseSensitive: false,
  );
  static final _timelineTd = RegExp(
    r'timeline[ \t]+TD\b',
    caseSensitive: false,
  );
  static final _timeline = RegExp(r'timeline\b', caseSensitive: false);
  static final _title = RegExp(r'title\s[^\n]+', caseSensitive: false);
  static final _accTitle = RegExp(r'accTitle\s*:\s*', caseSensitive: false);
  static final _accDescription = RegExp(
    r'accDescr\s*:\s*',
    caseSensitive: false,
  );
  static final _accDescriptionMultiline = RegExp(
    r'accDescr\s*\{\s*',
    caseSensitive: false,
  );
  static final _section = RegExp(r'section\s[^:\n]+', caseSensitive: false);
  static final _event = RegExp(r':\s(?:[^:\n]|:(?!\s))+');
  static final _period = RegExp(r'[^#:\n]+');

  Never invalid(String message, [int? atLine]) => throw FormatException(
    tr("Invalid Mermaid timeline at line {0}: {1}", [atLine ?? line, message]),
  );

  NativeMermaidTimelineDiagram parse() {
    while (cursor < source.length) {
      _skipWhitespace();
      if (cursor >= source.length) break;

      final tokenLine = line;
      if (source.startsWith('%%{', cursor)) {
        invalid(
          tr("Mermaid configuration directives are unsupported"),
          tokenLine,
        );
      }

      if (!headerSeen && source.startsWith('---', cursor)) {
        invalid(tr("YAML frontmatter is unsupported"), tokenLine);
      }

      if (_consumeComment()) continue;

      final lr = _timelineLr.matchAsPrefix(source, cursor);
      final td = _timelineTd.matchAsPrefix(source, cursor);
      final timeline = _timeline.matchAsPrefix(source, cursor);
      if (lr != null || td != null || timeline != null) {
        if (!headerSeen) {
          headerSeen = true;
        }
        if (lr != null) {
          direction = 'LR';
          _consumeTo(lr.end);
        } else if (td != null) {
          direction = 'TD';
          _consumeTo(td.end);
        } else {
          _consumeTo(timeline!.end);
        }
        continue;
      }

      if (!headerSeen) {
        invalid(tr("Expected timeline header"), tokenLine);
      }

      final titleMatch = _title.matchAsPrefix(source, cursor);
      if (titleMatch != null) {
        final token = source.substring(cursor, titleMatch.end);
        // The source parser uses substr(6), assuming "title "; preserve this
        // behavior even when the matched separator is a tab or newline.
        title = token.length > 6 ? token.substring(6) : '';
        _consumeTo(titleMatch.end);
        continue;
      }

      final accTitleMatch = _accTitle.matchAsPrefix(source, cursor);
      if (accTitleMatch != null) {
        _consumeTo(accTitleMatch.end);
        accessibleTitle = _consumeLineValue().trim();
        continue;
      }

      final accDescriptionMatch = _accDescription.matchAsPrefix(source, cursor);
      if (accDescriptionMatch != null) {
        _consumeTo(accDescriptionMatch.end);
        accessibleDescription = _normalizeDescription(_consumeLineValue());
        continue;
      }

      final accDescriptionMultilineMatch = _accDescriptionMultiline
          .matchAsPrefix(source, cursor);
      if (accDescriptionMultilineMatch != null) {
        _consumeTo(accDescriptionMultilineMatch.end);
        final end = source.indexOf('}', cursor);
        if (end < 0) {
          invalid(tr("Unterminated accDescr block"), tokenLine);
        }
        accessibleDescription = _normalizeDescription(
          source.substring(cursor, end),
        );
        _consumeTo(end + 1);
        continue;
      }

      final sectionMatch = _section.matchAsPrefix(source, cursor);
      if (sectionMatch != null) {
        final token = source.substring(cursor, sectionMatch.end);
        currentSection = token.length > 8 ? token.substring(8) : '';
        sections.add(
          NativeMermaidTimelineSection(
            index: sections.length,
            name: currentSection,
            sourceLine: tokenLine,
          ),
        );
        _consumeTo(sectionMatch.end);
        continue;
      }

      final eventMatch = _event.matchAsPrefix(source, cursor);
      if (eventMatch != null) {
        if (tasks.isEmpty) {
          invalid(tr("Event has no preceding period"), tokenLine);
        }
        final token = source.substring(cursor, eventMatch.end);
        tasks.last.events.add(
          NativeMermaidTimelineEvent(
            text: token.length > 2 ? token.substring(2) : '',
            sourceLine: tokenLine,
          ),
        );
        _consumeTo(eventMatch.end);
        continue;
      }

      final periodMatch = _period.matchAsPrefix(source, cursor);
      if (periodMatch != null) {
        final period = source.substring(cursor, periodMatch.end);
        tasks.add(
          _TimelineTaskBuilder(
            id: tasks.length,
            period: period,
            sectionName: currentSection,
            sourceLine: tokenLine,
          ),
        );
        _consumeTo(periodMatch.end);
        continue;
      }

      // The pinned Jison parser reports this first line for an invalid
      // timeline token. Keep context on following lines, as the Web error
      // surface intentionally displays only the first line of the exception.
      throw FormatException(
        tr("Parse error on line {0}:\nUnexpected token \"{1}\"", [
          tokenLine,
          source[cursor],
        ]),
      );
    }

    if (!headerSeen) {
      throw FormatException(tr("Missing Mermaid timeline header"));
    }

    return NativeMermaidTimelineDiagram(
      direction: direction,
      title: title,
      accessibleTitle: accessibleTitle,
      accessibleDescription: accessibleDescription,
      sections: sections,
      tasks: tasks.map(
        (task) => NativeMermaidTimelineTask(
          id: task.id,
          period: task.period,
          sectionName: task.sectionName,
          sourceLine: task.sourceLine,
          score: 0,
          events: task.events,
        ),
      ),
    );
  }

  bool _consumeComment() {
    final current = source[cursor];
    if (current == '#' ||
        (current == '%' &&
            cursor + 1 < source.length &&
            source[cursor + 1] != '{')) {
      _consumeThroughNewline();
      return true;
    }

    // The pinned Jison lexer has a second comment rule matching exactly one
    // non-`}` character immediately followed by `%%` and the rest of that
    // physical line. Ordinary embedded `%%` with a longer prefix stays text.
    if (current != '}' &&
        cursor + 2 < source.length &&
        source.startsWith('%%', cursor + 1)) {
      _consumeThroughNewline();
      return true;
    }
    return false;
  }

  void _skipWhitespace() {
    while (cursor < source.length && RegExp(r'^\s$').hasMatch(source[cursor])) {
      if (source[cursor] == '\n') line++;
      cursor++;
    }
  }

  String _consumeLineValue() {
    final end = source.indexOf('\n', cursor);
    final stop = end < 0 ? source.length : end;
    final value = source.substring(cursor, stop);
    _consumeTo(stop);
    return value;
  }

  void _consumeThroughNewline() {
    final end = source.indexOf('\n', cursor);
    if (end < 0) {
      cursor = source.length;
      return;
    }
    cursor = end;
  }

  void _consumeTo(int end) {
    for (var index = cursor; index < end; index++) {
      if (source[index] == '\n') line++;
    }
    cursor = end;
  }

  String _normalizeDescription(String value) =>
      value.trim().replaceAll(RegExp(r'\n\s+'), '\n');
}

class _TimelineTaskBuilder {
  _TimelineTaskBuilder({
    required this.id,
    required this.period,
    required this.sectionName,
    required this.sourceLine,
  });

  final int id;
  final String period;
  final String sectionName;
  final int sourceLine;
  final events = <NativeMermaidTimelineEvent>[];
}
