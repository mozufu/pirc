import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_controls.dart';
import 'package:pirc_render/src/native_markdown.dart';

import '../../test/live_test.dart' show theme;
import 'capture_fonts.dart';

Map<String, dynamic> interactionObject(dynamic value) =>
    (value as Map).map((key, value) => MapEntry('$key', value));

List<Map<String, dynamic>> interactionRows(dynamic value) =>
    (value as List).map(interactionObject).toList();

final interactionFixture = interactionObject(
  jsonDecode(
    File(
      '../../fixtures/mobile-parity/html-interactions.json',
    ).readAsStringSync(),
  ),
);
final interactionExpected = interactionObject(
  jsonDecode(
    File(
      '../../fixtures/mobile-parity/html-interactions-expected.json',
    ).readAsStringSync(),
  ),
);

Map<String, dynamic> interactionWebCase(
  int width,
  Brightness brightness,
  String id,
) {
  final themeReference = interactionObject(
    interactionObject(interactionExpected['themes'])[brightness.name],
  );
  final widthReference = interactionRows(
    themeReference['widths'],
  ).singleWhere((row) => row['width'] == width);
  return interactionRows(
    widthReference['cases'],
  ).singleWhere((row) => row['id'] == id);
}

Map<String, dynamic> interactionWebPhase(
  int width,
  Brightness brightness,
  String id,
  String phase,
) {
  final item = interactionWebCase(width, brightness, id);
  return interactionRows(
    item['observations'],
  ).singleWhere((row) => row['phase'] == phase);
}

class NativeInteractionControl {
  const NativeInteractionControl({
    required this.id,
    required this.element,
    required this.widget,
  });

  final String? id;
  final dom.Element element;
  final NativeHtmlControlWidget widget;
  bool get checked => widget.state.isChecked(widget.control.key);
}

typedef InteractionPhaseCallback =
    Future<void> Function(NativeInteractionSession session, String phase);

class NativeInteractionSession {
  NativeInteractionSession(this.tester, this.width, this.brightness);

  final WidgetTester tester;
  final int width;
  final Brightness brightness;
  final GlobalKey repaintKey = GlobalKey();
  int _mountId = 0;
  String _caseId = '';

  Future<void> mount(String source, String caseId) async {
    _caseId = caseId;
    final baseTheme = theme.build(brightness);
    final fontTheme = baseTheme.copyWith(
      textTheme: baseTheme.textTheme.apply(fontFamily: 'Arial'),
    );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(
      width.toDouble(),
      (interactionFixture['height'] as num).toDouble(),
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: repaintKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: fontTheme,
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  KeyedSubtree(
                    key: ValueKey('$_caseId-$_mountId'),
                    child: NativeMarkdown(
                      source: source,
                      fontSize: 15,
                      lineHeight: 1.65,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Resolve the DOM selector against HtmlWidget's reparsed annotated HTML,
  /// then resolve each marker back to its stateful native control.
  List<NativeInteractionControl> controls() {
    final elements = <String, dom.Element>{};
    for (final widget in tester.widgetList<HtmlWidget>(
      find.byType(HtmlWidget),
    )) {
      final fragment = html.parseFragment(widget.html);
      for (final input in fragment.querySelectorAll('input')) {
        final key = input.attributes['data-pirc-native-control-id'];
        if (key != null) elements[key] = input;
      }
    }

    final widgets = tester
        .widgetList<NativeHtmlControlWidget>(
          find.byType(NativeHtmlControlWidget),
        )
        .toList();
    return [
      for (final widget in widgets)
        for (final entry in elements.entries)
          if (entry.key == widget.control.key)
            NativeInteractionControl(
              id: entry.value.attributes['id'],
              element: entry.value,
              widget: widget,
            ),
    ];
  }

  NativeInteractionControl controlFor(dom.Element element) {
    if (element.localName != 'input') {
      throw ArgumentError.value(element.localName, 'element', 'Expected input');
    }
    final matches = controls()
        .where(
          (control) =>
              control.element.attributes['id'] == element.attributes['id'],
        )
        .toList();
    if (matches.length != 1) {
      throw StateError(
        'Could not resolve native input #${element.attributes['id']} in $_caseId',
      );
    }
    final nativeControl = matches.single;
    // Exercise the state API against the independently reparsed HtmlWidget DOM.
    final resolved = nativeControl.widget.state.resolveControl(element);
    if (resolved?.key != nativeControl.widget.control.key) {
      throw StateError('HtmlWidget input marker failed to resolve');
    }
    return nativeControl;
  }

  dom.Element? elementForSelector(String selector) {
    for (final widget in tester.widgetList<HtmlWidget>(
      find.byType(HtmlWidget),
    )) {
      final fragment = html.parseFragment(widget.html);
      final element = fragment.querySelector(selector);
      if (element != null) return element;
    }
    return null;
  }

  Future<void> activateLabel(String selector) async {
    final label = elementForSelector(selector);
    if (label == null || label.localName != 'label') {
      throw StateError('No rendered label matches $selector in $_caseId');
    }
    for (final control in controls()) {
      final resolved = control.widget.state.resolveLabel(label);
      if (resolved?.key != control.widget.control.key) continue;
      final text = _normalText(label.text);
      await tapInteractionText(tester, text);
      return;
    }
    // Labels for non-checkbox/radio controls still get a normal text tap.
    await tapInteractionText(tester, _normalText(label.text));
  }

  Future<void> tapSelectorText(String selector) async {
    final element = elementForSelector(selector);
    if (element == null) {
      throw StateError('No rendered element matches $selector in $_caseId');
    }
    await tapInteractionText(tester, _normalText(element.text));
  }

  Future<void> pressKeyOn(String selector, LogicalKeyboardKey key) async {
    final element = elementForSelector(selector);
    if (element == null) {
      throw StateError('No rendered element matches $selector in $_caseId');
    }
    if (element.localName == 'input') {
      final control = controlFor(element);
      control.widget.state.focusControl(control.widget.control.key);
    } else {
      final text = _normalText(element.text);
      final textFinder = interactionRichText(text).first;
      await tester.ensureVisible(textFinder);
      await tester.pumpAndSettle();
      final focusables = find.ancestor(
        of: textFinder,
        matching: find.byType(FocusableActionDetector),
      );
      if (focusables.evaluate().isEmpty) {
        throw StateError(
          'No FocusableActionDetector ancestor for keyboard target $selector',
        );
      }
      final focusNode = tester
          .widget<FocusableActionDetector>(focusables.first)
          .focusNode;
      if (focusNode == null) {
        throw StateError('Keyboard target $selector has no exposed focus node');
      }
      focusNode.requestFocus();
    }
    await tester.pump();
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  Future<void> perform(Map<String, dynamic> action) async {
    final mode = action['mode'] as String?;
    if (mode == 'replace-markdown') {
      _mountId++;
      await mount(
        action['source'] as String? ??
            interactionRows(
                  interactionFixture['cases'],
                ).singleWhere((item) => item['id'] == _caseId)['source']
                as String,
        _caseId,
      );
      return;
    }

    final selector = action['selector'] as String;
    final element = elementForSelector(selector);
    if (mode == 'key') {
      final key = switch (action['key']) {
        'Space' => LogicalKeyboardKey.space,
        'Enter' => LogicalKeyboardKey.enter,
        'ArrowRight' => LogicalKeyboardKey.arrowRight,
        'ArrowLeft' => LogicalKeyboardKey.arrowLeft,
        'ArrowUp' => LogicalKeyboardKey.arrowUp,
        'ArrowDown' => LogicalKeyboardKey.arrowDown,
        _ => throw StateError('Unknown interaction key: ${action['key']}'),
      };
      await pressKeyOn(selector, key);
      return;
    }

    if (element?.localName == 'label') {
      await activateLabel(selector);
      return;
    }
    if (element?.localName == 'summary') {
      await tapSelectorText(selector);
      return;
    }

    if (selector.startsWith('ul li:nth-child(')) {
      final index =
          int.parse(
            RegExp(r'li:nth-child\((\d+)\)').firstMatch(selector)!.group(1)!,
          ) -
          1;
      final tasks = find.byType(NativeTaskCheckbox);
      if (index < 0 || index >= tasks.evaluate().length) {
        throw StateError('No Markdown task checkbox for $selector');
      }
      await tester.ensureVisible(tasks.at(index));
      // Disabled task controls intentionally do not receive pointer events.
      await tester.tap(tasks.at(index), warnIfMissed: false);
      await tester.pumpAndSettle();
      return;
    }

    if (element?.localName == 'input') {
      final control = controlFor(element!);
      final finder = find.byKey(
        ValueKey('native-html-control-${control.widget.control.key}'),
      );
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await tester.pumpAndSettle();
      return;
    }

    throw StateError('Unsupported native interaction target: $selector');
  }

  List<NativeInteractionControl> controlsForId(String id) =>
      controls().where((control) => control.id == id).toList();

  Future<void> captureScreenshot(String phase, String caseId) async {
    final boundary =
        repaintKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null || !boundary.hasSize) {
      throw StateError('No native interaction repaint boundary for $caseId');
    }
    final bytes = await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return data!.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    });
    final path =
        'build/parity/html-interactions-native-$caseId-$width-${brightness.name}-$phase.png';
    File(path).parent.createSync(recursive: true);
    File(path).writeAsBytesSync(bytes!);
    final reference = interactionWebPhase(width, brightness, caseId, phase);
    final summaries = <Map<String, dynamic>>[];
    for (final detail in interactionRows(reference['details'])) {
      final summary = interactionObject(detail['summary']);
      final finder = interactionRichText(summary['text'] as String);
      if (finder.evaluate().isEmpty) continue;
      final native = tester.getRect(finder);
      final web = interactionObject(summary['box']);
      summaries.add({
        'text': summary['text'],
        'nativeTop': native.top,
        'nativeHeight': native.height,
        'webTop': web['y'],
        'webHeight': web['height'],
        'topDelta': native.top - (web['y'] as num),
        'heightDelta': native.height - (web['height'] as num),
      });
    }
    File(path.replaceFirst('.png', '.json')).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({'summaries': summaries}),
    );
  }
}

String _normalText(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

Finder interactionRichText(String text, {bool skipOffstage = true}) =>
    find.byWidgetPredicate(
      (widget) =>
          widget is RichText &&
          _normalText(widget.text.toPlainText()).contains(text),
      skipOffstage: skipOffstage,
    );

Future<void> tapInteractionText(WidgetTester tester, String text) async {
  final matches = interactionRichText(text);
  if (matches.evaluate().isEmpty) {
    throw StateError('No visible RichText contains "$text"');
  }
  final finder = matches.first;
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  final rich = tester.widget<RichText>(finder);
  final render = tester.renderObject<RenderParagraph>(finder);
  final start = rich.text.toPlainText().indexOf(text);
  if (start < 0) {
    throw StateError('Fixture text does not have contiguous glyphs');
  }
  final box = render
      .getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: start + text.length),
      )
      .first
      .toRect();
  await tester.tapAt(render.localToGlobal(box.center));
  await tester.pumpAndSettle();
}

Future<void> runNativeInteractionScenario(
  WidgetTester tester, {
  required Map<String, dynamic> item,
  required int width,
  required Brightness brightness,
  required InteractionPhaseCallback onPhase,
}) async {
  await tester.runAsync(loadParityFonts);
  final session = NativeInteractionSession(tester, width, brightness);
  var source = item['source'] as String;
  await session.mount(source, item['id'] as String);
  await onPhase(session, 'initial');
  for (final action in interactionRows(item['actions'] ?? const [])) {
    await session.perform(action);
    if (action['mode'] == 'replace-markdown') {
      source = action['source'] as String? ?? item['source'] as String;
    }
    final phase = action['id'] as String;
    await onPhase(session, phase);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final width in (interactionFixture['widths'] as List).cast<num>()) {
    for (final brightness in Brightness.values) {
      for (final item in interactionRows(interactionFixture['cases'])) {
        testWidgets('capture ${item['id']} $width ${brightness.name}', (
          tester,
        ) async {
          final semantics = tester.ensureSemantics();
          try {
            await runNativeInteractionScenario(
              tester,
              item: item,
              width: width.toInt(),
              brightness: brightness,
              onPhase: (session, phase) =>
                  session.captureScreenshot(phase, item['id'] as String),
            );
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            semantics.dispose();
            tester.view.reset();
          }
        });
      }
    }
  }
}
