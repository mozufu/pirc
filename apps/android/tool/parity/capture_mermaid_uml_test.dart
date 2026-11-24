import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_render/src/mermaid/native_mermaid.dart';
import 'package:pirc_render/src/mermaid/state_diagram.dart';
import 'package:pirc_render/src/mermaid/class_diagram.dart';
import '../../test/live_test.dart' show theme;
import 'capture_fonts.dart';

void main() {
  final f = obj(
    jsonDecode(
      File('../../fixtures/mobile-parity/mermaid-uml.json').readAsStringSync(),
    ),
  );
  for (final width in f['widths'] as List) {
    for (final brightness in Brightness.values) {
      for (final item in rows(f['cases'])) {
        testWidgets('native Mermaid UML $width ${brightness.name} ${item['id']}', (
          t,
        ) async {
          await t.runAsync(() async {
            await loadParityFonts();
            // Chromium on this host resolves generic sans-serif to PingFang
            // TC. Mermaid measures it as a fallback even for Latin labels.
            final fallback =
                Directory(
                      '/System/Library/AssetsV2/com_apple_MobileAsset_Font7',
                    )
                    .listSync(recursive: true)
                    .whereType<File>()
                    .firstWhere((file) => file.path.endsWith('/PingFang.ttc'));
            await (FontLoader('sans-serif')
                  ..addFont(fallback.readAsBytes().then(ByteData.sublistView)))
                .load();
            await (FontLoader('Mermaid reference')..addFont(
                  File(
                    '/System/Library/Fonts/SFNS.ttf',
                  ).readAsBytes().then(ByteData.sublistView),
                ))
                .load();
          });
          t.view.devicePixelRatio = 1;
          t.view.physicalSize = Size(
            (width as num).toDouble(),
            (f['height'] as num).toDouble(),
          );
          addTearDown(t.view.reset);
          final key = GlobalKey();
          await t.pumpWidget(
            RepaintBoundary(
              key: key,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: theme
                    .build(brightness)
                    .copyWith(
                      textTheme: theme
                          .build(brightness)
                          .textTheme
                          .apply(fontFamily: 'Mermaid reference'),
                    ),
                home: Scaffold(
                  body: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        NativeMarkdown(
                          source: item['source'] as String,
                          lineHeight: 1.65,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await t.pumpAndSettle();
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await t.pumpAndSettle();
          expect(t.takeException(), isNull);
          final expected = obj(
            jsonDecode(
              File(
                '../../fixtures/mobile-parity/mermaid-uml-expected.json',
              ).readAsStringSync(),
            ),
          );
          final reference = rows(
            rows(
              obj(obj(expected['themes'])[brightness.name])['widths'],
            ).firstWhere((row) => row['width'] == width)['cases'],
          ).firstWhere((row) => row['id'] == item['id']);
          expect(
            find.textContaining('Mermaid:'),
            reference['status'] == 'ok' ? findsNothing : findsOneWidget,
          );
          final figure = t.getSize(find.byType(NativeMermaid));
          Map<String, Object?>? geometry;
          if (reference['status'] == 'ok') {
            final source = (item['source'] as String)
                .replaceFirst(RegExp(r'^```mermaid\s*'), '')
                .replaceFirst(RegExp(r'\s*```$'), '');
            if (item['kind'] == 'state') {
              final layout = layoutNativeMermaidStateDiagram(
                parseNativeMermaidStateDiagram(source),
                fontFamily: 'Mermaid reference',
              );
              geometry = {
                'width': layout.size.width,
                'height': layout.size.height,
                'nodes': [
                  for (final node in layout.nodes)
                    {
                      'id': node.node.id,
                      'x': node.bounds.left,
                      'y': node.bounds.top,
                      'width': node.bounds.width,
                      'height': node.bounds.height,
                    },
                ],
              };
            } else {
              final layout = layoutNativeMermaidClassDiagram(
                parseNativeMermaidClassDiagram(source),
                fontFamily: 'Mermaid reference',
              );
              geometry = {
                'width': layout.size.width,
                'height': layout.size.height,
              };
            }
          }
          Directory('build/parity').createSync(recursive: true);
          File(
            'build/parity/mermaid-uml-native-$width-${brightness.name}-${item['id']}-metrics.json',
          ).writeAsStringSync(
            jsonEncode({
              'id': item['id'],
              'width': figure.width,
              'height': figure.height,
              'referenceBlock': reference['block'],
              'naturalGeometry': geometry,
              'comparisonFont':
                  'host SFNS.ttf as Mermaid reference; PingFang.ttc as generic sans-serif; optical metrics may differ from browser system UI',
            }),
          );

          await t.runAsync(() async {
            final capture =
                await (key.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await capture.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/parity/mermaid-uml-native-$width-${brightness.name}-${item['id']}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            capture.dispose();
          });
          await t.pumpWidget(const SizedBox());
        });
      }
    }
  }
}
