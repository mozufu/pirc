import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_render/src/native_html.dart';
import 'document_navigation_widget_test.dart' show DocumentGateway, response;
import 'live_test.dart' show theme;

class UnavailableImageScriptsGateway extends DocumentGateway {
  final capability = Completer<dynamic>();
  int images = 0;
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (method == 'documentScriptCapabilities') return capability.future;
    if (method == 'image') {
      images++;
      return {
        'mimeType': 'image/png',
        'bytes': Uint8List.fromList(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR4nGP4z8DwHwyBNBAw/AcAR8oI+ItOQ4UAAAAASUVORK5CYII=',
          ),
        ),
      };
    }
    return super.call(method, args);
  }
}

void main() {
  testWidgets(
    'unavailable script engine releases deferred ordinary image loading',
    (t) async {
      final g = UnavailableImageScriptsGateway()
        ..responses.add(
          response(
            '/fallback',
            '<img width="32" height="32" src="/photo.png"><script>void 0</script>',
          ),
        );
      final windows = NativeDocumentWindows(g),
          window = windows.target(
            'fallback',
            null,
            sourceUrl: 'https://gateway.example/',
          );
      await window.load(
        const NativeHtmlFormRequest(
          url: '/fallback',
          method: 'GET',
          target: '',
        ),
        baseUrl: window.sourceUrl,
      );
      windows.select(window);
      try {
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            home: NativeDocumentWorkspace(windows: windows),
          ),
        );
        await t.pumpAndSettle();
        expect(g.images, 0);
        expect(
          t
              .widget<NativeHtmlDocument>(find.byType(NativeHtmlDocument))
              .deferImageLoading,
          isTrue,
        );
        g.capability.complete({
          'supported': false,
          'reason': 'synthetic unavailable engine',
        });
        for (var i = 0; i < 30; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 3)),
          );
          await t.pump(const Duration(milliseconds: 16));
          if (g.images == 1 && find.byType(Image).evaluate().isNotEmpty) break;
        }
        expect(
          window.currentDocument!.scripts!.diagnostics,
          contains(contains('synthetic unavailable engine')),
        );
        expect(
          t
              .widget<NativeHtmlDocument>(find.byType(NativeHtmlDocument))
              .deferImageLoading,
          isFalse,
        );
        expect(g.images, 1);
        expect(find.byType(Image), findsOneWidget);
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox.shrink());
        windows.dispose();
        await t.pump();
      }
    },
  );
}
