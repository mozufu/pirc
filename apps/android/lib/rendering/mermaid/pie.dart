import '../render_l10n.dart';
import 'dart:math' as math;
import 'dart:convert';
import 'package:flutter/material.dart';

/// Geometry and slice filtering from pinned Mermaid 11.17.2 pieRenderer.ts.
/// Configuration directives are deliberately rejected until natively supported.
class MermaidPie {
  const MermaidPie(
    this.title,
    this.sections,
    this.showData,
    this.description,
    this.accessibleTitle,
  );
  final String title, description, accessibleTitle;
  final Map<String, double> sections;
  final bool showData;
  double get total => sections.values.fold(0, (a, b) => a + b);
  List<MapEntry<String, double>> get slices => sections.entries
      .where((e) => total > 0 && e.value / total * 100 >= 1)
      .toList();
  String legend(MapEntry<String, double> entry) => showData
      ? '${entry.key} [${entry.value == entry.value.truncateToDouble() ? entry.value.toInt() : entry.value}]'
      : entry.key;
}

String _withoutComment(String line) {
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    if (quoted && line[i] == r'\') {
      i++;
      continue;
    }
    if (line[i] == '"') quoted = !quoted;
    if (!quoted && line.startsWith('%%', i)) {
      if (line.startsWith('%%{', i)) {
        throw FormatException(
          tr("Native Mermaid configuration directives are not implemented"),
        );
      }
      return line.substring(0, i);
    }
  }
  return line;
}

class _PieStatement {
  const _PieStatement(this.text, {this.description});

  final String text;
  final String? description;
}

List<_PieStatement> _parsePieStatements(String source) {
  // Mermaid preprocesses full-line comments before parsing descriptions.
  final rawLines = source
      .replaceAll('\r\n', '\n')
      .split('\n')
      .where(
        (line) =>
            !line.trimLeft().startsWith('%%') ||
            line.trimLeft().startsWith('%%{'),
      )
      .toList();
  final statements = <_PieStatement>[];
  for (var i = 0; i < rawLines.length; i++) {
    final rawLine = rawLines[i];
    final candidate = rawLine.trimLeft();
    final opener = RegExp(
      r'^accDescr\s*\{',
      caseSensitive: false,
    ).firstMatch(candidate);
    if (opener == null) {
      final line = _withoutComment(rawLine).trim();
      if (line.isNotEmpty) statements.add(_PieStatement(line));
      continue;
    }

    final body = StringBuffer();
    var remaining = candidate.substring(opener.end);
    var close = remaining.indexOf('}');
    var trailing = '';
    var closed = close >= 0;
    if (closed) {
      body.write(remaining.substring(0, close));
      trailing = remaining.substring(close + 1);
    } else {
      body.write(remaining);
      body.write('\n');
      while (i + 1 < rawLines.length) {
        i++;
        remaining = rawLines[i];
        close = remaining.indexOf('}');
        if (close >= 0) {
          body.write(remaining.substring(0, close));
          trailing = remaining.substring(close + 1);
          closed = true;
          break;
        }
        body.write(remaining);
        if (i + 1 < rawLines.length) body.write('\n');
      }
    }
    if (!closed) {
      throw FormatException(tr("Unclosed native pie accDescr block"));
    }
    if (_withoutComment(trailing).trim().isNotEmpty) {
      throw FormatException(
        tr("Unsupported or invalid native pie statement: {0}", [
          trailing.trim(),
        ]),
      );
    }
    // Mermaid's common DB removes indentation and blank lines after each
    // newline, then trims the block's outer whitespace.
    final description = body.toString().trim().replaceAll(
      RegExp(r'\n\s+'),
      '\n',
    );
    statements.add(_PieStatement('', description: description));
  }
  return statements;
}

MermaidPie parseNativeMermaidPie(String source) {
  final statements = _parsePieStatements(source);
  if (statements.isEmpty) throw FormatException(tr("Expected pie diagram"));
  final header = RegExp(
    r'^pie(?:\s+(showData))?(?:\s+(title\s+.*))?$',
  ).firstMatch(statements.first.text);
  if (header == null) throw FormatException(tr("Expected pie diagram"));
  final showData = header[1] != null;
  if (header[2] != null) {
    statements.insert(1, _PieStatement(header[2]!));
  }
  var title = '', description = '', accessibleTitle = '';
  final sections = <String, double>{};
  for (final statement in statements.skip(1)) {
    if (statement.description != null) {
      description = statement.description!;
      continue;
    }
    final line = statement.text;
    if (line.startsWith('title ')) {
      title = line.substring(6).trim();
      continue;
    }
    if (line.startsWith('accTitle:')) {
      accessibleTitle = line.substring(9).trim();
      continue;
    }
    if (line.startsWith('accDescr:')) {
      description = line.substring(9).trim();
      continue;
    }
    final entry = RegExp(
      r'^("(?:[^"\\\r\n]|\\.)*")\s*:\s*(-?\d+(?:\.\d+)?)\s*$',
    ).firstMatch(line);
    if (entry == null) {
      throw FormatException(
        tr("Unsupported or invalid native pie statement: {0}", [line]),
      );
    }
    final value = double.parse(entry[2]!);
    final label = jsonDecode(entry[1]!) as String;
    if (!value.isFinite) {
      throw FormatException(tr("Native pie values must be finite"));
    }
    if (value < 0) {
      final formatted = value == value.truncateToDouble()
          ? value.toStringAsFixed(0)
          : value.toString();
      throw FormatException(
        '"$label" has invalid value: $formatted. Negative values are not allowed in pie charts. All slice values must be >= 0.',
      );
    }
    sections.putIfAbsent(label, () => value);
  }
  return MermaidPie(
    title,
    Map.unmodifiable(sections),
    showData,
    description,
    accessibleTitle,
  );
}

class NativeMermaidPie extends StatelessWidget {
  const NativeMermaidPie({
    super.key,
    required this.diagram,
    required this.dark,
  });
  final MermaidPie diagram;
  final bool dark;
  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    final font = DefaultTextStyle.of(context).style.fontFamily;
    final painter = MermaidPiePainter(diagram, dark, font);
    return Semantics(
      image: true,
      label: [
        diagram.accessibleTitle.isEmpty
            ? diagram.title
            : diagram.accessibleTitle,
        diagram.description,
        ...diagram.sections.entries.map((e) => '${e.key}: ${e.value}'),
      ].where((s) => s.isNotEmpty).join(', '),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final scale = math.min(
            1.0,
            constraints.maxWidth / painter.size.width,
          );
          return SizedBox(
            height: painter.size.height * scale,
            child: Center(
              child: SizedBox(
                width: painter.size.width * scale,
                height: painter.size.height * scale,
                child: CustomPaint(painter: painter),
              ),
            ),
          );
        },
      ),
    );
  }
}

class MermaidPiePainter extends CustomPainter {
  MermaidPiePainter(this.diagram, this.dark, this.fontFamily) {
    final labels = diagram.sections.entries.map(
      (e) => _text(diagram.legend(e), 17, legendColor).width,
    );
    final maxLabel = labels.fold(0.0, math.max);
    final titleWidth = _text(diagram.title, 25, legendColor).width;
    viewLeft = math.min(0, 225 - titleWidth / 2);
    size = Size(math.max(512 + maxLabel, 225 + titleWidth / 2) - viewLeft, 450);
  }
  final MermaidPie diagram;
  final bool dark;
  final String? fontFamily;
  late final Size size;
  late final double viewLeft;
  Color get legendColor =>
      dark ? const Color(0xffd3d3d3) : const Color(0xff0f1115);
  Color get sliceTextColor =>
      dark ? const Color(0xffcccccc) : const Color(0xff0f1115);
  List<Color> get palette {
    if (dark) {
      return const [
        Color(0xff0b0000),
        Color(0xff4d1037),
        Color(0xff3f5258),
        Color(0xff4f2f1b),
        Color(0xff6e0a0a),
        Color(0xff3b0048),
        Color(0xff995a01),
        Color(0xff154706),
        Color(0xff161722),
        Color(0xff00296f),
        Color(0xff01629c),
        Color(0xffcccccc),
      ];
    }
    // CSS-computed sRGB values from the pinned base theme. Using these avoids
    // a half-channel HSL rounding difference between Flutter and Chromium.
    return const [
      Color(0xffedf3fe),
      Color(0xfff1f3f5),
      Color(0xfff9fafb),
      Color(0xffbdd3fb),
      Color(0xffd3dae0),
      Color(0xffdae1e7),
      Color(0xffe5bdfb),
      Color(0xffbdfbe5),
      Color(0xfffeedf3),
      Color(0xffd28cf9),
      Color(0xff8cf9d2),
      Color(0xfffbbdd3),
    ];
  }

  TextPainter _text(String value, double fontSize, Color color) => TextPainter(
    text: TextSpan(
      text: value,
      style: TextStyle(
        fontFamily: fontFamily,
        fontSize: fontSize,
        fontWeight: FontWeight.w400,
        letterSpacing: 0,
        color: color,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  void _label(
    Canvas canvas,
    String value,
    Offset baseline,
    double fontSize,
    Color color, {
    bool centered = false,
  }) {
    final t = _text(value, fontSize, color);
    t.paint(
      canvas,
      baseline -
          Offset(
            centered ? t.width / 2 : 0,
            t.computeDistanceToActualBaseline(TextBaseline.alphabetic),
          ),
    );
  }

  @override
  void paint(Canvas canvas, Size renderedSize) {
    canvas.save();
    canvas.scale(renderedSize.width / size.width);
    canvas.translate(-viewLeft, 0);
    const center = Offset(225, 225);
    canvas.drawCircle(
      center,
      186,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final slices = diagram.slices;
    final filteredTotal = slices.fold(0.0, (a, e) => a + e.value);
    var angle = -math.pi / 2;
    for (final entry in slices) {
      final sweep = entry.value / filteredTotal * math.pi * 2;
      final color =
          palette[diagram.sections.keys.toList().indexOf(entry.key) % 12];
      final rect = Rect.fromCircle(center: center, radius: 185);
      final path = Path();
      if (sweep >= math.pi * 2 - 1e-10) {
        path.addOval(rect);
      } else {
        path.moveTo(center.dx, center.dy);
        path.arcTo(rect, angle, sweep, false);
        path.close();
      }
      canvas.saveLayer(
        rect.inflate(2),
        Paint()..color = Colors.white.withValues(alpha: .7),
      );
      canvas.drawPath(path, Paint()..color = color);
      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.black
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      canvas.restore();
      final mid = angle + sweep / 2;
      _label(
        canvas,
        '${(entry.value / diagram.total * 100).round()}%',
        center + Offset(math.cos(mid), math.sin(mid)) * 185 * .75,
        17,
        sliceTextColor,
        centered: true,
      );
      angle += sweep;
    }
    _label(
      canvas,
      diagram.title,
      const Offset(225, 25),
      25,
      legendColor,
      centered: true,
    );
    var index = 0;
    for (final entry in diagram.sections.entries) {
      final y = 225 - diagram.sections.length * 11.0 + index * 22;
      final color = palette[index % 12];
      final rect = Rect.fromLTWH(441, y, 18, 18);
      canvas.drawRect(rect, Paint()..color = color);
      canvas.drawRect(
        rect,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      _label(
        canvas,
        diagram.legend(entry),
        Offset(463, y + 14),
        17,
        legendColor,
      );
      index++;
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant MermaidPiePainter oldDelegate) =>
      oldDelegate.diagram != diagram ||
      oldDelegate.dark != dark ||
      oldDelegate.fontFamily != fontFamily;
}
