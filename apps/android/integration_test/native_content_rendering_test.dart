import 'package:pirc_mobile/live/remote_content_gate.dart';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/theme.dart';
import 'package:pirc_mobile/rendering/native_markdown.dart';
import 'package:pirc_mobile/rendering/mermaid/kanban_rendering.dart';
import 'package:pirc_mobile/rendering/mermaid/sankey_rendering.dart';
import 'package:pirc_mobile/rendering/mermaid/block_rendering.dart';
import 'package:pirc_mobile/live/markdown_image.dart';
import 'package:pirc_mobile/live/gateway.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // These suites exercise the image/media loaders themselves, not the hold-back.
  setUpAll(() => NativeRemoteContentPolicy.debugOpenForTests = true);
  tearDownAll(() => NativeRemoteContentPolicy.debugOpenForTests = false);
  testWidgets(
    'Android renders common diagrams and advances animated image frames',
    (t) async {
      expect(
        const bool.fromEnvironment('PIRC_NATIVE_CONTENT_ACCEPTANCE'),
        isTrue,
      );
      final input =
          jsonDecode(
                const String.fromEnvironment('PIRC_NATIVE_CONTENT_FIXTURES'),
              )
              as Map;
      final appTheme = await PircTheme.load();
      final figures = <String, Type>{
        'kanban': NativeMermaidKanban,
        'sankey': NativeMermaidSankey,
        'block': NativeMermaidBlockChart,
      };
      for (final brightness in Brightness.values) {
        for (final name in figures.keys) {
          final source = input[name] as String;
          await t.pumpWidget(
            MaterialApp(
              theme: appTheme.build(brightness),
              home: Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: NativeMarkdown(
                    source: '```mermaid\n$source\n```',
                    lineHeight: 1.65,
                  ),
                ),
              ),
            ),
          );
          await t.pumpAndSettle();
          final figure = find.byWidgetPredicate(
            (w) => w.runtimeType == figures[name],
          );
          expect(figure, findsOneWidget, reason: '$name $brightness');
          expect(figure.hitTestable(), findsOneWidget);
          expect(t.takeException(), isNull);
          debugPrint('NATIVE_CONTENT_ACCEPTED:$name:${brightness.name}');
        }
      }
      for (final item in input['animations'] as List) {
        final bytes = base64Decode(item['base64'] as String);
        await t.pumpWidget(
          MaterialApp(
            theme: appTheme.build(Brightness.light),
            home: Scaffold(
              body: NativeMarkdownImage(
                gateway: Gateway(),
                source: Uri.dataFromBytes(
                  bytes,
                  mimeType: item['mimeType'] as String,
                ),
                borderRadius: 0,
              ),
            ),
          ),
        );
        Future<List<int>> current() async {
          await t.pump(const Duration(milliseconds: 20));
          final images = t
              .widgetList<RawImage>(find.byType(RawImage))
              .where((w) => w.image != null)
              .toList();
          if (images.isEmpty) return [];
          final data = await images.single.image!.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          return data!.buffer.asUint8List().take(4).toList();
        }

        var red = false, blue = false;
        for (var i = 0; i < 150 && !blue; i++) {
          final p = await current();
          if (p.isEmpty) continue;
          if (p[0] > 200 && p[1] < 20 && p[2] < 20) red = true;
          if (red && p[2] > 200 && p[0] < 20 && p[1] < 20) blue = true;
        }
        expect(red, isTrue, reason: '${item['id']} first displayed frame');
        expect(blue, isTrue, reason: '${item['id']} next displayed frame');
        expect(t.takeException(), isNull);
        debugPrint('NATIVE_CONTENT_ANIMATION:${item['id']}:red-to-blue');
      }
      await t.pumpWidget(const SizedBox());
      await t.pump();
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
