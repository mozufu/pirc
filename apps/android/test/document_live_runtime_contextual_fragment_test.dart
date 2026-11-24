import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/document_scripts.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_form_submission.dart';

import 'document_navigation_widget_test.dart' show response;
import 'live_test.dart' show theme;
import 'support/document_vm_gateway.dart';

const _html = '''<!doctype html><html><body>
<div id="host"></div><p id="status">waiting</p>
<script>
const host = document.getElementById('host');
const range = document.createRange();
range.selectNodeContents(host);
const markup = '<script>document.getElementById("status").textContent="ready";<' +
  '/script><button id="generated">Go</button>';
host.appendChild(range.createContextualFragment(markup));
document.getElementById('generated').addEventListener('click', () => {
  document.getElementById('status').textContent = 'clicked';
});
</script></body></html>''';

const _svgHtml =
    '''<!doctype html><html><head><style>html,body{margin:0}</style></head><body>
<svg id="vector" width="40" height="40" viewBox="0 0 40 40"></svg>
<script>
(function(){
  const vector=document.getElementById('vector');
  const range=document.createRange();range.selectNodeContents(vector);
  vector.appendChild(range.createContextualFragment(
    '<circle cx="20" cy="20" r="12" fill="#ff0000"/>'));
})();
</script></body></html>''';

void main() {
  final runtime = File('assets/document-script-runtime.js').readAsStringSync();
  final svgPaintFixture =
      jsonDecode(
            File(
              'tool/parity/fixtures/document-contextual-fragment-chromium153.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  for (final width in [390.0, 768.0]) {
    testWidgets('contextual fragment paints and responds at width $width', (
      t,
    ) async {
      final gateway = (await t.runAsync(DocumentVmGateway.start))!
        ..responses.add(response('/test', _html));
      final windows = NativeDocumentWindows(gateway);
      final window = windows.target(
        'fragment',
        null,
        sourceUrl: 'https://fragment.example/',
      );
      await window.load(
        const NativeHtmlFormRequest(url: '/test', method: 'GET', target: ''),
        baseUrl: window.sourceUrl,
      );
      windows.select(window);
      final document = window.currentDocument!;
      document.scripts = NativeDocumentScripts(
        gateway,
        loadRuntime: () async => runtime,
      );
      final button = find.byWidgetPredicate(
        (widget) =>
            widget is NativeHtmlButtonWidget && widget.button.label == 'Go',
      );
      Finder status(String value) => find.byWidgetPredicate(
        (widget) =>
            widget is RichText && widget.text.toPlainText().contains(value),
      );
      try {
        t.view.physicalSize = Size(width, 844);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            home: NativeDocumentWorkspace(windows: windows),
          ),
        );
        await driveDocumentVm(
          t,
          () =>
              document.scripts!.ready &&
              !document.scripts!.hasPendingPublication &&
              button.evaluate().isNotEmpty &&
              status('ready').evaluate().isNotEmpty,
          reason: 'contextual fragment published',
          diagnostic: () => document.scripts!.diagnostics.toString(),
        );
        expect(
          await t.runAsync(
            () => gateway.inspect(
              "document.getElementById('status').textContent",
            ),
          ),
          'ready',
        );
        await t.tap(button);
        await driveDocumentVm(
          t,
          () =>
              status('clicked').evaluate().isNotEmpty &&
              !document.scripts!.hasPendingPublication,
          reason: 'fragment button updates native text',
          diagnostic: () => document.scripts!.diagnostics.toString(),
        );
        expect(
          await t.runAsync(
            () => gateway.inspect(
              "document.getElementById('status').textContent",
            ),
          ),
          'clicked',
        );
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox.shrink());
        final scripts = document.scripts;
        windows.dispose();
        var closed = false;
        (scripts?.closed ?? Future<void>.value()).then((_) => closed = true);
        await driveDocumentVm(
          t,
          () => closed && gateway.closes == gateway.opens,
          reason: 'retire contextual fragment document',
        );
        await t.runAsync(gateway.close);
        await t.pump();
      }
    });
    testWidgets('contextual SVG fragment paints at width $width', (t) async {
      final expected =
          (svgPaintFixture['svgPaint'] as List).singleWhere(
                (row) => row['width'] == width,
              )
              as Map;
      final gateway = (await t.runAsync(DocumentVmGateway.start))!
        ..responses.add(response('/svg', _svgHtml));
      final windows = NativeDocumentWindows(gateway);
      final window = windows.target(
        'svg-fragment',
        null,
        sourceUrl: 'https://fragment.example/',
      );
      await window.load(
        const NativeHtmlFormRequest(url: '/svg', method: 'GET', target: ''),
        baseUrl: window.sourceUrl,
      );
      windows.select(window);
      final document = window.currentDocument!;
      document.scripts = NativeDocumentScripts(
        gateway,
        loadRuntime: () async => runtime,
      );
      final paintKey = GlobalKey();
      try {
        t.view.physicalSize = Size(width, 844);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await t.pumpWidget(
          RepaintBoundary(
            key: paintKey,
            child: MaterialApp(
              theme: theme.build(Brightness.light),
              home: NativeDocumentWorkspace(windows: windows),
            ),
          ),
        );
        await driveDocumentVm(
          t,
          () =>
              document.scripts!.ready &&
              !document.scripts!.hasPendingPublication &&
              find.byType(SvgPicture).evaluate().isNotEmpty,
          reason: 'contextual SVG fragment painted',
          diagnostic: () => document.scripts!.diagnostics.toString(),
        );
        final svg = find.byType(SvgPicture).first;
        final box = t.getRect(svg);
        expect(box.width, closeTo(expected['rect'][2] as num, 1 / 32));
        expect(box.height, closeTo(expected['rect'][3] as num, 1 / 32));
        final image = (await t.runAsync(
          () => t
              .renderObject<RenderRepaintBoundary>(find.byKey(paintKey))
              .toImage(pixelRatio: 1),
        ))!;
        try {
          final bytes = (await t.runAsync(
            () => image.toByteData(format: ui.ImageByteFormat.rawStraightRgba),
          ))!;
          final center = box.center;
          final offset =
              (center.dy.floor() * image.width + center.dx.floor()) * 4;
          expect([
            for (var channel = 0; channel < 4; channel++)
              bytes.getUint8(offset + channel),
          ], expected['centerPixel']);
        } finally {
          image.dispose();
        }
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox.shrink());
        final scripts = document.scripts;
        windows.dispose();
        var closed = false;
        (scripts?.closed ?? Future<void>.value()).then((_) => closed = true);
        await driveDocumentVm(
          t,
          () => closed && gateway.closes == gateway.opens,
          reason: 'retire SVG contextual fragment document',
        );
        await t.runAsync(gateway.close);
        await t.pump();
      }
    });
  }
}
