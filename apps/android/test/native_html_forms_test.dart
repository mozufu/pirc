import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_form_feedback.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_render/src/html_form_validation.dart';
import 'package:pirc_render/src/html_forms.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'live_test.dart' show theme;

Widget page(
  String source,
  List<NativeHtmlFormSubmission> sent, {
  Brightness brightness = Brightness.light,
  double scale = 1,
  ValueChanged<NativeHtmlFormSubmission>? onSubmission,
}) => MaterialApp(
  theme: theme.build(brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: NativeMarkdown(
        source: source,
        onFormSubmit: (s) {
          onSubmission?.call(s);
          sent.add(s);
        },
      ),
    ),
  ),
);
NativeHtmlForms forms(WidgetTester t) =>
    t.widget<NativeHtmlFormFeedback>(find.byType(NativeHtmlFormFeedback)).forms;
Future<void> submit(WidgetTester t) async {
  final button = find.byType(NativeHtmlButtonWidget).first;
  await t.ensureVisible(button);
  await t.tap(button);
  await t.pumpAndSettle();
}

List<List<String>> entries(NativeHtmlFormSubmission s) => [
  for (final e in s.entries) [e.name, e.value],
];

void main() {
  testWidgets(
    'submit validates live fields and focuses first invalid without changing values',
    (t) async {
      final sent = <NativeHtmlFormSubmission>[];
      await t.pumpWidget(
        page(
          '<form action="/collect"><input id="a" name="a" required><input id="b" name="b" required><button name="go" value="yes">Send</button></form>',
          sent,
        ),
      );
      await t.pumpAndSettle();
      final edits = find.byType(EditableText);
      await submit(t);
      expect(sent, isEmpty);
      expect(t.widget<EditableText>(edits.at(0)).focusNode.hasFocus, isTrue);
      expect(
        find.byKey(const ValueKey('native-html-validation-message')),
        findsOneWidget,
      );
      expect(
        forms(t).validityForId('a')!.has(HtmlValidityFlag.valueMissing),
        isTrue,
      );
      await t.enterText(edits.at(0), 'one');
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('native-html-validation-message')),
        findsNothing,
      );
      await submit(t);
      expect(t.widget<EditableText>(edits.at(1)).focusNode.hasFocus, isTrue);
      await t.enterText(edits.at(1), 'two');
      await submit(t);
      expect(sent, hasLength(1));
      expect(entries(sent.single), [
        ['a', 'one'],
        ['b', 'two'],
        ['go', 'yes'],
      ]);
      expect(sent.single.buildRequest().url, '/collect?a=one&b=two&go=yes');
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'minlength depends on a real edit and resets clear that provenance',
    (t) async {
      final sent = <NativeHtmlFormSubmission>[];
      await t.pumpWidget(
        page(
          '<form><input id="short" name="x" minlength="3" value="a"><button>Send</button><button type="reset">Reset</button></form>',
          sent,
        ),
      );
      await t.pumpAndSettle();
      await submit(t);
      expect(sent, hasLength(1));
      await t.enterText(find.byType(EditableText), 'b');
      await submit(t);
      expect(sent, hasLength(1));
      expect(
        forms(t).validityForId('short')!.has(HtmlValidityFlag.tooShort),
        isTrue,
      );
      await t.tap(find.byType(NativeHtmlButtonWidget).last);
      await t.pumpAndSettle();
      expect(
        forms(t).validityForId('short')!.has(HtmlValidityFlag.tooShort),
        isFalse,
      );
      await submit(t);
      expect(sent, hasLength(2));
      expect(entries(sent.last), [
        ['x', 'a'],
      ]);
    },
  );

  testWidgets(
    'successful controls preserve tree order, duplicates and submitter position',
    (t) async {
      final sent = <NativeHtmlFormSubmission>[];
      const source =
          '<form action="/go?old=1#frag"><input name="first" value="one"><button name="go" value="yes">Send</button><input type="hidden" name="secret" value="h"><input name="readonly" readonly value="r"><input disabled name="disabled" value="d"><input type="checkbox" name="c" checked><input type="checkbox" name="c" checked value="two"><input type="checkbox" name="c" value="unchecked"><select name="s" multiple><option selected value="a">A</option><option selected disabled value="b">B</option><option selected value="c">C</option></select><textarea name="text">one\ntwo</textarea></form>';
      await t.pumpWidget(page(source, sent));
      await t.pumpAndSettle();
      await submit(t);
      expect(sent, hasLength(1));
      expect(entries(sent.single), [
        ['first', 'one'],
        ['go', 'yes'],
        ['secret', 'h'],
        ['readonly', 'r'],
        ['c', 'on'],
        ['c', 'two'],
        ['s', 'a'],
        ['s', 'c'],
        ['text', 'one\ntwo'],
      ]);
      expect(
        sent.single.buildRequest().url,
        '/go?first=one&go=yes&secret=h&readonly=r&c=on&c=two&s=a&s=c&text=one%0D%0Atwo#frag',
      );
    },
  );

  testWidgets(
    'hardware and software Enter submit once, while textarea and composition do not',
    (t) async {
      final sent = <NativeHtmlFormSubmission>[];
      await t.pumpWidget(
        page(
          '<form><input name="x" value="one"><textarea>two</textarea><button>Send</button></form>',
          sent,
        ),
      );
      await t.pumpAndSettle();
      final edit = find.byType(EditableText).first;
      await t.tap(edit);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(sent, hasLength(1));
      await t.showKeyboard(edit);
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      expect(sent, hasLength(2));
      expect(t.widget<EditableText>(edit).focusNode.hasFocus, isTrue);
      final editable = t.widget<EditableText>(edit);
      editable.controller.value = const TextEditingValue(
        text: 'one',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 0, end: 3),
      );
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(sent, hasLength(2));
      await t.tap(find.byType(EditableText).last);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(sent, hasLength(2));
    },
  );

  testWidgets(
    'implicit submission handles no button and blocks a disabled default button',
    (t) async {
      final sent = <NativeHtmlFormSubmission>[];
      for (final source in [
        '<form><input name="x" value="one"></form>',
        '<form><input value="one"><input value="two"></form>',
        '<form><input value="one"><button disabled>Disabled</button><button>Enabled</button></form>',
      ]) {
        await t.pumpWidget(page(source, sent));
        await t.pumpAndSettle();
        await t.tap(find.byType(EditableText).first);
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await t.pumpAndSettle();
        expect(sent, hasLength(1));
      }
    },
  );

  testWidgets(
    'incomplete number edits are badInput; unsupported form encoding does not send',
    (t) async {
      final sent = <NativeHtmlFormSubmission>[];
      await t.pumpWidget(
        page(
          '<form><input id="n" name="n" type="number" required><button>Send</button></form>',
          sent,
        ),
      );
      await t.pumpAndSettle();
      await t.enterText(find.byType(EditableText), '-');
      await submit(t);
      expect(sent, isEmpty);
      expect(
        forms(t).validityForId('n')!.has(HtmlValidityFlag.badInput),
        isTrue,
      );
      expect(forms(t).message, 'Please enter a number.');
      await t.pumpWidget(
        page(
          '<form method="post" enctype="multipart/form-data"><input name="x" value="one"><button>Send</button></form>',
          sent,
        ),
      );
      await t.pumpAndSettle();
      await submit(t);
      expect(sent, hasLength(1));
      expect(sent.single.buildRequest().bodyBytes, isNotEmpty);
      expect(forms(t).message, isNull);
    },
  );

  testWidgets(
    'live native constraint state matches initial Chromium oracle without imported browser provenance',
    (t) async {
      final fixture =
          jsonDecode(
                File(
                  '../../fixtures/mobile-parity/html-form-validation.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final expected =
          jsonDecode(
                File(
                  '../../fixtures/mobile-parity/html-form-validation-expected.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      await t.pumpWidget(page(fixture['source'] as String, []));
      await t.pumpAndSettle();
      for (final raw in (expected['initial'] as Map)['fields'] as List) {
        final field = raw as Map;
        final result = forms(t).validityForId(field['id'] as String)!;
        if (!result.supported) {
          expect(
            field['id'],
            anyOf(
              'pattern-v-intersection',
              'pattern-v-subtraction',
              'pattern-v-trailing-hyphen',
            ),
          );
          continue;
        }
        final validity = field['validity'] as Map;
        expect(
          result.willValidate,
          field['willValidate'],
          reason: '${field['id']} willValidate',
        );
        for (final flag in HtmlValidityFlag.values) {
          expect(
            result.has(flag),
            validity[flag.name],
            reason: '${field['id']} ${flag.name}',
          );
        }
      }
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'validation popup escapes and source replacement clean up safely',
    (t) async {
      final sent = <NativeHtmlFormSubmission>[];
      await t.pumpWidget(
        page('<form><input required><button>Send</button></form>', sent),
      );
      await t.pumpAndSettle();
      await submit(t);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(forms(t).message, isNull);
      await submit(t);
      await t.pumpWidget(page('<p>Replacement</p>', sent));
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('native-html-validation-message')),
        findsNothing,
      );
      expect(t.takeException(), isNull);
    },
  );
  for (final width in [390.0, 650.0, 651.0, 768.0, 860.0, 861.0, 1024.0]) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'validation feedback remains readable at $width $brightness scale $scale',
          (t) async {
            t.view.devicePixelRatio = 1;
            t.view.physicalSize = Size(width, 844);
            addTearDown(t.view.resetPhysicalSize);
            addTearDown(t.view.resetDevicePixelRatio);
            await t.pumpWidget(
              page(
                '<form><div style="height:900px"></div><input name="x" required><button>Send</button></form>',
                [],
                brightness: brightness,
                scale: scale,
              ),
            );
            await t.pumpAndSettle();
            await submit(t);
            final message = find.byKey(
              const ValueKey('native-html-validation-message'),
            );
            expect(message, findsOneWidget);
            final rect = t.getRect(message);
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(width));
            expect(rect.top, greaterThanOrEqualTo(0));
            expect(rect.bottom, lessThanOrEqualTo(844));
            final anchor = t.getRect(find.byKey(forms(t).activeAnchor));
            final popup = t.getRect(
              find
                  .ancestor(of: message, matching: find.byType(DecoratedBox))
                  .first,
            );
            expect(
              Scrollable.of(
                forms(t).activeAnchor.currentContext!,
              ).position.pixels,
              greaterThan(0),
              reason: 'the styled empty spacer must cause a real reveal scroll',
            );
            final fitsBelow = anchor.bottom + 6 + popup.height <= 844 - 12;
            expect(
              fitsBelow ? popup.top : popup.bottom,
              closeTo(fitsBelow ? anchor.bottom + 6 : anchor.top - 6, .01),
            );
            expect(
              t
                  .widget<EditableText>(find.byType(EditableText))
                  .focusNode
                  .hasFocus,
              isTrue,
            );
            expect(t.takeException(), isNull);
          },
        );
      }
    }
  }
  testWidgets(
    'forged enctype, formenctype and method attributes never leave the standard encodings',
    (t) async {
      const standardTypes = {
        'application/x-www-form-urlencoded',
        'text/plain',
        'multipart/form-data',
      };
      final variants = <String>[
        '<form method="post" enctype="application/json" action="/api/x"><input name="a" value="1"><button>Send</button></form>',
        '<form method="POST" enctype="ApPlIcAtIoN/JsOn" action="/api/x"><input name="a" value="1"><button>Send</button></form>',
        '<form method="post" action="/api/x"><input name="a" value="1"><button formenctype="application/json">Send</button></form>',
        '<form method="get" action="/api/x"><input name="a" value="1"><button formmethod="put" formenctype="application/json">Send</button></form>',
        '<form method="delete" action="/api/x"><input name="a" value="1"><button>Send</button></form>',
        '<form method="patch" enctype="text/html" action="/api/x"><input name="a" value="1"><button>Send</button></form>',
        '<form method="post" enctype="x" action="/api/x"><input name="a" value="1"><button>Send</button></form>',
      ];
      for (final source in variants) {
        final sent = <NativeHtmlFormSubmission>[];
        await t.pumpWidget(page(source, sent));
        await t.pumpAndSettle();
        await submit(t);
        expect(sent, hasLength(1), reason: source);
        final request = sent.single.buildRequest();
        expect(['GET', 'POST'], contains(request.method), reason: source);
        if (request.method == 'POST') {
          expect(
            standardTypes,
            contains(request.contentType!.split(';').first),
            reason: source,
          );
        } else {
          expect(request.contentType, isNull, reason: source);
        }
        await t.pumpWidget(const SizedBox());
      }
    },
  );
}
