import '../render_l10n.dart';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Participant shapes understood by the native sequence renderer.
enum NativeSequenceParticipantKind { participant, actor }

/// Arrow strokes supported by the sequence renderer.
enum NativeSequenceArrow {
  solid,
  dashed,
  solidLine,
  dashedLine,
  solidOpen,
  dashedOpen,
  solidCross,
  dashedCross,
  solidBidirectional,
  dashedBidirectional,
}

enum NativeSequenceActivationMarker { none, activateReceiver, deactivateSender }

enum NativeSequenceNotePlacement { left, right, over }

enum NativeSequenceFrameKind { loop, opt, alt, par, critical, breakLoop, rect }

sealed class NativeSequenceEvent {
  const NativeSequenceEvent();
}

class NativeSequenceMessage extends NativeSequenceEvent {
  const NativeSequenceMessage({
    required this.from,
    required this.to,
    required this.text,
    required this.arrow,
    this.activation = NativeSequenceActivationMarker.none,
    this.number,
  });

  final String from;
  final String to;
  final String text;
  final NativeSequenceArrow arrow;
  final NativeSequenceActivationMarker activation;
  final int? number;

  String get displayText => number == null ? text : '$number: $text';
}

class NativeSequenceNote extends NativeSequenceEvent {
  const NativeSequenceNote({
    required this.participants,
    required this.placement,
    required this.text,
  });

  final List<String> participants;
  final NativeSequenceNotePlacement placement;
  final String text;
}

class NativeSequenceActivation extends NativeSequenceEvent {
  const NativeSequenceActivation({
    required this.participant,
    required this.start,
  });

  final String participant;
  final bool start;
}

class NativeSequenceFrameStart extends NativeSequenceEvent {
  const NativeSequenceFrameStart({
    required this.id,
    required this.kind,
    required this.label,
  });

  final int id;
  final NativeSequenceFrameKind kind;
  final String label;
}

class NativeSequenceFrameDivider extends NativeSequenceEvent {
  const NativeSequenceFrameDivider({required this.kind, required this.label});

  final NativeSequenceFrameKind kind;
  final String label;
}

class NativeSequenceFrameEnd extends NativeSequenceEvent {
  const NativeSequenceFrameEnd({required this.id, required this.kind});

  final int id;
  final NativeSequenceFrameKind kind;
}

class NativeSequenceParticipant {
  const NativeSequenceParticipant({
    required this.id,
    required this.label,
    required this.kind,
  });

  final String id;
  final String label;
  final NativeSequenceParticipantKind kind;
}

class NativeSequenceDiagram {
  const NativeSequenceDiagram({
    required this.participants,
    required this.events,
    this.title,
  });

  final List<NativeSequenceParticipant> participants;
  final List<NativeSequenceEvent> events;
  final String? title;
}

/// Parses the native-supported Mermaid sequence subset synchronously.
///
/// Unsupported statements raise [FormatException] instead of being omitted.
/// The caller can invoke this before constructing [NativeMermaidSequence] so
/// parse failures are caught by the surrounding markdown block.
NativeSequenceDiagram parseNativeMermaidSequence(String source) {
  if (source.length > 50000) {
    throw FormatException(tr("Sequence diagram exceeds 50000 characters"));
  }

  final lines = source
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  final participants = <String, NativeSequenceParticipant>{};
  final explicitlyDeclared = <String>{};
  final events = <NativeSequenceEvent>[];
  final frames = <_FrameStackEntry>[];
  var headerFound = false;
  var frameId = 0;
  var title = '';
  var numbering = false;
  var nextNumber = 1;
  var numberStep = 1;
  final activationCounts = <String, int>{};

  Never invalid(int line, String details) => throw FormatException(
    tr("Invalid Mermaid sequence diagram at line {0}: {1}", [line, details]),
  );

  NativeSequenceParticipant ensureParticipant(
    String id, [
    NativeSequenceParticipantKind kind =
        NativeSequenceParticipantKind.participant,
  ]) {
    return participants.putIfAbsent(
      id,
      () => NativeSequenceParticipant(id: id, label: id, kind: kind),
    );
  }

  String unquote(String value) {
    final text = value.trim();
    if (text.length >= 2 &&
        ((text.startsWith('"') && text.endsWith('"')) ||
            (text.startsWith("'") && text.endsWith("'")))) {
      return text
          .substring(1, text.length - 1)
          .replaceAll(r'\"', '"')
          .replaceAll(r"\'", "'")
          .replaceAll(r'\\', String.fromCharCode(92));
    }
    return text;
  }

  const identifierPattern =
      r'''(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[A-Za-z_][A-Za-z0-9_.-]*|\d+)''';
  const messageIdentifierPattern =
      r'''(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\d+|[A-Za-z_][A-Za-z0-9_.-]*?)''';

  String normalizeIdentifier(String value, int lineNumber) {
    final identifier = unquote(value);
    if (identifier.isEmpty) {
      invalid(lineNumber, tr("Participant identifiers cannot be empty"));
    }
    return identifier;
  }

  for (var index = 0; index < lines.length; index++) {
    var line = lines[index].trim();
    if (line.isEmpty) continue;
    if (line.startsWith('%%{')) {
      invalid(index + 1, tr("Mermaid directives are not supported natively"));
    }
    if (line.startsWith('%%')) continue;

    if (!headerFound) {
      if (line.toLowerCase() != 'sequencediagram') {
        invalid(index + 1, tr("Expected sequenceDiagram header"));
      }
      headerFound = true;
      continue;
    }

    final titleMatch = RegExp(
      r'^title(?:\s+|:\s*)(.+)$',
      caseSensitive: false,
    ).firstMatch(line);
    if (titleMatch != null) {
      if (title.isNotEmpty) {
        invalid(index + 1, tr("Only one diagram title is supported"));
      }
      title = unquote(titleMatch.group(1)!);
      continue;
    }

    final numberMatch = RegExp(
      r'^autonumber(?:\s+(off|\d+)(?:\s+(\d+))?)?$',
      caseSensitive: false,
    ).firstMatch(line);
    if (numberMatch != null) {
      final start = numberMatch.group(1);
      if (start?.toLowerCase() == 'off') {
        numbering = false;
      } else {
        numbering = true;
        nextNumber = int.tryParse(start ?? '') ?? 1;
        numberStep = int.tryParse(numberMatch.group(2) ?? '') ?? 1;
        if (numberStep < 1) {
          invalid(index + 1, tr("autonumber step must be positive"));
        }
      }
      continue;
    }

    final declaration = RegExp(
      '^(participant|actor)\\s+($identifierPattern)(?:\\s+as\\s+(.+))?\$',
      caseSensitive: false,
    ).firstMatch(line);
    if (declaration != null) {
      final id = normalizeIdentifier(declaration.group(2)!, index + 1);
      final kind = declaration.group(1)!.toLowerCase() == 'actor'
          ? NativeSequenceParticipantKind.actor
          : NativeSequenceParticipantKind.participant;
      if (explicitlyDeclared.contains(id)) {
        invalid(index + 1, tr("Participant {0} is already declared", [id]));
      }
      final label = unquote(declaration.group(3) ?? id);
      if (label.isEmpty) {
        invalid(index + 1, tr("Participant labels cannot be empty"));
      }
      participants[id] = NativeSequenceParticipant(
        id: id,
        label: label,
        kind: kind,
      );
      explicitlyDeclared.add(id);
      continue;
    }
    if (RegExp(
      r'^(participant|actor)\b',
      caseSensitive: false,
    ).hasMatch(line)) {
      invalid(index + 1, tr("Malformed participant declaration"));
    }

    final activate = RegExp(
      '^(activate|deactivate)\\s+($identifierPattern)\$',
      caseSensitive: false,
    ).firstMatch(line);
    if (activate != null) {
      final id = normalizeIdentifier(activate.group(2)!, index + 1);
      ensureParticipant(id);
      final start = activate.group(1)!.toLowerCase() == 'activate';
      final count = activationCounts[id] ?? 0;
      if (!start && count == 0) {
        invalid(
          index + 1,
          tr("Cannot deactivate inactive participant {0}", [id]),
        );
      }
      activationCounts[id] = count + (start ? 1 : -1);
      events.add(NativeSequenceActivation(participant: id, start: start));
      continue;
    }
    if (RegExp(
      r'^(activate|deactivate)\b',
      caseSensitive: false,
    ).hasMatch(line)) {
      invalid(index + 1, tr("Malformed activation statement"));
    }

    if (line.toLowerCase() == 'end') {
      if (frames.isEmpty) {
        invalid(index + 1, tr("Unexpected end"));
      }
      final frame = frames.removeLast();
      events.add(NativeSequenceFrameEnd(id: frame.id, kind: frame.kind));
      continue;
    }

    final frameStart = RegExp(
      r'^(loop|opt|alt|par|critical|break|rect)(?:\s+(.+))?$',
      caseSensitive: false,
    ).firstMatch(line);
    if (frameStart != null) {
      final keyword = frameStart.group(1)!.toLowerCase();
      final kind = switch (keyword) {
        'loop' => NativeSequenceFrameKind.loop,
        'opt' => NativeSequenceFrameKind.opt,
        'alt' => NativeSequenceFrameKind.alt,
        'par' => NativeSequenceFrameKind.par,
        'critical' => NativeSequenceFrameKind.critical,
        'break' => NativeSequenceFrameKind.breakLoop,
        _ => NativeSequenceFrameKind.rect,
      };
      final entry = _FrameStackEntry(frameId++, kind);
      frames.add(entry);
      events.add(
        NativeSequenceFrameStart(
          id: entry.id,
          kind: kind,
          label: frameStart.group(2)?.trim() ?? '',
        ),
      );
      continue;
    }

    final divider = RegExp(
      r'^(else|and|option)(?:\s+(.+))?$',
      caseSensitive: false,
    ).firstMatch(line);
    if (divider != null) {
      if (frames.isEmpty) {
        final name = divider.group(1)!;
        invalid(index + 1, tr("Unexpected {0}", [name]));
      }
      final keyword = divider.group(1)!.toLowerCase();
      final activeKind = frames.last.kind;
      final supported = switch (keyword) {
        'else' => activeKind == NativeSequenceFrameKind.alt,
        'and' => activeKind == NativeSequenceFrameKind.par,
        _ => activeKind == NativeSequenceFrameKind.critical,
      };
      if (!supported) {
        invalid(
          index + 1,
          tr("{0} does not match the open sequence block", [keyword]),
        );
      }
      events.add(
        NativeSequenceFrameDivider(
          kind: activeKind,
          label: divider.group(2)?.trim() ?? '',
        ),
      );
      continue;
    }

    final note = RegExp(
      '^note\\s+(left of|right of|over)\\s+($identifierPattern(?:\\s*,\\s*$identifierPattern)?)(?:\\s*:\\s*(.*))?\$',
      caseSensitive: false,
    ).firstMatch(line);
    if (note != null) {
      final placementName = note.group(1)!.toLowerCase();
      final ids = RegExp(identifierPattern)
          .allMatches(note.group(2)!)
          .map((match) => normalizeIdentifier(match.group(0)!, index + 1))
          .toList(growable: false);
      if (placementName != 'over' && ids.length != 1) {
        invalid(index + 1, tr("left/right notes require one participant"));
      }
      for (final id in ids) {
        ensureParticipant(id);
      }
      events.add(
        NativeSequenceNote(
          participants: ids,
          placement: switch (placementName) {
            'left of' => NativeSequenceNotePlacement.left,
            'right of' => NativeSequenceNotePlacement.right,
            _ => NativeSequenceNotePlacement.over,
          },
          text: (note.group(3) ?? '').replaceAll(r'\n', '\n'),
        ),
      );
      continue;
    }
    if (RegExp(r'^note\b', caseSensitive: false).hasMatch(line)) {
      invalid(index + 1, tr("Malformed note statement"));
    }

    final message = RegExp(
      '^($messageIdentifierPattern)\\s*(<<-->>|<<->>|-->>|->>|--x|-x|--\\)|-\\)|-->|->)\\s*([+-])?\\s*($messageIdentifierPattern)(?:\\s*:\\s?(.*))?\$',
    ).firstMatch(line);
    if (message != null) {
      final from = normalizeIdentifier(message.group(1)!, index + 1);
      final to = normalizeIdentifier(message.group(4)!, index + 1);
      ensureParticipant(from);
      ensureParticipant(to);
      final token = message.group(2)!;
      final arrow = switch (token) {
        '<<->>' => NativeSequenceArrow.solidBidirectional,
        '<<-->>' => NativeSequenceArrow.dashedBidirectional,
        '-->>' => NativeSequenceArrow.dashed,
        '->>' => NativeSequenceArrow.solid,
        '--x' => NativeSequenceArrow.dashedCross,
        '-x' => NativeSequenceArrow.solidCross,
        '--)' => NativeSequenceArrow.dashedOpen,
        '-)' => NativeSequenceArrow.solidOpen,
        '-->' => NativeSequenceArrow.dashedLine,
        _ => NativeSequenceArrow.solidLine,
      };
      final marker = switch (message.group(3)) {
        '+' => NativeSequenceActivationMarker.activateReceiver,
        '-' => NativeSequenceActivationMarker.deactivateSender,
        _ => NativeSequenceActivationMarker.none,
      };
      if (marker == NativeSequenceActivationMarker.activateReceiver) {
        activationCounts[to] = (activationCounts[to] ?? 0) + 1;
      } else if (marker == NativeSequenceActivationMarker.deactivateSender) {
        final count = activationCounts[from] ?? 0;
        if (count == 0) {
          invalid(
            index + 1,
            tr("Cannot deactivate inactive participant {0}", [from]),
          );
        }
        activationCounts[from] = count - 1;
      }
      final number = numbering ? nextNumber : null;
      if (numbering) nextNumber += numberStep;
      events.add(
        NativeSequenceMessage(
          from: from,
          to: to,
          text: (message.group(5) ?? '').replaceAll(r'\n', '\n'),
          arrow: arrow,
          activation: marker,
          number: number,
        ),
      );
      continue;
    }

    invalid(index + 1, tr("Unsupported sequence diagram statement"));
  }

  if (!headerFound) {
    throw FormatException(tr("Expected sequenceDiagram header"));
  }
  if (frames.isNotEmpty) {
    throw FormatException(tr("Unclosed sequence diagram block"));
  }
  return NativeSequenceDiagram(
    participants: List.unmodifiable(participants.values),
    events: List.unmodifiable(events),
    title: title.isEmpty ? null : title,
  );
}

class NativeSequencePositionedEvent {
  const NativeSequencePositionedEvent({
    required this.event,
    required this.top,
    required this.height,
    this.lineY,
  });

  final NativeSequenceEvent event;
  final double top;
  final double height;
  final double? lineY;
  double get centerY => top + height / 2;
}

class NativeSequenceFrameBounds {
  const NativeSequenceFrameBounds({
    required this.id,
    required this.kind,
    required this.label,
    required this.top,
    required this.height,
    required this.width,
  });

  final int id;
  final NativeSequenceFrameKind kind;
  final String label;
  final double top;
  final double height;
  final double width;
}

class NativeSequenceActivationBounds {
  const NativeSequenceActivationBounds({
    required this.participant,
    required this.top,
    required this.height,
    required this.depth,
  });

  final String participant;
  final double top;
  final double height;
  final int depth;
}

class NativeSequenceLayout {
  const NativeSequenceLayout({
    required this.diagram,
    required this.fontFamily,
    required this.width,
    required this.height,
    required this.headerTop,
    required this.footerTop,
    required this.participantCenters,
    required this.participantWidths,
    required this.events,
    required this.frames,
    required this.activations,
  });

  final NativeSequenceDiagram diagram;
  final String fontFamily;
  final double width;
  final double height;
  final double headerTop;
  final double footerTop;
  final Map<String, double> participantCenters;
  final Map<String, double> participantWidths;
  final List<NativeSequencePositionedEvent> events;
  final List<NativeSequenceFrameBounds> frames;
  final List<NativeSequenceActivationBounds> activations;
}

/// Computes deterministic participant, event, frame, and activation geometry.
NativeSequenceLayout layoutNativeMermaidSequence(
  NativeSequenceDiagram diagram, {
  TextStyle? inheritedTextStyle,
}) {
  final fontFamily = inheritedTextStyle?.fontFamily ?? tr("Arial");
  TextStyle textStyle(double size) =>
      TextStyle(fontFamily: fontFamily, fontSize: size);
  final actorFont = textStyle(16);
  final messageFont = textStyle(16);
  final noteFont = textStyle(16);
  const actorWidth = 150.0;
  const actorHeight = 65.0;
  const actorGap = 50.0;
  const marginX = 50.0;
  const boxMargin = 10.0;

  TextPainter measurePainter(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text.isEmpty ? ' ' : text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    return painter;
  }

  ({double width, double height, double lineHeight}) measureDimensions(
    String text,
    TextStyle style,
  ) {
    ({double width, double height, double lineHeight}) forFont(TextStyle font) {
      var width = 0.0, height = 0.0, lineHeight = 0.0;
      if (text.isEmpty) {
        return (width: width, height: height, lineHeight: lineHeight);
      }
      for (final line in text.split('\n')) {
        final value = line.isEmpty ? '\u200b' : line;
        final painter = measurePainter(value, font);
        final boxes = painter.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: value.length),
          boxHeightStyle: ui.BoxHeightStyle.tight,
        );
        final extent = boxes.isEmpty
            ? 0.0
            : boxes.map((box) => box.bottom).reduce(math.max) -
                  boxes.map((box) => box.top).reduce(math.min);
        width = math.max(width, painter.width.roundToDouble());
        height += extent.roundToDouble();
        lineHeight = math.max(lineHeight, extent.roundToDouble());
        painter.dispose();
      }
      return (width: width, height: height, lineHeight: lineHeight);
    }

    final requested = forFont(style);
    final fallback = forFont(style.copyWith(fontFamily: 'sans-serif'));
    // Mermaid calculateTextDimensions measures both fonts and uses the
    // fallback only when all three rounded dimensions are greater. The
    // generic font resolves per platform; host captures record that choice.
    return fallback.width > requested.width &&
            fallback.height > requested.height &&
            fallback.lineHeight > requested.lineHeight
        ? fallback
        : requested;
  }

  double measureWidth(String text, TextStyle style) =>
      measureDimensions(text, style).width;
  double measureHeight(String text, TextStyle style) =>
      measureDimensions(text, style).height;

  final widths = <String, double>{};
  for (final participant in diagram.participants) {
    widths[participant.id] = math.max(
      actorWidth,
      measureWidth(participant.label, actorFont) + 24,
    );
  }
  final gaps = List<double>.filled(
    math.max(0, diagram.participants.length - 1),
    actorGap,
  );

  final centers = <String, double>{};
  var cursor = marginX;
  for (var i = 0; i < diagram.participants.length; i++) {
    final participant = diagram.participants[i];
    final width = widths[participant.id] ?? actorWidth;
    centers[participant.id] = cursor + width / 2;
    cursor += width;
    if (i < gaps.length) cursor += gaps[i];
  }
  var width = math.max(120.0, cursor + marginX);
  var leadingExtra = 0.0;
  var trailingExtra = 0.0;
  const noteMinWidth = 150.0;
  for (final event in diagram.events.whereType<NativeSequenceMessage>()) {
    final textWidth = measureWidth(event.displayText, messageFont);
    final from = centers[event.from]!;
    final to = centers[event.to]!;
    final left = event.from == event.to
        ? from + 39
        : (from + to - textWidth) / 2;
    leadingExtra = math.max(leadingExtra, marginX - left);
    trailingExtra = math.max(trailingExtra, left + textWidth + marginX - width);
  }
  for (final event in diagram.events.whereType<NativeSequenceNote>()) {
    final noteWidth = math
        .max(noteMinWidth, measureWidth(event.text, noteFont) + 20)
        .toDouble();
    final xs = event.participants.map((id) => centers[id]!).toList();
    double left;
    if (event.placement == NativeSequenceNotePlacement.left) {
      left = xs.single - 25 - noteWidth;
    } else if (event.placement == NativeSequenceNotePlacement.right) {
      left = xs.single + 25;
    } else {
      left = (xs.reduce(math.min) + xs.reduce(math.max) - noteWidth) / 2;
    }
    leadingExtra = math.max(leadingExtra, marginX - left);
    trailingExtra = math.max(trailingExtra, left + noteWidth + marginX - width);
  }
  leadingExtra = math.max(0, leadingExtra);
  trailingExtra = math.max(0, trailingExtra);
  if (leadingExtra > 0) {
    for (final id in centers.keys.toList()) {
      centers[id] = centers[id]! + leadingExtra;
    }
  }
  width += leadingExtra + trailingExtra;
  final titleHeight = diagram.title == null ? 0.0 : 27.0;
  final headerTop = titleHeight + 0;
  final bodyStart = headerTop + actorHeight;
  var currentY = bodyStart;
  final positioned = <NativeSequencePositionedEvent>[];
  for (final event in diagram.events) {
    var top = currentY;
    var height = 0.0;
    double? lineY;
    if (event is NativeSequenceMessage) {
      final textHeight = measureHeight(event.displayText, messageFont);
      final lineCount = event.displayText.split('\n').length;
      final lineHeight = textHeight / lineCount;
      currentY += 10 + lineHeight;
      final totalOffset = textHeight - 10 + boxMargin;
      lineY = currentY + totalOffset;
      final isSelfMessage = event.from == event.to;
      height = lineHeight + totalOffset + (isSelfMessage ? 30 : 0);
      currentY = lineY + (isSelfMessage ? 30 : 0);
    } else if (event is NativeSequenceNote) {
      final textHeight = measureHeight(event.text, noteFont);
      top += boxMargin;
      height = math.max(38, textHeight + 20);
      currentY = top + height;
    } else if (event is NativeSequenceFrameStart) {
      height = 22;
      currentY += height;
    } else if (event is NativeSequenceFrameDivider) {
      height = 22;
      currentY += height;
    } else if (event is NativeSequenceFrameEnd) {
      height = 12;
      currentY += height;
    } else if (event is NativeSequenceActivation) {
      height = 0;
    }
    positioned.add(
      NativeSequencePositionedEvent(
        event: event,
        top: top,
        height: height,
        lineY: lineY,
      ),
    );
  }

  final footerTop = math.max(bodyStart + 55, currentY + 20);
  final height = footerTop + actorHeight + 21;

  final frameStarts = <int, NativeSequencePositionedEvent>{};
  final frames = <NativeSequenceFrameBounds>[];
  for (final item in positioned) {
    final event = item.event;
    if (event is NativeSequenceFrameStart) {
      frameStarts[event.id] = item;
    } else if (event is NativeSequenceFrameEnd) {
      final start = frameStarts.remove(event.id);
      if (start != null) {
        final startEvent = start.event as NativeSequenceFrameStart;
        frames.add(
          NativeSequenceFrameBounds(
            id: event.id,
            kind: event.kind,
            label: startEvent.label,
            top: start.top,
            height: math.max(32, item.top + item.height - start.top),
            width: width - 40,
          ),
        );
      }
    }
  }

  final open = <String, List<_OpenActivation>>{};
  final activations = <NativeSequenceActivationBounds>[];
  void startActivation(String id, double y) {
    final entries = open.putIfAbsent(id, () => <_OpenActivation>[]);
    entries.add(_OpenActivation(y, entries.length));
  }

  void finishActivation(String id, double y) {
    final entries = open[id];
    if (entries == null || entries.isEmpty) return;
    final start = entries.removeLast();
    activations.add(
      NativeSequenceActivationBounds(
        participant: id,
        top: start.top,
        height: math.max(3, y - start.top),
        depth: start.depth,
      ),
    );
  }

  for (final item in positioned) {
    final event = item.event;
    if (event is NativeSequenceActivation) {
      if (event.start) {
        startActivation(event.participant, item.top);
      } else {
        finishActivation(event.participant, item.top);
      }
    } else if (event is NativeSequenceMessage) {
      if (event.activation == NativeSequenceActivationMarker.deactivateSender) {
        finishActivation(event.from, item.top);
      } else if (event.activation ==
          NativeSequenceActivationMarker.activateReceiver) {
        startActivation(event.to, item.top + item.height);
      }
    }
  }
  for (final entry in open.entries) {
    for (final start in entry.value) {
      activations.add(
        NativeSequenceActivationBounds(
          participant: entry.key,
          top: start.top,
          height: math.max(3, footerTop - start.top),
          depth: start.depth,
        ),
      );
    }
  }

  return NativeSequenceLayout(
    diagram: diagram,
    fontFamily: fontFamily,
    width: width,
    height: height,
    headerTop: headerTop,
    footerTop: footerTop,
    participantCenters: Map.unmodifiable(centers),
    participantWidths: Map.unmodifiable(widths),
    events: List.unmodifiable(positioned),
    frames: List.unmodifiable(frames),
    activations: List.unmodifiable(activations),
  );
}

class NativeMermaidSequence extends StatelessWidget {
  const NativeMermaidSequence({
    super.key,
    required this.source,
    required this.dark,
  });

  final String source;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    final diagram = parseNativeMermaidSequence(source);
    final layout = layoutNativeMermaidSequence(
      diagram,
      inheritedTextStyle: DefaultTextStyle.of(context).style,
    );
    return Semantics(
      image: true,
      label: _sequenceSemanticsLabel(diagram),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final available = constraints.hasBoundedWidth
              ? constraints.maxWidth
              : layout.width;
          final scale = available <= 0
              ? 0.0
              : math.min(1.0, available / layout.width);
          final paintWidth = available.isFinite ? available : layout.width;
          final paintHeight = layout.height * scale;
          final horizontalOffset =
              math.max(0, paintWidth - layout.width * scale) / 2;
          return SizedBox(
            width: paintWidth,
            height: paintHeight,
            child: CustomPaint(
              size: Size(paintWidth, paintHeight),
              painter: _NativeSequencePainter(
                layout: layout,
                dark: dark,
                scale: scale,
                horizontalOffset: horizontalOffset,
              ),
            ),
          );
        },
      ),
    );
  }
}

String _sequenceSemanticsLabel(NativeSequenceDiagram diagram) {
  final labels = {
    for (final participant in diagram.participants)
      participant.id: participant.label,
  };
  final sections = <String>[
    'Participants: ${diagram.participants.map((participant) => participant.label).join(', ')}',
  ];
  final messages = diagram.events.whereType<NativeSequenceMessage>().map((
    message,
  ) {
    final from = labels[message.from] ?? message.from;
    final to = labels[message.to] ?? message.to;
    final text = message.displayText;
    return text.isEmpty
        ? tr("{0} to {1}", [from, to])
        : tr("{0} to {1}: {2}", [from, to, text]);
  }).toList();
  if (messages.isNotEmpty) {
    sections.add('Messages: ${messages.join('; ')}');
  }
  final notes = diagram.events.whereType<NativeSequenceNote>().map((note) {
    final placement = switch (note.placement) {
      NativeSequenceNotePlacement.left => tr("left of"),
      NativeSequenceNotePlacement.right => tr("right of"),
      NativeSequenceNotePlacement.over => 'over',
    };
    final participants = note.participants
        .map((id) => labels[id] ?? id)
        .join(', ');
    return '$placement $participants: ${note.text}';
  }).toList();
  if (notes.isNotEmpty) {
    sections.add('Notes: ${notes.join('; ')}');
  }
  final title = diagram.title;
  final description = title == null
      ? tr("Sequence diagram. {0}", [sections.join('. ')])
      : tr("Sequence diagram. {0}. {1}", [title, sections.join('. ')]);
  return description.length <= 4000
      ? description
      : '${description.substring(0, 3997)}...';
}

class _NativeSequencePainter extends CustomPainter {
  const _NativeSequencePainter({
    required this.layout,
    required this.dark,
    required this.scale,
    required this.horizontalOffset,
  });

  final NativeSequenceLayout layout;
  final bool dark;
  final double scale;
  final double horizontalOffset;

  Color get actorFill =>
      dark ? const Color(0xff1f2020) : const Color(0xffedf3fe);
  Color get actorBorder =>
      dark ? const Color(0xffcccccc) : const Color(0xff4176e6);
  Color get textColor =>
      dark ? const Color(0xffd3d3d3) : const Color(0xff0f1115);
  Color get lineColor =>
      dark ? const Color(0xffd3d3d3) : const Color(0xff0f1115);
  Color get noteFill =>
      dark ? const Color(0xff474949) : const Color(0xfffff5ad);
  Color get noteBorder =>
      dark ? const Color(0xff2f2f2f) : const Color(0xffe4db95);
  Color get noteText =>
      dark ? const Color(0xffb8b6b6) : const Color(0xff333333);
  Color get activationFill =>
      dark ? const Color(0xff474949) : const Color(0xfff1f3f5);
  Color get frameFill =>
      dark ? const Color(0xff252525) : const Color(0xfff9fafb);

  TextStyle _style(double size, Color color) =>
      TextStyle(fontFamily: layout.fontFamily, fontSize: size, color: color);

  @override
  void paint(Canvas canvas, Size size) {
    if (scale <= 0) return;
    canvas.save();
    canvas.translate(horizontalOffset, 0);
    canvas.scale(scale);
    canvas.translate(0, 10);
    _paintDiagram(canvas);
    canvas.restore();
  }

  void _paintDiagram(Canvas canvas) {
    _paintTitle(canvas);
    _paintFrames(canvas);
    _paintLifelines(canvas);
    _paintActivations(canvas);
    _paintEvents(canvas);
    _paintActors(canvas);
  }

  void _paintTitle(Canvas canvas) {
    final title = layout.diagram.title;
    if (title == null) return;
    final text = _text(title, _style(16, textColor));
    text.paint(canvas, Offset((layout.width - text.width) / 2, 2));
  }

  void _paintFrames(Canvas canvas) {
    for (final frame in layout.frames) {
      final rect = Rect.fromLTWH(20, frame.top, frame.width, frame.height);
      canvas.drawRect(
        rect,
        Paint()
          ..color = frameFill
          ..style = PaintingStyle.fill,
      );
      final border = Paint()
        ..color = actorBorder.withValues(alpha: .9)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;
      _dashedLine(canvas, rect.topLeft, rect.topRight, border);
      _dashedLine(canvas, rect.topRight, rect.bottomRight, border);
      _dashedLine(canvas, rect.bottomRight, rect.bottomLeft, border);
      _dashedLine(canvas, rect.bottomLeft, rect.topLeft, border);
      final label = _frameLabel(frame);
      if (label.isNotEmpty) {
        final text = _text(label, _style(12, textColor));
        final chip = Rect.fromLTWH(25, frame.top + 2, text.width + 10, 18);
        canvas.drawRect(chip, Paint()..color = frameFill);
        text.paint(canvas, Offset(chip.left + 5, chip.top + 1));
      }
    }
  }

  String _frameLabel(NativeSequenceFrameBounds frame) {
    final kind = switch (frame.kind) {
      NativeSequenceFrameKind.breakLoop => 'break',
      _ => frame.kind.name,
    };
    final label = frame.label;
    return label.isEmpty ? kind : '$kind $label';
  }

  void _paintLifelines(Canvas canvas) {
    final paint = Paint()
      ..color = dark ? const Color(0xffcccccc) : const Color(0xff4176e6)
      ..strokeWidth = 0.5
      ..style = PaintingStyle.stroke;
    for (final participant in layout.diagram.participants) {
      final center = layout.participantCenters[participant.id]!;
      final topHeight = participant.kind == NativeSequenceParticipantKind.actor
          ? 80.0
          : 65.0;
      canvas.drawLine(
        Offset(center, layout.headerTop + topHeight),
        Offset(center, layout.footerTop),
        paint,
      );
    }
  }

  void _paintActivations(Canvas canvas) {
    for (final activation in layout.activations) {
      final center = layout.participantCenters[activation.participant];
      if (center == null) continue;
      final left = center + activation.depth * 5.0;
      final rect = Rect.fromLTWH(left, activation.top, 10, activation.height);
      canvas.drawRect(rect, Paint()..color = activationFill);
      canvas.drawRect(
        rect,
        Paint()
          ..color = actorBorder
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke,
      );
    }
  }

  void _paintEvents(Canvas canvas) {
    for (final positioned in layout.events) {
      final event = positioned.event;
      if (event is NativeSequenceMessage) {
        _paintMessage(canvas, positioned, event);
      } else if (event is NativeSequenceNote) {
        _paintNote(canvas, positioned, event);
      } else if (event is NativeSequenceFrameDivider) {
        _paintDivider(canvas, positioned, event);
      }
    }
  }

  void _paintMessage(
    Canvas canvas,
    NativeSequencePositionedEvent positioned,
    NativeSequenceMessage message,
  ) {
    final from = layout.participantCenters[message.from]!;
    final to = layout.participantCenters[message.to]!;
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final text = _text(message.displayText, _style(16, textColor));
    final textTop = positioned.top + 17;
    if (message.from == message.to) {
      final x = from + 1;
      final y = positioned.lineY ?? positioned.top + 46;
      final path = Path()
        ..moveTo(x, y)
        ..cubicTo(x + 60, y - 10, x + 60, y + 30, x, y + 20);
      if (_isDashed(message.arrow)) {
        _dashedPath(canvas, path, paint, dash: 3, gap: 3);
      } else {
        canvas.drawPath(path, paint);
      }
      _drawHead(canvas, Offset(x, y + 20), -1, message.arrow, paint);
      text.paint(canvas, Offset(x - text.width / 2, textTop));
      return;
    }
    final y = positioned.lineY ?? positioned.top + 46;
    final direction = to >= from ? 1.0 : -1.0;
    final targetInset =
        message.arrow == NativeSequenceArrow.solidOpen ||
            message.arrow == NativeSequenceArrow.dashedOpen
        ? 1.0
        : 4.0;
    final source = Offset(from + direction, y);
    final target = Offset(to - direction * targetInset, y);
    _drawArrow(canvas, source, target, message.arrow, paint);
    text.paint(
      canvas,
      Offset((source.dx + target.dx - text.width) / 2, textTop),
    );
  }

  void _drawArrow(
    Canvas canvas,
    Offset from,
    Offset to,
    NativeSequenceArrow arrow,
    Paint paint,
  ) {
    final direction = to.dx >= from.dx ? 1.0 : -1.0;
    final startHead =
        arrow == NativeSequenceArrow.solidBidirectional ||
        arrow == NativeSequenceArrow.dashedBidirectional;
    final hasEndMarker =
        arrow != NativeSequenceArrow.solidLine &&
        arrow != NativeSequenceArrow.dashedLine;
    if (_isDashed(arrow)) {
      _dashedLine(canvas, from, to, paint, dash: 3, gap: 3);
    } else {
      canvas.drawLine(from, to, paint);
    }
    if (startHead) {
      _drawHead(canvas, from, -direction, arrow, paint);
    }
    if (hasEndMarker) {
      final markerTip = _isCross(arrow)
          ? to
          : (arrow == NativeSequenceArrow.solidOpen ||
                    arrow == NativeSequenceArrow.dashedOpen
                ? to
                : Offset(to.dx + direction * 2.1, to.dy));
      _drawHead(canvas, markerTip, direction, arrow, paint);
    }
  }

  void _drawHead(
    Canvas canvas,
    Offset tip,
    double direction,
    NativeSequenceArrow arrow,
    Paint paint,
  ) {
    final cross = _isCross(arrow);
    if (arrow == NativeSequenceArrow.solidLine ||
        arrow == NativeSequenceArrow.dashedLine) {
      return;
    }
    if (cross) {
      canvas.drawLine(
        Offset(tip.dx - 4, tip.dy - 5),
        Offset(tip.dx + 4, tip.dy + 5),
        paint,
      );
      canvas.drawLine(
        Offset(tip.dx - 4, tip.dy + 5),
        Offset(tip.dx + 4, tip.dy - 5),
        paint,
      );
      return;
    }
    final filled =
        arrow == NativeSequenceArrow.solid ||
        arrow == NativeSequenceArrow.dashed ||
        arrow == NativeSequenceArrow.solidBidirectional ||
        arrow == NativeSequenceArrow.dashedBidirectional;
    final baseA = Offset(tip.dx - direction * 8, tip.dy - 5);
    final baseB = Offset(tip.dx - direction * 8, tip.dy + 5);
    if (filled) {
      final path = Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(baseA.dx, baseA.dy)
        ..lineTo(baseB.dx, baseB.dy)
        ..close();
      canvas.drawPath(path, Paint()..color = paint.color);
    } else {
      final path = Path()
        ..moveTo(baseA.dx, baseA.dy)
        ..lineTo(tip.dx, tip.dy)
        ..lineTo(baseB.dx, baseB.dy);
      canvas.drawPath(path, paint);
    }
  }

  bool _isDashed(NativeSequenceArrow arrow) =>
      arrow == NativeSequenceArrow.dashed ||
      arrow == NativeSequenceArrow.dashedLine ||
      arrow == NativeSequenceArrow.dashedOpen ||
      arrow == NativeSequenceArrow.dashedCross ||
      arrow == NativeSequenceArrow.dashedBidirectional;

  bool _isCross(NativeSequenceArrow arrow) =>
      arrow == NativeSequenceArrow.solidCross ||
      arrow == NativeSequenceArrow.dashedCross;

  void _paintNote(
    Canvas canvas,
    NativeSequencePositionedEvent positioned,
    NativeSequenceNote note,
  ) {
    final text = _text(note.text, _style(16, noteText));
    const noteMinWidth = 150.0;
    final noteWidth = math.max(noteMinWidth, text.width + 20).toDouble();
    double left;
    if (note.placement == NativeSequenceNotePlacement.left) {
      final center = layout.participantCenters[note.participants.single]!;
      left = center - 25 - noteWidth;
    } else if (note.placement == NativeSequenceNotePlacement.right) {
      final center = layout.participantCenters[note.participants.single]!;
      left = center + 25;
    } else {
      final xs = note.participants
          .map((id) => layout.participantCenters[id]!)
          .toList();
      final center = (xs.reduce(math.min) + xs.reduce(math.max)) / 2;
      left = center - noteWidth / 2;
    }
    final height = math.max(38.0, text.height + 20);
    final rect = Rect.fromLTWH(left, positioned.top, noteWidth, height);
    canvas.drawRect(rect, Paint()..color = noteFill);
    canvas.drawRect(
      rect,
      Paint()
        ..color = noteBorder
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
    text.paint(
      canvas,
      Offset(
        rect.left + (rect.width - text.width) / 2,
        rect.top + (rect.height - text.height) / 2,
      ),
    );
  }

  void _paintDivider(
    Canvas canvas,
    NativeSequencePositionedEvent positioned,
    NativeSequenceFrameDivider divider,
  ) {
    final y = positioned.centerY;
    final paint = Paint()
      ..color = actorBorder
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    _dashedLine(canvas, Offset(20, y), Offset(layout.width - 20, y), paint);
    final label = divider.label.isEmpty
        ? divider.kind.name
        : (divider.kind == NativeSequenceFrameKind.alt ? 'else ' : 'and ') +
              divider.label;
    final text = _text(label, _style(12, textColor));
    final chip = Rect.fromLTWH(25, y - 9, text.width + 10, 18);
    canvas.drawRect(chip, Paint()..color = frameFill);
    text.paint(canvas, Offset(chip.left + 5, chip.top + 1));
  }

  void _paintActors(Canvas canvas) {
    for (final participant in layout.diagram.participants) {
      final center = layout.participantCenters[participant.id]!;
      final width = layout.participantWidths[participant.id]!;
      _paintActor(canvas, participant, center, width, layout.headerTop);
      _paintActor(canvas, participant, center, width, layout.footerTop);
    }
  }

  void _paintActor(
    Canvas canvas,
    NativeSequenceParticipant participant,
    double center,
    double width,
    double top,
  ) {
    if (participant.kind == NativeSequenceParticipantKind.actor) {
      _paintMermaidActor(canvas, center, top);
      final label = _text(participant.label, _style(14, textColor));
      label.paint(canvas, Offset(center - label.width / 2, top + 35));
      return;
    }

    final rect = Rect.fromLTWH(center - width / 2, top, width, 65);
    final boxPaint = Paint()
      ..color = actorFill
      ..style = PaintingStyle.fill;
    final borderPaint = Paint()
      ..color = actorBorder
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final shape = RRect.fromRectAndRadius(rect, const Radius.circular(3));
    canvas.drawRRect(shape, boxPaint);
    canvas.drawRRect(shape, borderPaint);
    final label = _text(participant.label, _style(16, textColor));
    label.paint(
      canvas,
      Offset(center - label.width / 2, top + (65 - label.height) / 2),
    );
  }

  void _paintMermaidActor(Canvas canvas, double x, double top) {
    final paint = Paint()
      ..color = actorBorder
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final fill = Paint()
      ..color = actorFill
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(x, top + 10), 15, fill);
    canvas.drawCircle(Offset(x, top + 10), 15, paint);
    canvas.drawLine(Offset(x, top + 25), Offset(x, top + 45), paint);
    canvas.drawLine(Offset(x - 18, top + 33), Offset(x + 18, top + 33), paint);
    canvas.drawLine(Offset(x - 18, top + 60), Offset(x, top + 45), paint);
    canvas.drawLine(Offset(x, top + 45), Offset(x + 16, top + 60), paint);
  }

  TextPainter _text(String value, TextStyle style) {
    return TextPainter(
      text: TextSpan(text: value, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  void _dashedPath(
    Canvas canvas,
    Path path,
    Paint paint, {
    double dash = 4,
    double gap = 3,
  }) {
    for (final metric in path.computeMetrics()) {
      var position = 0.0;
      while (position < metric.length) {
        final stop = math.min(metric.length, position + dash);
        canvas.drawPath(metric.extractPath(position, stop), paint);
        position = stop + gap;
      }
    }
  }

  void _dashedLine(
    Canvas canvas,
    Offset start,
    Offset end,
    Paint paint, {
    double dash = 4,
    double gap = 3,
  }) {
    final delta = end - start;
    final distance = delta.distance;
    if (distance == 0) return;
    final direction = delta / distance;
    var position = 0.0;
    while (position < distance) {
      final stop = math.min(distance, position + dash);
      canvas.drawLine(
        start + direction * position,
        start + direction * stop,
        paint,
      );
      position = stop + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _NativeSequencePainter oldDelegate) =>
      oldDelegate.layout != layout ||
      oldDelegate.dark != dark ||
      oldDelegate.scale != scale ||
      oldDelegate.horizontalOffset != horizontalOffset;
}

class _FrameStackEntry {
  const _FrameStackEntry(this.id, this.kind);

  final int id;
  final NativeSequenceFrameKind kind;
}

class _OpenActivation {
  const _OpenActivation(this.top, this.depth);

  final double top;
  final int depth;
}
