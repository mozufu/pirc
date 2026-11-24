import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' as md;
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_date.dart';
import 'package:pirc_render/src/html_form_feedback.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_render/src/html_form_validation.dart';
import 'package:pirc_render/src/html_forms.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';
import 'live_test.dart' show theme;

Widget _page(
  String source, {
  NativeHtmlHistoryController? history,
  ValueChanged<NativeHtmlFormSubmission>? onSubmit,
}) => MaterialApp(
  theme: theme.build(Brightness.light),
  home: Scaffold(
    body: SingleChildScrollView(
      child: NativeHtmlDocument(
        nodes: [NativeHtmlRaw(source)],
        style: const TextStyle(fontSize: 15),
        styles: md.MarkdownStyleSheet(),
        builders: const {},
        historyController: history,
        onFormSubmit: onSubmit,
      ),
    ),
  ),
);

Widget _scaledFieldsetPage(
  String source, {
  required bool markdownStyles,
  required double textScale,
}) => MaterialApp(
  theme: theme.build(Brightness.light),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: SingleChildScrollView(
          child: NativeHtmlDocument(
            nodes: [NativeHtmlRaw(source)],
            style: const TextStyle(fontSize: 15),
            styles: md.MarkdownStyleSheet(),
            builders: const {},
            markdownStyles: markdownStyles,
          ),
        ),
      ),
    ),
  ),
);

NativeHtmlForms _forms(WidgetTester tester) => tester
    .widget<NativeHtmlFormFeedback>(find.byType(NativeHtmlFormFeedback))
    .forms;

NativeHtmlDateInput _dateNamed(WidgetTester tester, String name) =>
    tester.widget<NativeHtmlDateInput>(
      find.byWidgetPredicate(
        (widget) =>
            widget is NativeHtmlDateInput && widget.control.name == name,
      ),
    );

Finder _segment(NativeHtmlDateInput date, NativeHtmlDateSegment segment) =>
    find.byKey(
      ValueKey('native-html-date-segment-${date.control.key}-${segment.name}'),
    );

Finder _button(String label) => find.byWidgetPredicate(
  (widget) => widget is NativeHtmlButtonWidget && widget.button.label == label,
);

Future<void> _tapButton(WidgetTester tester, String label) async {
  final finder = _button(label);
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'NativeHtmlDocument validates, submits, resets, and serializes dates',
    (tester) async {
      final sent = <NativeHtmlFormSubmission>[];
      const source = '''
<form id="date-form" action="/collect" method="get">
  <label for="visit">Visit date</label>
  <input id="visit" type="date" name="visit" required
    min="2024-02-01" step="7" value="2024-02-08">
  <label for="locked">Readonly date</label>
  <input id="locked" type="date" name="locked" required readonly>
  <fieldset disabled><legend>Unavailable</legend>
    <input id="disabled-underflow" type="date" name="disabled"
      min="2024-03-01" value="2024-02-29">
  </fieldset>
  <button type="submit" name="go" value="yes">Send</button>
  <button type="reset">Reset</button>
</form>
''';
      await tester.pumpWidget(_page(source, onSubmit: sent.add));
      await tester.pumpAndSettle();

      final visit = _dateNamed(tester, 'visit');
      final locked = _dateNamed(tester, 'locked');
      expect(visit.state.valueFor(visit.control.key), '2024-02-08');
      expect(
        locked.state.validityFor(locked.control.key).willValidate,
        isFalse,
      );
      expect(locked.state.validityFor(locked.control.key).valid, isTrue);
      expect(
        _forms(tester)
            .validityForId('disabled-underflow')!
            .has(HtmlValidityFlag.rangeUnderflow),
        isTrue,
      );
      expect(
        _forms(tester).validityForId('disabled-underflow')!.willValidate,
        isFalse,
      );

      await tester.enterText(_segment(visit, NativeHtmlDateSegment.day), '09');
      expect(visit.state.valueFor(visit.control.key), '2024-02-09');
      await _tapButton(tester, 'Send');
      expect(sent, isEmpty);
      expect(
        _forms(
          tester,
        ).validityForId('visit')!.has(HtmlValidityFlag.stepMismatch),
        isTrue,
      );
      expect(
        visit.state
            .segmentFocusNodeFor(visit.control.key, NativeHtmlDateSegment.month)
            .hasFocus,
        isTrue,
      );

      await tester.enterText(_segment(visit, NativeHtmlDateSegment.day), '08');
      await _tapButton(tester, 'Send');
      expect(sent, hasLength(1));
      expect(
        [
          for (final entry in sent.single.entries) [entry.name, entry.value],
        ],
        [
          ['visit', '2024-02-08'],
          ['locked', ''],
          ['go', 'yes'],
        ],
      );
      expect(
        sent.single.buildRequest().url,
        '/collect?visit=2024-02-08&locked=&go=yes',
      );

      await tester.enterText(_segment(visit, NativeHtmlDateSegment.day), '09');
      await _tapButton(tester, 'Reset');
      expect(visit.state.valueFor(visit.control.key), '2024-02-08');
      expect(visit.state.wasUserEdited(visit.control.key), isFalse);

      await tester.enterText(_segment(visit, NativeHtmlDateSegment.month), '');
      await tester.enterText(_segment(visit, NativeHtmlDateSegment.day), '');
      await tester.enterText(_segment(visit, NativeHtmlDateSegment.year), '');
      await _tapButton(tester, 'Send');
      expect(sent, hasLength(1));
      expect(
        _forms(
          tester,
        ).validityForId('visit')!.has(HtmlValidityFlag.valueMissing),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'date history restores canonical and partial edits, but skips autocomplete off',
    (tester) async {
      const before = '''
<form id="date-form" autocomplete="on">
  <label for="canonical">Canonical</label>
  <input id="canonical" type="date" name="canonical" value="2024-02-29">
  <label for="draft">Partial draft</label>
  <input id="draft" type="date" name="draft">
  <label for="off">No autofill history</label>
  <input id="off" type="date" name="off" autocomplete="off" value="2024-04-01">
  <button type="reset">Reset</button>
</form>
''';
      const after = '''
<form id="date-form" autocomplete="on">
  <label for="canonical">Canonical</label>
  <input id="canonical" type="date" name="canonical" value="2024-01-31">
  <label for="draft">Partial draft</label>
  <input id="draft" type="date" name="draft" value="2025-01-01">
  <label for="off">No autofill history</label>
  <input id="off" type="date" name="off" autocomplete="off" value="2024-06-10">
  <button type="reset">Reset</button>
</form>
''';
      final originalHistory = NativeHtmlHistoryController();
      await tester.pumpWidget(_page(before, history: originalHistory));
      await tester.pumpAndSettle();

      final canonical = _dateNamed(tester, 'canonical');
      final draft = _dateNamed(tester, 'draft');
      final off = _dateNamed(tester, 'off');
      await tester.enterText(
        _segment(canonical, NativeHtmlDateSegment.month),
        '3',
      );
      await tester.enterText(_segment(draft, NativeHtmlDateSegment.month), '2');
      await tester.enterText(_segment(draft, NativeHtmlDateSegment.day), '30');
      await tester.enterText(
        _segment(draft, NativeHtmlDateSegment.year),
        '2024',
      );
      await tester.enterText(_segment(off, NativeHtmlDateSegment.month), '5');
      expect(canonical.state.valueFor(canonical.control.key), '2024-03-29');
      expect(draft.state.badInputFor(draft.control.key), isTrue);
      expect(off.state.valueFor(off.control.key), '2024-05-01');

      final snapshot = originalHistory.capture();
      expect(snapshot, isNotNull);
      final savedDates = snapshot!.controls.values
          .where((value) => value.kind == NativeHtmlHistoryValueKind.date)
          .map((value) => value.date!)
          .toList();
      expect(savedDates, hasLength(2));
      expect(savedDates.map((entry) => entry.value), contains('2024-03-29'));
      expect(savedDates.any((entry) => entry.badInput), isTrue);
      originalHistory.dispose();

      final restoredHistory = NativeHtmlHistoryController()..restore(snapshot);
      await tester.pumpWidget(_page(after, history: restoredHistory));
      await tester.pumpAndSettle();
      final restoredCanonical = _dateNamed(tester, 'canonical');
      final restoredDraft = _dateNamed(tester, 'draft');
      final restoredOff = _dateNamed(tester, 'off');
      expect(
        restoredCanonical.state.valueFor(restoredCanonical.control.key),
        '2024-03-29',
      );
      expect(restoredDraft.state.valueFor(restoredDraft.control.key), isEmpty);
      expect(
        restoredDraft.state.badInputFor(restoredDraft.control.key),
        isTrue,
      );
      expect(
        restoredDraft.state
            .segmentControllerFor(
              restoredDraft.control.key,
              NativeHtmlDateSegment.day,
            )
            .text,
        '30',
      );
      expect(restoredOff.state.valueFor(restoredOff.control.key), '2024-06-10');

      await _tapButton(tester, 'Reset');
      expect(
        restoredCanonical.state.valueFor(restoredCanonical.control.key),
        '2024-01-31',
      );
      expect(
        restoredDraft.state.valueFor(restoredDraft.control.key),
        '2025-01-01',
      );
      expect(
        restoredDraft.state.badInputFor(restoredDraft.control.key),
        isFalse,
      );
      expect(restoredOff.state.valueFor(restoredOff.control.key), '2024-06-10');
      expect(tester.takeException(), isNull);
      restoredHistory.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'first-legend date fields fit scaled text in raw and Markdown documents',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const source = '''
<fieldset disabled>
  <legend>
    <input id="automatic" type="date" name="automatic"
      value="2024-06-15" style="padding:1px 2px; border:1px solid">
  </legend>
</fieldset>
<fieldset disabled>
  <legend>
    <input id="authored" type="date" name="authored"
      value="2024-06-15" style="width:200px; padding:1px 2px; border:1px solid">
  </legend>
  <input id="outside-first-legend" type="date" name="disabled"
    value="2024-06-15">
</fieldset>
''';

      for (final markdownStyles in [false, true]) {
        double? authoredWidthAtScaleOne;
        double? autoWidthAtScaleOne;
        for (final scale in [1.0, 2.0]) {
          await tester.pumpWidget(
            _scaledFieldsetPage(
              source,
              markdownStyles: markdownStyles,
              textScale: scale,
            ),
          );
          await tester.pumpAndSettle();

          final automatic = _dateNamed(tester, 'automatic');
          final authored = _dateNamed(tester, 'authored');
          final disabled = _dateNamed(tester, 'disabled');
          expect(automatic.control.disabled, isFalse);
          expect(authored.control.disabled, isFalse);
          expect(disabled.control.disabled, isTrue);

          final automaticRect = tester.getRect(find.byWidget(automatic));
          final authoredRect = tester.getRect(find.byWidget(authored));
          expect(automaticRect.width, greaterThan(0));
          expect(authoredRect.width, greaterThan(0));
          expect(automaticRect.height, greaterThan(0));
          expect(authoredRect.height, greaterThan(0));
          if (scale == 1) {
            authoredWidthAtScaleOne = authoredRect.width;
            autoWidthAtScaleOne = automaticRect.width;
          } else {
            if (markdownStyles) {
              expect(
                authoredRect.width,
                greaterThan(authoredWidthAtScaleOne!),
                reason:
                    'intrinsic Markdown controls grow with their text metrics',
              );
            } else {
              expect(
                authoredRect.width,
                closeTo(authoredWidthAtScaleOne!, 1),
                reason: 'an authored CSS width stays fixed when text scales',
              );
            }
            expect(
              automaticRect.width,
              greaterThan(autoWidthAtScaleOne!),
              reason: 'the intrinsic date control grows with its text metrics',
            );
          }

          for (final date in [automatic, authored]) {
            final controlRect = tester.getRect(find.byWidget(date));
            final calendarRect = tester.getRect(
              find.byKey(
                ValueKey('native-html-date-calendar-${date.control.key}'),
              ),
            );
            expect(calendarRect.left, greaterThanOrEqualTo(controlRect.left));
            expect(calendarRect.right, lessThanOrEqualTo(controlRect.right));
            for (final segment in NativeHtmlDateSegment.values) {
              final fieldFinder = _segment(date, segment);
              final field = tester.widget<TextField>(fieldFinder);
              final scaleContext = tester.element(fieldFinder);
              final scaler = MediaQuery.textScalerOf(scaleContext);
              final style =
                  field.style ?? DefaultTextStyle.of(scaleContext).style;
              final sample = segment == NativeHtmlDateSegment.year
                  ? '0000'
                  : '88';
              final placeholder = switch (segment) {
                NativeHtmlDateSegment.month => 'MM',
                NativeHtmlDateSegment.day => 'DD',
                NativeHtmlDateSegment.year => 'YYYY',
              };
              double measuredWidth(String text) {
                final painter = TextPainter(
                  text: TextSpan(text: text, style: style),
                  textDirection: Directionality.of(scaleContext),
                  textScaler: scaler,
                  maxLines: 1,
                )..layout();
                return painter.width;
              }

              final textWidth = math.max(
                measuredWidth(sample),
                measuredWidth(placeholder),
              );
              final fieldSize = tester.getSize(fieldFinder);
              expect(
                fieldSize.width,
                greaterThanOrEqualTo(textWidth),
                reason:
                    '${date.control.name}/${segment.name} width, mode=$markdownStyles scale=$scale',
              );
              final line = TextPainter(
                text: TextSpan(text: sample, style: style),
                textDirection: Directionality.of(scaleContext),
                textScaler: scaler,
                maxLines: 1,
              )..layout();
              expect(
                fieldSize.height,
                greaterThanOrEqualTo(line.height),
                reason:
                    '${date.control.name}/${segment.name} height, mode=$markdownStyles scale=$scale',
              );
            }
          }

          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
    },
  );
}
