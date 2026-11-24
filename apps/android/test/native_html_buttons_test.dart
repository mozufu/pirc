import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_controls.dart';
import 'package:pirc_render/src/html_select.dart';
import 'package:pirc_render/src/html_range.dart';
import 'native_html_test.dart' show shell, tapText;

void main() {
  testWidgets('reset restores its form, keeps other form and survives rebuild', (
    tester,
  ) async {
    const source =
        '<form><input value="Initial">'
        '<input type="checkbox" checked><input type="radio" name="r" checked>'
        '<input type="radio" name="r"><select><option>First</option>'
        '<option selected>Second</option></select>'
        '<input type="range" min="0" max="10" step="3" value="4" readonly>'
        '<button type="reset"><strong>Reset</strong> this form</button></form>'
        '<form><input value="Other"><input type="checkbox"></form>';
    await tester.pumpWidget(shell(source));
    await tester.pumpAndSettle();
    final edits = find.byType(EditableText);
    await tester.enterText(edits.at(0), 'Changed');
    await tester.enterText(edits.at(1), 'Other changed');
    final widgets = tester
        .widgetList<NativeHtmlControlWidget>(
          find.byType(NativeHtmlControlWidget),
        )
        .toList();
    for (final index in [0, 2, 3]) {
      widgets[index].state.activateControl(widgets[index].control.key);
    }
    final select = tester.widget<NativeHtmlSelectWidget>(
      find.byType(NativeHtmlSelectWidget),
    );
    select.state.select(select.control.key, 0);
    final range = tester.widget<NativeHtmlRangeWidget>(
      find.byType(NativeHtmlRangeWidget),
    );
    expect(range.state.valueFor(range.control.key), '3');
    range.state.setRangeValue(range.control.key, 8);
    expect(range.state.valueFor(range.control.key), '9');
    await tester.pump();
    final button = find.byType(NativeHtmlButtonWidget);
    expect(button, findsOneWidget);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(tester.widget<EditableText>(edits.at(0)).controller.text, 'Initial');
    expect(
      tester.widget<EditableText>(edits.at(1)).controller.text,
      'Other changed',
    );
    expect(widgets[0].state.isChecked(widgets[0].control.key), true);
    expect(widgets[1].state.isChecked(widgets[1].control.key), true);
    expect(widgets[2].state.isChecked(widgets[2].control.key), false);
    expect(widgets[3].state.isChecked(widgets[3].control.key), true);
    expect(select.state.valueFor(select.control.key), 'Second');
    expect(range.state.valueFor(range.control.key), '3');
    await tester.enterText(edits.at(0), 'Second edit');
    await tester.pumpWidget(shell(source));
    await tester.pumpAndSettle();
    expect(
      tester.widget<EditableText>(edits.at(0)).controller.text,
      'Second edit',
    );
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(tester.widget<EditableText>(edits.at(0)).controller.text, 'Initial');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'input reset, disabled fieldset exception and keyboard activation',
    (tester) async {
      const source =
          '<form><input value="Initial"><fieldset disabled>'
          '<legend><input type="reset" value="Legend reset"></legend>'
          '<input type="reset" value="Disabled reset"></fieldset>'
          '<button type="reset">Keyboard reset</button></form>';
      await tester.pumpWidget(shell(source));
      await tester.pumpAndSettle();
      final buttons = find.byType(NativeHtmlButtonWidget);
      final edit = find.byType(EditableText);
      expect(buttons, findsNWidgets(3));
      await tester.enterText(edit, 'Changed');
      await tester.tap(buttons.at(1));
      await tester.pumpAndSettle();
      expect(tester.widget<EditableText>(edit).controller.text, 'Changed');
      await tester.tap(buttons.at(0));
      await tester.pumpAndSettle();
      expect(tester.widget<EditableText>(edit).controller.text, 'Initial');
      final detector = find.descendant(
        of: buttons.at(2),
        matching: find.byType(FocusableActionDetector),
      );
      tester
          .widget<FocusableActionDetector>(detector)
          .focusNode!
          .requestFocus();
      await tester.pump();
      tester.widget<EditableText>(edit).controller.text = 'Keyboard change';
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      expect(
        tester.widget<EditableText>(edit).controller.text,
        'Keyboard change',
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(tester.widget<EditableText>(edit).controller.text, 'Initial');
      tester.widget<EditableText>(edit).controller.text = 'Enter change';
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(tester.widget<EditableText>(edit).controller.text, 'Initial');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('copy keeps rich content and authored box across label changes', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') copied = call.arguments['text'];
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    const source =
        '<div class="code-block"><button type="button" data-copy '
        'style="padding:8px 20px;border:3px solid red;background-color:blue">'
        '<strong>Authored copy</strong></button>'
        '<pre><code>line &lt;one&gt;\nlast\n</code></pre></div>';
    await tester.pumpWidget(shell(source));
    await tester.pumpAndSettle();
    final button = find.byType(NativeHtmlButtonWidget);
    final rich = tester
        .widgetList<RichText>(
          find.descendant(of: button, matching: find.byType(RichText)),
        )
        .toList();
    expect(
      rich.any((w) => w.text.toPlainText().contains('Authored copy')),
      true,
    );
    final height = tester.getSize(button).height;
    final originalWidth = tester.getSize(button).width;
    await tester.tap(button);
    await tester.pump();
    expect(copied, 'line <one>\nlast\n');
    expect(find.text('Copied'), findsOneWidget);
    expect(tester.getSize(button).width, lessThan(originalWidth));
    expect(tester.getSize(button).height, height);
    await tester.pump(const Duration(milliseconds: 1400));
    expect(find.text('Copy'), findsOneWidget);
    expect(tester.getSize(button).height, height);
    await tester.tap(button);
    await tester.pump();
    await tester.pumpWidget(shell('<p>Replacement document</p>'));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Copy'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('top-level copy hit target follows the painted box', (
    tester,
  ) async {
    final writes = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          writes.add(call.arguments['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final original =
        shell(
              '<button type="button" data-copy><strong>Missing code</strong></button><form><input value="Initial"></form>',
            )
            as MaterialApp;
    await tester.pumpWidget(
      MaterialApp(
        theme: original.theme,
        home: Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [(original.home! as Scaffold).body!],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final button = find.byType(NativeHtmlButtonWidget);
    final before = tester.getRect(button);
    expect(before.width, lessThan(400));
    await tester.tapAt(Offset(before.right + 25, before.center.dy));
    await tester.pump();
    expect(writes, isEmpty);
    await tester.tap(button);
    await tester.pump();
    expect(writes, ['']);
    expect(tester.getRect(button).width, lessThan(before.width));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test('reset default occurs even when clipboard is rejected', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final binding = TestDefaultBinaryMessengerBinding.instance;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (_) async => throw PlatformException(code: 'denied'),
    );
    addTearDown(
      () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    const source =
        '<form><input id="a" value="Initial">'
        '<button type="reset" data-copy>Reset and copy</button></form>';
    var resets = 0;
    final state = NativeHtmlButtonState.fromHtml(
      source,
      onReset: (elements) {
        resets++;
        expect(elements.single.attributes['id'], 'a');
      },
    );
    final button = state.resolveControl(
      html.parseFragment(state.annotateHtml(source)).querySelector('button')!,
    )!;
    expect(await state.activate(button.key), false);
    expect(resets, 1);
    state.dispose();
  });
  testWidgets(
    'associated label resets and first labelable child blocks fallback',
    (tester) async {
      const source =
          '<form><input value="Initial"><label for="form-reset-control">Reset label</label>'
          '<button id="form-reset-control" type="reset">Reset content</button>'
          '<label><input type="text" value="Label target"><button type="reset">'
          'Later reset</button></label></form>';
      await tester.pumpWidget(shell(source));
      await tester.pumpAndSettle();
      final edits = find.byType(EditableText);
      await tester.enterText(edits.first, 'Changed');
      await tapText(tester, 'Reset label');
      expect(
        tester.widget<EditableText>(edits.first).controller.text,
        'Initial',
      );
      final button = tester.widget<NativeHtmlButtonWidget>(
        find.byType(NativeHtmlButtonWidget).first,
      );
      expect(button.button.label, 'Reset label');
      expect(button.state.focusNodeFor(button.button.key).hasFocus, true);
      await tester.enterText(edits.first, 'Second edit');
      final later = tester.widget<NativeHtmlButtonWidget>(
        find.byType(NativeHtmlButtonWidget).last,
      );
      expect(later.button.contentName, true);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Space release after focus loss does not reset a form', (
    tester,
  ) async {
    const source =
        '<form><input value="Initial"><button type="reset">Reset</button></form>';
    await tester.pumpWidget(shell(source));
    await tester.pumpAndSettle();
    final button = tester.widget<NativeHtmlButtonWidget>(
      find.byType(NativeHtmlButtonWidget),
    );
    button.state.focusNodeFor(button.button.key).requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    final edit = tester.widget<EditableText>(find.byType(EditableText));
    edit.controller.text = 'Changed';
    edit.focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(edit.controller.text, 'Changed');
    expect(tester.takeException(), isNull);
  });
  for (final scale in [1.0, 2.0]) {
    testWidgets('fieldset legend keeps checkbox/range control layout at $scale', (
      tester,
    ) async {
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: shell(
            '<fieldset disabled><legend><label for="legend-check">Legend checkbox</label>'
            '<input id="legend-check" type="checkbox"><input type="range" min="0" max="10" value="5"></legend>'
            '<input type="checkbox"><legend>Later <input type="checkbox"></legend></fieldset>',
          ),
        ),
      );
      await tester.pumpAndSettle();
      final checks = tester
          .widgetList<NativeHtmlControlWidget>(
            find.byType(NativeHtmlControlWidget),
          )
          .toList();
      expect(checks.map((w) => w.control.disabled), [false, true, true]);
      await tapText(tester, 'Legend checkbox');
      expect(checks.first.state.isChecked(checks.first.control.key), true);
      final range = tester.widget<NativeHtmlRangeWidget>(
        find.byType(NativeHtmlRangeWidget),
      );
      expect(range.control.disabled, false);
      range.state.focusNodeFor(range.control.key).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(range.state.valueFor(range.control.key), '6');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('code header shrinks both children at large text without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') copied = call.arguments['text'];
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: shell(
          '<div class="code-block"><div class="code-head"><span>typescript-long-title</span>'
          '<button type="button" class="code-copy" data-copy>Copy a longer title</button>'
          '</div><pre><code>line</code></pre></div>',
        ),
      ),
    );
    await tester.pumpAndSettle();
    final button = find.byType(NativeHtmlButtonWidget);
    expect(button, findsOneWidget);
    expect(MediaQuery.textScalerOf(tester.element(button)).scale(12), 24);
    expect(tester.getRect(button).right, lessThanOrEqualTo(374));
    await tester.tap(button);
    await tester.pump();
    expect(copied, 'line');
    expect(find.text('Copied'), findsOneWidget);
    expect(tester.getRect(button).right, lessThanOrEqualTo(374));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
