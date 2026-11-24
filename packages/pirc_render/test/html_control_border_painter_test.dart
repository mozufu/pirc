import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_control_border_painter.dart';

Future<Uint8List> _capture(
  WidgetTester tester, {
  required NativeHtmlControlBorderPainter painter,
  required Size size,
}) async {
  final key = UniqueKey();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: key,
            child: CustomPaint(size: size, painter: painter),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(key));
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return Uint8List.fromList(data!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
  return bytes!;
}

Color _pixel(Uint8List rgba, int width, int x, int y) {
  final offset = (y * width + x) * 4;
  return Color.fromARGB(
    rgba[offset + 3],
    rgba[offset],
    rgba[offset + 1],
    rgba[offset + 2],
  );
}

Border _border({
  BorderSide top = BorderSide.none,
  BorderSide right = BorderSide.none,
  BorderSide bottom = BorderSide.none,
  BorderSide left = BorderSide.none,
}) => Border(top: top, right: right, bottom: bottom, left: left);

void main() {
  testWidgets('solid border paints per-side width and color', (tester) async {
    final rgba = await _capture(
      tester,
      size: const Size(60, 40),
      painter: NativeHtmlControlBorderPainter(
        border: _border(
          top: const BorderSide(color: Color(0xffff0000), width: 4),
          right: const BorderSide(color: Color(0xff00ff00), width: 6),
          bottom: const BorderSide(color: Color(0xff0000ff), width: 2),
          left: const BorderSide(color: Color(0xffffff00), width: 3),
        ),
        styleNames: const {
          'top': 'solid',
          'right': 'solid',
          'bottom': 'solid',
          'left': 'solid',
        },
        borderRadius: BorderRadius.zero,
      ),
    );

    expect(_pixel(rgba, 60, 30, 1), const Color(0xffff0000));
    expect(_pixel(rgba, 60, 58, 20), const Color(0xff00ff00));
    expect(_pixel(rgba, 60, 30, 38), const Color(0xff0000ff));
    expect(_pixel(rgba, 60, 1, 20), const Color(0xffffff00));
    expect(_pixel(rgba, 60, 30, 20), Colors.transparent);
  });

  testWidgets('solid border clips to the CSS rounded outer bounds', (
    tester,
  ) async {
    final rgba = await _capture(
      tester,
      size: const Size(40, 40),
      painter: NativeHtmlControlBorderPainter(
        border: Border.all(color: const Color(0xffd02030), width: 4),
        styleNames: const {'top': 'solid'},
        borderRadius: BorderRadius.circular(16),
      ),
    );

    expect(_pixel(rgba, 40, 0, 0), Colors.transparent);
    expect(_pixel(rgba, 40, 20, 1), const Color(0xffd02030));
    expect(_pixel(rgba, 40, 20, 20), Colors.transparent);
  });

  testWidgets('dotted border uses separated round dots', (tester) async {
    final rgba = await _capture(
      tester,
      size: const Size(60, 20),
      painter: NativeHtmlControlBorderPainter(
        border: _border(
          top: const BorderSide(color: Color(0xffc020d0), width: 4),
        ),
        styleNames: const {'top': 'dotted'},
        borderRadius: BorderRadius.zero,
      ),
    );

    expect(_pixel(rgba, 60, 2, 2), const Color(0xffc020d0));
    expect(_pixel(rgba, 60, 6, 2), Colors.transparent);
    expect(_pixel(rgba, 60, 10, 2), const Color(0xffc020d0));
  });

  testWidgets('dashed border paints distinct dash and gap segments', (
    tester,
  ) async {
    final rgba = await _capture(
      tester,
      size: const Size(60, 20),
      painter: NativeHtmlControlBorderPainter(
        border: _border(
          top: const BorderSide(color: Color(0xff2080d0), width: 4),
        ),
        styleNames: const {'top': 'dashed'},
        borderRadius: BorderRadius.zero,
      ),
    );

    expect(_pixel(rgba, 60, 5, 2), const Color(0xff2080d0));
    expect(_pixel(rgba, 60, 16, 2), Colors.transparent);
    expect(_pixel(rgba, 60, 24, 2), const Color(0xff2080d0));
  });

  testWidgets('double border paints two bands separated by a gap', (
    tester,
  ) async {
    final rgba = await _capture(
      tester,
      size: const Size(60, 20),
      painter: NativeHtmlControlBorderPainter(
        border: _border(
          top: const BorderSide(color: Color(0xff5030c0), width: 9),
        ),
        styleNames: const {'top': 'double'},
        borderRadius: BorderRadius.zero,
      ),
    );

    expect(_pixel(rgba, 60, 30, 1), const Color(0xff5030c0));
    expect(_pixel(rgba, 60, 30, 4), Colors.transparent);
    expect(_pixel(rgba, 60, 30, 7), const Color(0xff5030c0));
    expect(_pixel(rgba, 60, 30, 10), Colors.transparent);
  });

  testWidgets('none is unpainted and unsupported relief styles are reported', (
    tester,
  ) async {
    const painter = NativeHtmlControlBorderPainter(
      border: Border(
        top: BorderSide(color: Color(0xffa03040), width: 4),
        right: BorderSide.none,
        bottom: BorderSide.none,
        left: BorderSide.none,
      ),
      styleNames: {'top': 'groove', 'right': 'none'},
      borderRadius: BorderRadius.zero,
    );
    expect(painter.unsupportedStyles, const {'top': 'groove'});

    final rgba = await _capture(
      tester,
      size: const Size(40, 20),
      painter: painter,
    );
    expect(_pixel(rgba, 40, 20, 1), const Color(0xffa03040));
    expect(_pixel(rgba, 40, 20, 5), Colors.transparent);
  });
}
