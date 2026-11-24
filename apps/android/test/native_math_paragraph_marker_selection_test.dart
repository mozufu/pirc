import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_math_fork/flutter_math.dart'
    show MathStyle, TexParserSettings;
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_render/src/native_math_paragraph.dart';
import 'package:pirc_render/src/native_tex_adapter.dart';

import 'live_test.dart' show theme;

void main() {
  String? copied;

  setUp(() {
    copied = null;
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

  testWidgets('layout marker uses source body style and scales once', (
    tester,
  ) async {
    const bodyStyle = TextStyle(
      fontSize: 28,
      height: 1.35,
      fontWeight: FontWeight.w600,
      color: Colors.purple,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: SizedBox(
            width: 500,
            child: NativeMathParagraph(
              children: [
                NativeMarkdownMath(
                  math: NativeMathTex(
                    'x+y',
                    mathStyle: MathStyle.text,
                    textStyle: bodyStyle.copyWith(fontSize: 30.24),
                    settings: const TexParserSettings(throwOnError: false),
                  ),
                  bodyFontSize: 28,
                  lineHeight: 1.65,
                  display: false,
                  bodyStyle: bodyStyle,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final content = tester.widget<NativeMathParagraphContent>(
      find.byType(NativeMathParagraphContent),
    );
    final paragraph = tester.widget<RichText>(find.byWidget(content.child));
    final marker = (paragraph.text as TextSpan).children!
        .whereType<TextSpan>()
        .firstWhere((span) => span.text == '\u200b');
    expect(marker.style?.fontSize, 56);
    expect(marker.style?.height, 1.35);
    expect(marker.style?.fontWeight, FontWeight.w600);
    expect(marker.style?.color, Colors.purple);
    expect(tester.takeException(), isNull);
  });

  Future<void> show(WidgetTester tester, String source) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme.build(Brightness.light),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: NativeMarkdown(
              source: source,
              fontSize: 15,
              lineHeight: 1.65,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> copy(WidgetTester tester, {required bool all}) async {
    final region = tester.state<SelectableRegionState>(
      find.byType(SelectableRegion),
    );
    if (all) region.selectAll(SelectionChangedCause.keyboard);
    await tester.pump();
    region.contextMenuButtonItems
        .firstWhere((item) => item.type == ContextMenuButtonType.copy)
        .onPressed!();
    await tester.pump();
  }

  testWidgets('filters only synthetic paragraph markers from copy', (
    tester,
  ) async {
    const source = 'Before\u200b \$x+\\pircmissing+y\$ after\u200b.';
    await show(tester, source);
    await copy(tester, all: true);

    expect(copied, 'Before\u200b x+\\pircmissing+y after\u200b.');
    expect(
      copied!.split('\u200b').length - 1,
      2,
      reason:
          'the two U+200B characters came from source text and must survive',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('partial math selection forwards through the marker proxy', (
    tester,
  ) async {
    await show(tester, r'Before $a+b$ after.');
    Finder glyph(String text) => find.byWidgetPredicate(
      (widget) =>
          widget is RichText &&
          widget.text.toPlainText() == text &&
          (widget.text.style?.fontFamily?.contains('KaTeX') ?? false),
    );

    final a = tester.getRect(glyph('a').first);
    final b = tester.getRect(glyph('b').first);
    final gesture = await tester.startGesture(
      Offset(a.left + .5, a.center.dy),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(Offset(b.right - .5, b.center.dy));
    await gesture.up();
    await tester.pump();
    await copy(tester, all: false);

    expect(copied, 'a+b');
    expect(tester.takeException(), isNull);
  });
}
