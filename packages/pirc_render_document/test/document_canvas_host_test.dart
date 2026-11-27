@Tags(['tier3'])
library;

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render_document/src/document_scripts.dart';
import 'support/legacy_scripts_platform.dart';
import 'package:pirc_render_document/src/document_canvas.dart';
import 'package:pirc_render/src/native_html.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'support/render_theme.dart';

Map<String, Object?> snapshot(int revision) => {
  'id': 'c',
  'width': 120,
  'height': 60,
  'revision': revision,
  'commands': [],
};

class CanvasGateway extends LegacyScriptsPlatform {
  int revision = 0;
  bool timer = true;
  Object? overrideCanvases;
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    if (method == 'documentScriptCapabilities') return {'supported': true};
    if (method == 'documentScriptOpen') return {'id': 1};
    if (method == 'documentScriptClose') return null;
    if (method == 'documentScriptEvaluate') {
      final source = args['source'] as String;
      if (source == 'runtime') return {'value': ''};
      if (source.startsWith('__pircDocument.pump')) {
        revision++;
        timer = false;
      }
      return {
        'value': jsonEncode({
          'html':
              '<html><body><canvas data-pirc-script-id="c" width="120" height="60"></canvas></body></html>',
          'canvases': overrideCanvases ?? [snapshot(revision)],
          'diagnostics': [],
          'scheduler': {
            'timerDelayMs': timer ? 20 : null,
            'animationFrame': false,
          },
        }),
      };
    }
    throw StateError(method);
  }
}

void main() {
  testWidgets('canvas-only timer notifies without changing the DOM snapshot', (
    t,
  ) async {
    final gateway = CanvasGateway();
    double now = 0;
    final scripts = NativeDocumentScripts(
      gateway,
      clockMilliseconds: () => now,
    );
    await scripts.start(
      source: '<script></script>',
      url: 'https://example.test/',
    );
    expect(scripts.ready, true);
    final content = scripts.content;
    final canvases = scripts.canvases;
    var notifications = 0;
    scripts.addListener(() => notifications++);
    now = 20;
    await t.pump(const Duration(milliseconds: 20));
    await t.pump();
    expect(scripts.content, same(content));
    expect(scripts.canvases, isNot(same(canvases)));
    expect(scripts.canvases['c']!.revision, 1);
    expect(notifications, 1);
    await scripts.click('c', []);
    expect(scripts.canvases['c']!.revision, 1);
    gateway.overrideCanvases = [];
    await scripts.click('c', []);
    expect(scripts.canvases, isEmpty);
    scripts.dispose();
    await t.pump();
  });

  testWidgets('duplicate canvas identity rejects snapshot and closes runtime', (
    t,
  ) async {
    final gateway = CanvasGateway()
      ..overrideCanvases = [snapshot(0), snapshot(1)];
    final scripts = NativeDocumentScripts(gateway);
    await scripts.start(
      source: '<script></script>',
      url: 'https://example.test/',
    );
    expect(scripts.ready, false);
    expect(scripts.diagnostics.join(), contains('Duplicate document canvas'));
    scripts.dispose();
    await t.pump();
  });

  testWidgets(
    'native canvas follows author CSS sizing and refreshes without resetting inputs',
    (t) async {
      final doc = Object();
      final content = Object();
      Future<void> show(int revision) => t.pumpWidget(
        MaterialApp(
          theme: renderTestTheme(),
          home: Scaffold(
            body: NativeHtmlDocument(
              nodes: [
                NativeHtmlRaw(
                  '<input value="initial"><div><canvas data-pirc-script-id="c" width="120" height="60" style="width:240px;height:90px;border:2px solid red;padding:3px">fallback hidden</canvas></div>',
                ),
              ],
              style: const TextStyle(fontSize: 16),
              styles: MarkdownStyleSheet(),
              builders: const {},
              markdownStyles: false,
              scriptDocument: doc,
              scriptSnapshot: content,
              canvases: {
                'c': NativeDocumentCanvasSnapshot.fromJson(snapshot(revision)),
              },
            ),
          ),
        ),
      );
      await show(0);
      await t.pumpAndSettle();
      expect(find.byType(NativeDocumentCanvas), findsOneWidget);
      expect(t.getSize(find.byType(NativeDocumentCanvas)), const Size(240, 90));
      expect(find.text('fallback hidden', findRichText: true), findsNothing);
      await t.enterText(find.byType(TextField), 'local draft');
      await show(1);
      await t.pumpAndSettle();
      expect(
        t
            .widget<NativeDocumentCanvas>(find.byType(NativeDocumentCanvas))
            .snapshot
            .revision,
        1,
      );
      expect(
        t.widget<TextField>(find.byType(TextField)).controller!.text,
        'local draft',
      );
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('canvas width-only and height-only CSS keep the intrinsic ratio', (
    t,
  ) async {
    for (final (style, size) in [
      ('width:240px', const Size(240, 120)),
      ('height:90px', const Size(180, 90)),
      ('', const Size(120, 60)),
    ]) {
      await t.pumpWidget(
        MaterialApp(
          theme: renderTestTheme(),
          home: Scaffold(
            body: NativeHtmlDocument(
              nodes: [
                NativeHtmlRaw(
                  '<p><canvas data-pirc-script-id="c" width="120" height="60" style="$style"></canvas></p>',
                ),
              ],
              style: const TextStyle(fontSize: 16),
              styles: MarkdownStyleSheet(),
              builders: const {},
              markdownStyles: false,
              // Canvases draw only in a script-driven document.
              scriptDocument: style,
              canvases: {
                'c': NativeDocumentCanvasSnapshot.fromJson(snapshot(0)),
              },
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(t.getSize(find.byType(NativeDocumentCanvas)), size, reason: style);
      expect(t.takeException(), isNull);
    }
  });
}
