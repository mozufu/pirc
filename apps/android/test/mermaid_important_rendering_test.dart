import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_render/src/mermaid/native_mermaid.dart';
import 'package:pirc_render/src/mermaid/packet_rendering.dart';
import 'package:pirc_render/src/mermaid/radar_rendering.dart';
import 'package:pirc_render/src/mermaid/architecture_rendering.dart';
import 'live_test.dart' show theme;

void main() {
  final reference =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/mermaid-important-web.json',
            ).readAsStringSync(),
          )
          as Map;
  final fixtures =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/mermaid-important-cases.json',
            ).readAsStringSync(),
          )
          as Map;
  final types = <String, Type>{
    'packet': NativeMermaidPacket,
    'radar': NativeMermaidRadar,
    'architecture': NativeMermaidArchitecture,
  };
  for (final input in fixtures['cases'] as List) {
    for (final width in [390.0, 650.0, 651.0, 768.0, 860.0, 861.0, 1024.0]) {
      for (final brightness in Brightness.values) {
        for (final scale in [1.0, 2.0]) {
          testWidgets('${input['id']} $width ${brightness.name} $scale', (
            tester,
          ) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 1100);
            addTearDown(tester.view.reset);
            final semantics = tester.ensureSemantics();
            try {
              final expected = (reference['captures'] as List).firstWhere(
                (c) =>
                    c['id'] == input['id'] &&
                    c['colorScheme'] == brightness.name,
              );
              const boundary = ValueKey('important-diagram');
              await tester.pumpWidget(
                MaterialApp(
                  theme: theme.build(brightness),
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      textScaler: TextScaler.linear(scale),
                      size: Size(width, 1100),
                      devicePixelRatio: 1,
                    ),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: width,
                        height: 1100,
                        child: child!,
                      ),
                    ),
                  ),
                  home: Scaffold(
                    body: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: RepaintBoundary(
                        key: boundary,
                        child: NativeMarkdown(
                          source: '```mermaid\n${input['source']}\n```',
                        ),
                      ),
                    ),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              final figure = find.byWidgetPredicate(
                (widget) => widget.runtimeType == types[input['family']],
              );
              expect(figure, findsOneWidget);
              expect(find.textContaining('Mermaid:'), findsNothing);
              expect(find.text(input['source'] as String), findsNothing);
              final size = tester.getSize(figure);
              expect(size.width, greaterThan(0));
              expect(size.height, greaterThan(0));
              expect(size.width, lessThanOrEqualTo(width - 32));
              final labels = <String>{
                for (final label in expected['labels'] as List)
                  if ((label['text'] as String).isNotEmpty &&
                      !('${label['class']}'.startsWith('packetByte')))
                    label['text'] as String,
              };
              for (final label in labels) {
                expect(
                  find.bySemanticsLabel(RegExp(RegExp.escape(label))),
                  findsWidgets,
                  reason: 'Browser label $label must survive native rendering',
                );
              }
              // Packet/radar have deterministic viewBox scaling; architecture
              // uses a native topology layout with separately checked bounds.
              if (input['family'] != 'architecture' &&
                  [390.0, 768.0].contains(width)) {
                final geometry = (reference['captures'] as List).firstWhere(
                  (c) =>
                      c['id'] == input['id'] &&
                      c['width'] == width &&
                      c['colorScheme'] == brightness.name,
                )['box'];
                final canvas = find.descendant(
                  of: figure,
                  matching: find.byType(CustomPaint),
                );
                expect(canvas, findsOneWidget);
                final paintedSize = tester.getSize(canvas);
                expect(
                  paintedSize.width,
                  closeTo((geometry['width'] as num).toDouble(), 1),
                );
                expect(
                  paintedSize.height,
                  closeTo((geometry['height'] as num).toDouble(), 1),
                );
              }
              // Representative host snapshots validate that content is painted,
              // beyond merely finding a mounted renderer or semantic model.
              if (width == 390 && scale == 1) {
                final colors = await tester.runAsync(() async {
                  final image = await tester
                      .renderObject<RenderRepaintBoundary>(find.byKey(boundary))
                      .toImage(pixelRatio: 1);
                  try {
                    final output = Directory(
                      'build/parity-acceptance/important-mermaid-native',
                    );
                    output.createSync(recursive: true);
                    final png = (await image.toByteData(
                      format: ui.ImageByteFormat.png,
                    ))!;
                    File(
                      '${output.path}/${input['id']}-$width-${brightness.name}.png',
                    ).writeAsBytesSync(
                      png.buffer.asUint8List(
                        png.offsetInBytes,
                        png.lengthInBytes,
                      ),
                    );
                    final data = (await image.toByteData(
                      format: ui.ImageByteFormat.rawRgba,
                    ))!;
                    final pixels = data.buffer.asUint8List(
                      data.offsetInBytes,
                      data.lengthInBytes,
                    );
                    final unique = <int>{};
                    for (var i = 0; i + 3 < pixels.length; i += 16) {
                      if (pixels[i + 3] > 0) {
                        unique.add(
                          (pixels[i] << 16) |
                              (pixels[i + 1] << 8) |
                              pixels[i + 2],
                        );
                      }
                    }
                    return unique.length;
                  } finally {
                    image.dispose();
                  }
                });
                expect(colors, greaterThan(3));
              }
              expect(tester.takeException(), isNull);
            } finally {
              await tester.pumpWidget(const SizedBox());
              semantics.dispose();
            }
          });
        }
      }
    }
  }
  testWidgets('streaming and invalid source remain recoverable', (
    tester,
  ) async {
    const sources = [
      'packet-beta\n+0: "Invalid"',
      'radar-beta\naxis a["A"]\ncurve x{a: invalid}',
      'architecture-beta\nservice one(server)[One]\none:R -- L:missing',
    ];
    for (final source in sources) {
      for (final ready in [false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            home: Scaffold(
              body: NativeMermaid(source: source, ready: ready),
            ),
          ),
        );
        await tester.pump();
        expect(find.text(source), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    }
  });
}
