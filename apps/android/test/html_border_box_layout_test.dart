import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_text_fields.dart';
import 'package:pirc_render/src/html_document_box.dart';
import 'html_flex_layout_test.dart' show flexDocument;
import 'live_test.dart' show theme;

void main() {
  final fixture =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/html-border-box-layout.json',
            ).readAsStringSync(),
          )
          as Map;
  const colors = {
    'box': Color(0xffef4444),
    'parent': Color(0xff3b82f6),
    'after': Color(0xff22c55e),
  };
  for (final c in fixture['cases'] as List) {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets('Chromium box ${c['id']} ${brightness.name}', (t) async {
        final viewport = c['viewport'] as Map;
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = Size(
          (viewport['width'] as num).toDouble(),
          (viewport['height'] as num).toDouble(),
        );
        addTearDown(t.view.reset);
        final document = flexDocument(c['authoredHTML'] as String);
        try {
          await t.pumpWidget(
            MaterialApp(
              theme: theme.build(brightness),
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
          await t.pumpAndSettle();
          for (final entry in (c['result'] as Map).entries) {
            final color = colors[entry.key], expected = entry.value as Map;
            final found = find.byWidgetPredicate(
              (w) =>
                  w is DecoratedBox &&
                  w.decoration is BoxDecoration &&
                  (w.decoration as BoxDecoration).color == color,
            );
            expect(found, findsOneWidget, reason: '${c['id']} ${entry.key}');
            final rect = t.getRect(found);
            for (final part in {
              'x': rect.left,
              'y': rect.top,
              'width': rect.width,
              'height': rect.height,
            }.entries) {
              expect(
                part.value,
                closeTo((expected[part.key] as num).toDouble(), .1),
                reason: '${c['id']} ${entry.key} ${part.key}',
              );
            }
          }
          expect(t.takeException(), isNull);
        } finally {
          await t.pumpWidget(const SizedBox());
          document.dispose();
        }
      });
    }
  }
  testWidgets('border-box responsive form retains text caret and focus', (
    t,
  ) async {
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final document = flexDocument(
      '<html><head><style>body{margin:0}*{box-sizing:border-box}#form{width:100%;max-width:600px;padding:20px;border:3px solid #111;background:#ef4444}input{width:100%}</style></head><body><div id="form"><input name="note" value="Initial"></div></body></html>',
    );
    Future<void> render(double width) async {
      t.view.physicalSize = Size(width, 900);
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
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
      await t.pumpAndSettle();
    }

    try {
      await render(390);
      final field = find.byType(TextField);
      final fieldBox = find.byType(NativeHtmlTextFieldWidget);
      await t.enterText(field, '保留原生表單草稿');
      final controller = t.widget<TextField>(field).controller!;
      final focus = t.widget<TextField>(field).focusNode!;
      controller.selection = const TextSelection.collapsed(offset: 3);
      await t.pump();
      expect(t.getRect(fieldBox).width, closeTo(344, .1));
      await render(768);
      expect(t.widget<TextField>(field).controller, same(controller));
      expect(t.widget<TextField>(field).focusNode, same(focus));
      expect(focus.hasFocus, isTrue);
      expect(controller.selection, const TextSelection.collapsed(offset: 3));
      expect(controller.text, '保留原生表單草稿');
      expect(t.getRect(fieldBox).width, closeTo(554, .1));
      await render(390);
      expect(t.getRect(fieldBox).width, closeTo(344, .1));
      expect(controller.selection, const TextSelection.collapsed(offset: 3));
      expect(focus.hasFocus, isTrue);
      expect(t.takeException(), isNull);
    } finally {
      await t.pumpWidget(const SizedBox());
      document.dispose();
    }
  });
  testWidgets('fixed border-box width determines intrinsic text height', (
    t,
  ) async {
    final document = flexDocument(
      '<html><head><style>body{margin:0}</style></head><body><div style="box-sizing:border-box;width:100px;padding:6px;border:2px solid #111">One two three four five six seven eight nine ten eleven twelve</div></body></html>',
    );
    try {
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
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
      await t.pumpAndSettle();
      final found = find.byWidgetPredicate(
        (w) => w is NativeDocumentBox && w.applySizing && w.width?.value == 100,
      );
      expect(found, findsOneWidget);
      final box = t.renderObject<RenderBox>(found);
      final actual = box.size.height;
      expect(actual, greaterThan(50));
      expect(box.getMinIntrinsicHeight(300), closeTo(actual, .1));
      expect(box.getMaxIntrinsicHeight(double.infinity), closeTo(actual, .1));
      expect(
        box.getDryLayout(const BoxConstraints(maxWidth: 300)).height,
        closeTo(actual, .1),
      );
      expect(t.takeException(), isNull);
    } finally {
      await t.pumpWidget(const SizedBox());
      document.dispose();
    }
  });
  testWidgets('natural column flex card keeps its native input usable', (
    t,
  ) async {
    final document = flexDocument(
      '<html><head><style>body{margin:0}#column{display:flex;flex-direction:column;align-items:flex-start;width:390px}#card{box-sizing:border-box;padding:10px;border:2px solid #111}</style></head><body><div id="column"><div id="card"><input name="note" value="Initial"></div></div></body></html>',
    );
    try {
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
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
      await t.pumpAndSettle();
      final field = find.byType(TextField);
      expect(field, findsOneWidget);
      expect(
        t.getSize(find.byType(NativeHtmlTextFieldWidget)).width,
        inExclusiveRange(50, 300),
      );
      await t.enterText(field, 'Native column input');
      expect(
        t.widget<TextField>(field).controller!.text,
        'Native column input',
      );
      expect(t.widget<TextField>(field).focusNode!.hasFocus, isTrue);
      expect(t.takeException(), isNull);
    } finally {
      await t.pumpWidget(const SizedBox());
      document.dispose();
    }
  });
}
