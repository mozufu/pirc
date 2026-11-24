import 'dart:convert';
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderBox, RenderParagraph, Selectable;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_math_fork/flutter_math.dart' show Math;
import 'package:pirc_render/src/native_markdown.dart';
import 'live_test.dart' show theme;
import '../tool/parity/capture_fonts.dart' show loadParityFonts;

void main() {
  String? copied;
  String? observedSelection;
  setUp(() {
    copied = null;
    observedSelection = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );

  Future<void> show(WidgetTester t, String source) async {
    await t.runAsync(loadParityFonts);
    t.view.physicalSize = const Size(390, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: theme.build(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            gestureSettings: const DeviceGestureSettings(touchSlop: 0),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: SelectableRegion(
              selectionControls: materialTextSelectionHandleControls,
              contextMenuBuilder: (context, state) =>
                  AdaptiveTextSelectionToolbar.selectableRegion(
                    selectableRegionState: state,
                  ),
              onSelectionChanged: (content) =>
                  observedSelection = content?.plainText,
              child: NativeMarkdown(
                source: source,
                fontSize: 15,
                lineHeight: 1.65,
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  Future<void> copy(WidgetTester t, {bool all = true}) async {
    final region = t.state<SelectableRegionState>(
      find.byType(SelectableRegion),
    );
    if (all) region.selectAll(SelectionChangedCause.keyboard);
    await t.pump();
    region.contextMenuButtonItems
        .firstWhere((item) => item.type == ContextMenuButtonType.copy)
        .onPressed!();
    await t.pump();
  }

  String? selectionDirection(SelectableRegionState region) {
    final overlay = region.selectionOverlay!;
    if (overlay.startHandleType == TextSelectionHandleType.left &&
        overlay.endHandleType == TextSelectionHandleType.right) {
      return 'forward';
    }
    if (overlay.startHandleType == TextSelectionHandleType.right &&
        overlay.endHandleType == TextSelectionHandleType.left) {
      return 'reverse';
    }
    return null;
  }

  Future<void> moveSelectionHandle(
    WidgetTester t,
    SelectableRegionState region, {
    required bool start,
    required Offset target,
  }) async {
    final overlay = region.selectionOverlay!;
    final expectedLayerLink = start
        ? overlay.startHandleLayerLink
        : overlay.endHandleLayerLink;
    final handleFinder = find.byWidgetPredicate((widget) {
      if (widget.runtimeType.toString() != '_SelectionHandleOverlay') {
        return false;
      }
      final dynamic handle = widget;
      return identical(handle.handleLayerLink, expectedLayerLink);
    });
    expect(handleFinder, findsOneWidget);
    final gestureFinder = find.descendant(
      of: handleFinder,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is RawGestureDetector &&
            widget.gestures.containsKey(PanGestureRecognizer),
      ),
    );
    expect(gestureFinder, findsOneWidget);
    final handle = t.getRect(gestureFinder);
    final otherLink = start
        ? overlay.endHandleLayerLink
        : overlay.startHandleLayerLink;
    final otherFinder = find.byWidgetPredicate(
      (widget) =>
          widget.runtimeType.toString() == '_SelectionHandleOverlay' &&
          identical((widget as dynamic).handleLayerLink, otherLink),
    );
    final otherGesture = find.descendant(
      of: otherFinder,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is RawGestureDetector &&
            widget.gestures.containsKey(PanGestureRecognizer),
      ),
    );
    final otherHandle = t.getRect(otherGesture);
    final hitPoints = [
      handle.center,
      Offset(handle.left + 1, handle.center.dy),
      Offset(handle.right - 1, handle.center.dy),
      Offset(handle.center.dx, handle.top + 1),
      Offset(handle.center.dx, handle.bottom - 1),
    ];
    final hitPoint = hitPoints.firstWhere(
      (point) => !otherHandle.contains(point),
    );
    final rootContainerFinder = find
        .descendant(
          of: find.byType(SelectableRegion),
          matching: find.byType(SelectionContainer),
        )
        .first;
    final container = t.widget<SelectionContainer>(rootContainerFinder);
    final selectable = t.state(rootContainerFinder) as Selectable;
    final geometry = container.delegate!.value;
    final point = start
        ? geometry.startSelectionPoint!
        : geometry.endSelectionPoint!;
    final currentEndpoint = MatrixUtils.transformPoint(
      selectable.getTransformTo(null),
      point.localPosition,
    );
    final targetHandlePosition =
        target +
        Offset(
          0,
          (start ? region.startGlyphHeight : region.endGlyphHeight) / 2,
        );
    final gesture = await t.startGesture(
      hitPoint,
      kind: PointerDeviceKind.touch,
    );
    final delta = targetHandlePosition - currentEndpoint;
    // Start the accepted pan separately from the requested caret movement.
    // These tests validate selection routing; physical platform drag slop is
    // covered by the outstanding Android touch acceptance gate.
    await gesture.moveBy(const Offset(.1, 0));
    await t.pump();
    await gesture.moveBy(delta);
    await gesture.up();
    await t.pumpAndSettle();
  }

  for (final (source, visible) in [
    (r'Prefix $a+b$ suffix.', 'Prefix \na\n+\nb\na+b suffix.'),
    (r'Prefix $x+\pircmissing+y$ suffix.', r'Prefix x+\pircmissing+y suffix.'),
    (r'Prefix $x+{y$ suffix.', r'Prefix x+{y suffix.'),
  ]) {
    testWidgets('copy actual glyphs in $source', (t) async {
      await show(t, source);
      await copy(t);
      expect(copied, visible);
      expect(t.takeException(), isNull);
    });
  }
  testWidgets('selectable AST preserves nested fraction rendering', (t) async {
    await show(t, r'Prefix $\dfrac{\dfrac{a+b}{c+d}}{e+f}$ suffix.');
    final rendered = t.widget<Math>(find.byType(Math).first);
    expect(rendered.parseError, isNull);
    expect(rendered.ast, isNotNull);
    expect(t.takeException(), isNull);
  });
  testWidgets('mouse drag selects Math glyphs without surrounding prose', (
    t,
  ) async {
    await show(t, r'Before $a+b$ after.');
    Finder glyph(String symbol) => find.byWidgetPredicate(
      (w) =>
          w is RichText &&
          w.text.toPlainText() == symbol &&
          (w.text.style?.fontFamily?.contains('KaTeX') ?? false),
    );
    final a = t.getRect(glyph('a').first), b = t.getRect(glyph('b').first);
    final gesture = await t.startGesture(
      Offset(a.left + .5, a.center.dy),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(Offset(b.right - .5, b.center.dy));
    await gesture.up();
    await t.pump();
    await copy(t, all: false);
    expect(copied, 'a+b');
    expect(t.takeException(), isNull);
  });

  testWidgets('fresh reverse drag selects Math glyphs', (t) async {
    await show(t, r'Before $a+b$ after.');
    Finder glyph(String text) => find.byWidgetPredicate(
      (w) =>
          w is RichText &&
          w.text.toPlainText() == text &&
          (w.text.style?.fontFamily?.contains('KaTeX') ?? false),
    );
    final a = t.getRect(glyph('a').first), b = t.getRect(glyph('b').first);
    final gesture = await t.startGesture(
      Offset(b.right - .5, b.center.dy),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(Offset(a.left + .5, a.center.dy));
    await gesture.up();
    await t.pump();
    await copy(t, all: false);
    expect(copied, 'a+b');
    expect(t.takeException(), isNull);
  });

  testWidgets('select-all then moving a handle uses the new edge only', (
    t,
  ) async {
    await show(t, r'Before $a+b$ after.');
    final region = t.state<SelectableRegionState>(
      find.byType(SelectableRegion),
    );
    region.selectAll(SelectionChangedCause.toolbar);
    await t.pump();
    final regionRender = region.context.findRenderObject()! as RenderBox;
    final target = regionRender.localToGlobal(
      region.selectionOverlay!.selectionEndpoints.last.point -
          const Offset(10, 0),
    );
    await moveSelectionHandle(t, region, start: true, target: target);
    await copy(t, all: false);
    expect(copied, isNotEmpty);
    expect(copied, isNot('Before a+b after.'));
    expect(t.takeException(), isNull);
  });

  testWidgets('overlay handles cross forward to reverse and back in prose', (
    t,
  ) async {
    const source = 'one two three four.';
    await show(t, source);
    final region = t.state<SelectableRegionState>(
      find.byType(SelectableRegion),
    );
    final paragraph = t.renderObject<RenderParagraph>(
      find.byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText() == source,
      ),
    );
    Offset caret(int offset) => paragraph.localToGlobal(
      paragraph.getOffsetForCaret(TextPosition(offset: offset), Rect.zero) +
          Offset(0, paragraph.size.height / 2),
    );

    region.selectAll(SelectionChangedCause.toolbar);
    await t.pumpAndSettle();
    await moveSelectionHandle(t, region, start: true, target: caret(3));
    await moveSelectionHandle(t, region, start: false, target: caret(12));
    expect(selectionDirection(region), 'forward');

    await moveSelectionHandle(t, region, start: true, target: caret(16));
    expect(selectionDirection(region), 'reverse');

    await moveSelectionHandle(t, region, start: false, target: caret(17));
    expect(selectionDirection(region), 'forward');
    await copy(t, all: false);
    expect(copied, 'u');
    expect(t.takeException(), isNull);
  });

  testWidgets('overlay handles cross both directions over inline Math', (
    t,
  ) async {
    await show(t, r'Before $a+b$ after.');
    final region = t.state<SelectableRegionState>(
      find.byType(SelectableRegion),
    );
    Finder glyph(String text) => find.byWidgetPredicate(
      (w) =>
          w is RichText &&
          w.text.toPlainText() == text &&
          (w.text.style?.fontFamily?.contains('KaTeX') ?? false),
    );
    final a = t.getRect(glyph('a').first);
    final b = t.getRect(glyph('b').first);
    final paragraphWidget = t
        .widgetList<RichText>(find.byWidgetPredicate((w) => w is RichText))
        .firstWhere(
          (w) => w.text
              .toPlainText(includeSemanticsLabels: false)
              .contains(' after.'),
        );
    final paragraph = t.renderObject<RenderParagraph>(
      find.byWidget(paragraphWidget),
    );
    final plainText = paragraph.text.toPlainText(includeSemanticsLabels: false);
    final afterStart = plainText.indexOf(' after.');
    Offset paragraphCaret(int offset) => paragraph.localToGlobal(
      paragraph.getOffsetForCaret(TextPosition(offset: offset), Rect.zero) +
          Offset(0, paragraph.size.height / 2),
    );
    region.selectAll(SelectionChangedCause.toolbar);
    await t.pumpAndSettle();
    await moveSelectionHandle(
      t,
      region,
      start: true,
      target: Offset(a.left + .5, a.center.dy),
    );
    await moveSelectionHandle(
      t,
      region,
      start: false,
      target: Offset(b.right - .5, b.center.dy),
    );
    expect(selectionDirection(region), 'forward');

    await moveSelectionHandle(
      t,
      region,
      start: true,
      target: paragraphCaret(afterStart + 4),
    );
    expect(selectionDirection(region), 'reverse');
    expect(
      region.selectionOverlay!.selectionEndpoints.first.point,
      isNot(region.selectionOverlay!.selectionEndpoints.last.point),
    );
    expect(observedSelection, isNotEmpty);
    await moveSelectionHandle(
      t,
      region,
      start: false,
      target: paragraphCaret(afterStart + 5),
    );
    expect(selectionDirection(region), 'forward');
    final selectedBeforeCopy = observedSelection;
    expect(selectedBeforeCopy, isNotEmpty);
    await copy(t, all: false);
    expect(copied, selectedBeforeCopy);
    expect(copied, isNot('a+b'));
    expect(t.takeException(), isNull);
  });

  const scriptedFraction =
      r'Tall inline math $x^{\frac{a+b}{c+d}}_{i_0}$ sits between before and after text.';

  testWidgets('fraction and script whole-copy matches actual Chrome', (
    t,
  ) async {
    await show(t, scriptedFraction);
    await copy(t);
    final oracle =
        jsonDecode(
              File(
                '../../fixtures/mobile-parity/inline-math-clipboard-expected.json',
              ).readAsStringSync(),
            )
            as Map;
    final config = (oracle['configurations'] as List).singleWhere(
      (row) => row['id'] == '390-light-1',
    );
    final expected = (config['cases'] as List).singleWhere(
      (row) => row['id'] == 'inline-tall-fraction-scripts',
    );
    // Compare the real clipboard observation, including both branches. Partial
    // script selection retains its independently tested glyph/MathML ordering.
    expect(copied, expected['actualClipboard']['textPlain']);
    expect(t.takeException(), isNull);
  });

  testWidgets('script groups retain real partial glyph selection', (t) async {
    Finder glyph(String text) => find.byWidgetPredicate(
      (w) =>
          w is RichText &&
          w.text.toPlainText() == text &&
          (w.text.style?.fontFamily?.contains('KaTeX') ?? false),
    );

    Future<void> dragAndCopy(
      String startText,
      String endText,
      bool reverse,
    ) async {
      await show(t, scriptedFraction);
      final startRect = t.getRect(glyph(startText).first);
      final endRect = t.getRect(glyph(endText).first);
      final from = Offset(startRect.left + .5, startRect.center.dy);
      final to = Offset(endRect.right - .5, endRect.center.dy);
      final gesture = await t.startGesture(
        reverse ? to : from,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(reverse ? from : to);
      await gesture.up();
      await t.pump();
      await copy(t, all: false);
    }

    await dragAndCopy('a', 'b', true);
    expect(copied, 'a+b');
    copied = null;
    await dragAndCopy('a', 'b', false);
    expect(copied, 'a+b');
    copied = null;
    await dragAndCopy('i', '0', false);
    expect(copied, 'i0');
    copied = null;
    await dragAndCopy('i', '0', true);
    expect(copied, 'i0');
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'overlay handles cross both directions within a script fraction',
    (t) async {
      await show(t, r'Math $x^{\frac{a+b}{c+d}}_{i_0}$ z.');
      final region = t.state<SelectableRegionState>(
        find.byType(SelectableRegion),
      );
      Finder glyph(String text) => find.byWidgetPredicate(
        (w) =>
            w is RichText &&
            w.text.toPlainText() == text &&
            (w.text.style?.fontFamily?.contains('KaTeX') ?? false),
      );
      final numeratorStart = t.getRect(glyph('a').first);
      final numeratorEnd = t.getRect(glyph('b').first);
      final denominatorEnd = t.getRect(glyph('d').first);

      region.selectAll(SelectionChangedCause.toolbar);
      await t.pumpAndSettle();
      await moveSelectionHandle(
        t,
        region,
        start: true,
        target: Offset(numeratorStart.left + .5, numeratorStart.center.dy),
      );
      await moveSelectionHandle(
        t,
        region,
        start: false,
        target: Offset(numeratorEnd.right - .5, numeratorEnd.center.dy),
      );
      expect(selectionDirection(region), 'forward');
      expect(observedSelection, 'a+b');

      await moveSelectionHandle(
        t,
        region,
        start: true,
        target: denominatorEnd.center,
      );
      expect(selectionDirection(region), 'reverse');
      expect(
        region.selectionOverlay!.selectionEndpoints.first.point,
        isNot(region.selectionOverlay!.selectionEndpoints.last.point),
      );
      expect(observedSelection, isNotEmpty);

      // Moving the original start back before the untouched focus restores the
      // forward range. Copy must match the real selected glyph fragments.
      await moveSelectionHandle(
        t,
        region,
        start: true,
        target: Offset(numeratorStart.left + .5, numeratorStart.center.dy),
      );
      expect(selectionDirection(region), 'forward');
      expect(
        region.selectionOverlay!.selectionEndpoints.first.point,
        isNot(region.selectionOverlay!.selectionEndpoints.last.point),
      );
      expect(observedSelection, 'a+b');
      final selectedBeforeCopy = observedSelection;
      await copy(t, all: false);
      expect(copied, selectedBeforeCopy);
      expect(copied, 'a+b');
      expect(t.takeException(), isNull);
    },
  );
}
