import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_mobile/live/document_dynamic_styles.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/document_scripts.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'live_test.dart' show theme;

class _Styles extends NativeDocumentScripts {
  _Styles(this.model) : super(Gateway());
  final NativeDynamicDocumentStyles model;
  @override
  List<NativeDocumentStylesheet> get stylesheets => model.stylesheets;
  @override
  Future<void> start({
    required String source,
    required String url,
    String? referrerPolicy,
    String? blobCreatorUrl,
    String referrer = '',
    Json? history,
    String? storageSessionKey,
  }) async {
    ready = true;
  }

  void change(Json snapshot) {
    model.update(snapshot);
    notifyListeners();
  }
}

void main() {
  final oracle =
      jsonDecode(
            File(
              '../../packages/pirc_render/test/fixtures/parity/document-stylesheets-chromium153.json',
            ).readAsStringSync(),
          )
          as Map;
  final inline =
      ((oracle['cases'] as List).singleWhere(
                (item) => item['caseId'] == 'inline-cssom-mutations',
              )
              as Map)['result']
          as Map;
  final initialCss = inline['afterDelete']['cssText'] as String;
  final phases = <String, String>{
    'initial': initialCss,
    'afterInsert': initialCss + (inline['afterInsert']['cssText'] as String),
    'afterSetProperty':
        initialCss + (inline['afterSetProperty']['cssText'] as String),
    'afterDelete': initialCss,
    'afterTextReset': inline['afterTextReset']['cssText'] as String,
  };
  for (final width in [390.0, 768.0]) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'dynamic CSS matches frozen Chromium153 at $width dark=$dark scale=$scale',
          (t) async {
            t.view.physicalSize = Size(width, 1024);
            t.view.devicePixelRatio = 1;
            addTearDown(t.view.resetPhysicalSize);
            addTearDown(t.view.resetDevicePixelRatio);
            final bytes = Uint8List.fromList(
              utf8.encode(
                '<html><body><div id="inlineProbe">Probe</div><script></script></body></html>',
              ),
            );
            final content = NativeHtmlDocumentContent.fromBytes(
              bytes,
              mimeType: 'text/html',
              charset: 'utf-8',
            );
            final model = NativeDynamicDocumentStyles();
            final scripts = _Styles(model)..content = content;
            final document = NativeFetchedDocument(
              id: 1,
              url: 'https://example.test/',
              status: 200,
              bytes: bytes,
              mimeType: 'text/html',
              content: content,
              headers: {},
            )..scripts = scripts;
            addTearDown(document.dispose);
            await t.pumpWidget(
              MaterialApp(
                theme: theme.build(dark ? Brightness.dark : Brightness.light),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: Scaffold(
                  body: NativeFetchedDocumentView(
                    document: document,
                    gateway: Gateway(),
                    onLink: (_) {},
                    onSubmit: (_) {},
                  ),
                ),
              ),
            );
            var revision = 0;
            for (final phase in phases.entries) {
              revision++;
              scripts.change({
                'sheets': [
                  {
                    'id': 'style',
                    'ownerId': 'style',
                    'order': 0,
                    'revision': revision,
                    'requestId': 'style:$revision',
                    'transportId': 'stylesheet-$revision',
                    'baseURL': 'https://example.test/',
                    'cssText': phase.value,
                  },
                ],
                'links': [],
              });
              await t.pumpAndSettle();
              final expected = inline[phase.key]['target'] as Map;
              final parsed = html.parse(content.text);
              final cascade = NativeDocumentStyleEngine(
                stylesheets: model.stylesheets,
                viewportWidth: width,
                dark: dark,
              ).apply(parsed);
              final style = cascade
                  .stylesByElement[parsed.querySelector('#inlineProbe')]!;
              for (final key in ['color', 'width', 'height']) {
                expect(
                  style[key]?.replaceAll(' ', ''),
                  (expected[key] as String).replaceAll(' ', ''),
                  reason: '${phase.key} $key',
                );
              }
              final channels = RegExp(r'\d+')
                  .allMatches(expected['color'] as String)
                  .map((m) => int.parse(m[0]!))
                  .toList();
              final rendered = t
                  .widgetList<RichText>(find.byType(RichText))
                  .singleWhere((r) => r.text.toPlainText() == 'Probe');
              expect(
                rendered.text.style!.color,
                Color.fromRGBO(channels[0], channels[1], channels[2], 1),
                reason: phase.key,
              );
              expect(t.takeException(), isNull);
            }
            await t.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
}
