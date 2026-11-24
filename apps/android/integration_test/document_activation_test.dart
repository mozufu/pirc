import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_controls.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/html_text_fields.dart';
import 'package:pirc_mobile/theme.dart';

import 'document_activation_fixture.dart';

NativeFetchedDocument _document(int id) {
  final bytes = Uint8List.fromList(utf8.encode(documentActivationFixture));
  return NativeFetchedDocument(
    id: id,
    url: 'https://example.test/fixture',
    status: 200,
    bytes: bytes,
    mimeType: 'text/html',
    headers: const {},
    content: NativeHtmlDocumentContent.fromBytes(
      bytes,
      mimeType: 'text/html',
      charset: 'utf-8',
    ),
  );
}

Map<String, dynamic>? _elementJson(
  NativeFetchedDocument document,
  String selector,
) {
  final source = document.scripts?.content?.text;
  if (source == null) return null;
  final text = html.parse(source).querySelector(selector)?.text.trim();
  if (text == null || !text.startsWith('{')) return null;
  return Map<String, dynamic>.from(jsonDecode(text) as Map);
}

String? _scriptIdFor(NativeFetchedDocument document, String selector) {
  final source = document.scripts?.content?.text;
  if (source == null) return null;
  return html
      .parse(source)
      .querySelector(selector)
      ?.attributes['data-pirc-script-id'];
}

List<Map<String, dynamic>> _rows(Object? value) => (value as List)
    .map((row) => Map<String, dynamic>.from(row as Map))
    .toList(growable: false);

Map<String, dynamic> _map(Object? value) =>
    Map<String, dynamic>.from(value as Map);

void _expectClickShape(Map<String, dynamic> event) {
  expect(event['type'], 'click');
  expect(event['isTrusted'], false);
  expect(event['bubbles'], true);
  expect(event['cancelable'], true);
  expect(event['isMouseEvent'], true);
  expect(event['isPointerEvent'], true);
}

void _expectProgrammaticActivation(Map<String, dynamic> result) {
  expect(result['status'], 'DONE', reason: '$result');
  expect(result['networkSubmissionCount'], 0);
  final cases = _map(result['cases']);

  final checkbox = _map(cases['checkbox']);
  final checkboxEvents = _rows(checkbox['events']);
  expect(checkboxEvents.map((event) => event['type']).toList(), [
    'click',
    'input',
    'change',
  ]);
  expect(checkboxEvents.map((event) => event['checked']).toList(), [
    true,
    true,
    true,
  ]);
  expect(_map(checkbox['after']), {'checked': true, 'indeterminate': false});
  _expectClickShape(checkboxEvents.first);

  final cancelled = _map(cases['cancelledCheckbox']);
  final cancelledEvents = _rows(cancelled['events']);
  expect(cancelledEvents.map((event) => event['type']).toList(), ['click']);
  expect(_map(cancelled['after']), {'checked': false, 'indeterminate': true});
  expect(_map(cancelled['documentObservation']), {
    'targetId': 'cancelled-checkbox',
    'defaultPrevented': true,
    'checked': true,
  });

  final radio = _map(cases['radio']);
  final radioTwoEvents = _rows(radio['radioTwoEvents']);
  expect(radioTwoEvents.map((event) => event['type']).toList(), [
    'click',
    'input',
    'change',
    'click',
  ]);
  expect(_rows(radio['radioOneEvents']), isEmpty);
  expect(_map(radio['after']), {'radioOne': false, 'radioTwo': true});

  final disabled = _map(cases['disabled']);
  expect(_rows(disabled['ownDisabledEvents']), isEmpty);
  expect(_rows(disabled['fieldsetDescendantEvents']), isEmpty);
  expect(_rows(disabled['firstLegendEvents']).map((event) => event['type']), [
    'click',
    'input',
    'change',
  ]);
  expect(_map(disabled['after']), {
    'ownDisabled': false,
    'fieldsetDescendant': false,
    'firstLegend': true,
  });

  final submit = _map(cases['submitButtonChildClick']);
  final childClicks = _rows(submit['childClickEvents']);
  final buttonClicks = _rows(submit['buttonClickEvents']);
  final submitEvents = _rows(submit['submitEvents']);
  expect(childClicks, hasLength(1));
  expect(childClicks.single['targetId'], 'submit-button-child');
  expect(childClicks.single['currentTargetId'], 'submit-button-child');
  expect(buttonClicks, hasLength(1));
  expect(buttonClicks.single['targetId'], 'submit-button-child');
  expect(buttonClicks.single['currentTargetId'], 'submit-button');
  expect(submitEvents, hasLength(1));
  expect(submitEvents.single['submitterId'], 'submit-button');
  // The form's watcher was registered before the later preventDefault handler.
  expect(submitEvents.single['defaultPrevented'], false);
  expect(_map(submit['documentObservation'])['submitterId'], 'submit-button');
  expect(_map(submit['documentObservation'])['defaultPrevented'], true);

  final reset = _map(cases['resetButton']);
  final resetEvents = _rows(reset['events']);
  expect(resetEvents.map((event) => event['type']).toList(), ['reset']);
  expect(reset['valueAfter'], 'original');
  expect(_map(reset['documentObservation']), {
    'targetId': 'reset-form',
    'defaultPrevented': false,
  });

  final cancelledReset = _map(cases['cancelledResetButton']);
  expect(_rows(cancelledReset['events']).map((event) => event['type']), [
    'reset',
  ]);
  expect(cancelledReset['valueAfter'], 'changed');
  expect(_map(cancelledReset['documentObservation'])['defaultPrevented'], true);

  final label = _map(cases['label']);
  for (final name in ['explicit', 'implicit']) {
    final activated = _map(label[name]);
    expect(
      _rows(activated['events']).map((event) => event['type']),
      ['click', 'input', 'change'],
      reason: '$name label activation',
    );
    expect(activated['checked'], true);
  }
  final cancelledLabel = _map(label['cancelled']);
  expect(_rows(cancelledLabel['events']), isEmpty);
  expect(cancelledLabel['checked'], false);
  expect(_map(cancelledLabel['documentObservation'])['defaultPrevented'], true);
  final interactive = _map(label['interactiveDescendant']);
  expect(_rows(interactive['childEvents']), hasLength(1));
  expect(_rows(interactive['labelControlEvents']), isEmpty);
  expect(interactive['checked'], false);
  final disabledLabel = _map(label['disabledTarget']);
  expect(_rows(disabledLabel['events']), isEmpty);
  expect(disabledLabel['checked'], false);

  final recursive = _map(cases['recursiveClick']);
  expect(_rows(recursive['events']).map((event) => event['type']), [
    'click',
    'input',
    'change',
  ]);
  expect(recursive['reentryAttempts'], 1);
  expect(recursive['after'], true);

  final disabledMouse = _map(cases['disabledMouseEventDispatch']);
  expect(_rows(disabledMouse['events']).map((event) => event['type']), [
    'click',
    'input',
    'change',
  ]);
  expect(disabledMouse['after'], true);
  final dispatchedMouse = _map(cases['mouseEventDispatch']);
  expect(_rows(dispatchedMouse['events']).map((event) => event['type']), [
    'click',
    'input',
    'change',
  ]);
  expect(dispatchedMouse['after'], true);
  final dispatchedEvent = _map(cases['plainEventDispatch']);
  expect(_rows(dispatchedEvent['events']).map((event) => event['type']), [
    'click',
  ]);
  expect(dispatchedEvent['after'], false);

  final disabledSubmit = _map(cases['disabledSubmitMouseEventDispatch']);
  expect(_rows(disabledSubmit['buttonEvents']), hasLength(1));
  expect(_rows(disabledSubmit['submitEvents']), isEmpty);
  expect(_rows(disabledSubmit['documentObservation']), isEmpty);
  final disabledReset = _map(cases['disabledResetMouseEventDispatch']);
  expect(_rows(disabledReset['buttonEvents']), hasLength(1));
  expect(_rows(disabledReset['resetEvents']), isEmpty);
  expect(_rows(disabledReset['documentObservation']), isEmpty);
  expect(disabledReset['valueAfter'], 'changed');
  final fieldsetSubmit = _map(cases['disabledFieldsetChildClick']);
  expect(_rows(fieldsetSubmit['childEvents']), hasLength(1));
  expect(_rows(fieldsetSubmit['buttonEvents']), hasLength(1));
  expect(_rows(fieldsetSubmit['submitEvents']), isEmpty);
  expect(_rows(fieldsetSubmit['documentObservation']), isEmpty);

  final shapes = _map(cases['eventShapes']);
  _expectClickShape(_rows(shapes['divClick']).single);
  _expectClickShape(_rows(shapes['buttonClick']).single);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'programmatic and native HTML activation agree across viewport, theme, and text scale',
    (tester) async {
      final theme = await PircTheme.load();
      final gateway = Gateway();
      var documentId = 0;

      Future<void> until(
        NativeFetchedDocument document,
        bool Function() ready,
        String label,
      ) async {
        for (var i = 0; i < 240 && !ready(); i++) {
          await tester.pump(const Duration(milliseconds: 25));
        }
        expect(
          ready(),
          isTrue,
          reason:
              '$label: ${document.scripts?.diagnostics}; physical=${_elementJson(document, '#physical-result')}',
        );
        expect(tester.takeException(), isNull, reason: label);
      }

      Finder button(String label) => find.byWidgetPredicate(
        (widget) =>
            widget is NativeHtmlButtonWidget && widget.button.label == label,
        description: 'Native HTML button "$label"',
      );

      Future<void> tapButton(String label) async {
        final finder = button(label);
        expect(finder, findsOneWidget, reason: 'button "$label" is rendered');
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        expect(
          finder.hitTestable(),
          findsOneWidget,
          reason:
              '$label rect=${tester.getRect(finder)} screen=${tester.view.physicalSize} insets=${tester.view.viewInsets}',
        );
        await tester.tap(finder);
      }

      NativeHtmlControlWidget physicalCheckbox(
        NativeFetchedDocument document,
      ) => tester.widget<NativeHtmlControlWidget>(
        find.byWidgetPredicate(
          (widget) =>
              widget is NativeHtmlControlWidget &&
              widget.control.scriptId ==
                  _scriptIdFor(document, '#physical-checkbox'),
          description: 'native control for #physical-checkbox',
        ),
      );

      NativeHtmlControlWidget explicitCheckbox(
        NativeFetchedDocument document,
      ) => tester.widget<NativeHtmlControlWidget>(
        find.byWidgetPredicate(
          (widget) =>
              widget is NativeHtmlControlWidget &&
              widget.control.scriptId ==
                  _scriptIdFor(document, '#explicit-checkbox'),
          description: 'native control for #explicit-checkbox',
        ),
      );

      NativeHtmlTextFieldWidget physicalResetField() => tester
          .widgetList<NativeHtmlTextFieldWidget>(
            find.byType(NativeHtmlTextFieldWidget),
          )
          .singleWhere(
            (widget) => widget.field.label == 'physical reset value',
          );

      for (final width in [390.0, 860.0]) {
        for (final brightness in [Brightness.light, Brightness.dark]) {
          for (final scale in [1.0, 2.0]) {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 844);
            // The emulator's real keyboard inset is in its 1080px surface,
            // not this synthetic 390/860px viewport. Exercise controls without
            // importing that mismatched inset; IME behavior has separate tests.
            tester.view.viewInsets = const FakeViewPadding();
            final document = _document(++documentId);
            var hostSubmissions = 0;

            try {
              await tester.pumpWidget(
                MaterialApp(
                  theme: theme.build(brightness),
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: Scaffold(
                    body: NativeFetchedDocumentView(
                      document: document,
                      gateway: gateway,
                      onLink: (_) {},
                      onSubmit: (_) => hostSubmissions++,
                    ),
                  ),
                ),
              );

              await until(
                document,
                () =>
                    document.scripts?.ready == true &&
                    _elementJson(document, '#result')?['status'] == 'READY',
                'runtime and fixture initialize at $width/${brightness.name}/$scale',
              );
              await tester.pumpAndSettle();

              await tapButton('Run activation checks');
              await until(
                document,
                () => _elementJson(document, '#result')?['status'] == 'DONE',
                'programmatic activation cases finish',
              );
              final result = _elementJson(document, '#result')!;
              _expectProgrammaticActivation(result);

              final checkboxFinder = find.byWidgetPredicate(
                (widget) =>
                    widget is NativeHtmlControlWidget &&
                    widget.control.scriptId ==
                        _scriptIdFor(document, '#physical-checkbox'),
              );
              expect(checkboxFinder, findsOneWidget);
              expect(
                physicalCheckbox(
                  document,
                ).state.isChecked(physicalCheckbox(document).control.key),
                false,
              );
              await tester.ensureVisible(checkboxFinder);
              await tester.tap(checkboxFinder);
              await until(
                document,
                () =>
                    _elementJson(document, '#physical-result')?['checkbox'] !=
                    null,
                'native checkbox click is observed in the document',
              );
              var physical = _elementJson(document, '#physical-result')!;
              var physicalCheckboxResult = _map(physical['checkbox']);
              final physicalCheckboxEvents = _rows(
                physicalCheckboxResult['events'],
              );
              expect(physicalCheckboxEvents.map((event) => event['type']), [
                'click',
                'input',
                'change',
              ]);
              expect(physicalCheckboxEvents.map((event) => event['checked']), [
                true,
                true,
                true,
              ]);
              expect(physicalCheckboxEvents.first['isTrusted'], true);
              expect(physicalCheckboxEvents.first['isMouseEvent'], true);
              expect(physicalCheckboxEvents.first['isPointerEvent'], true);
              expect(physicalCheckboxResult['checked'], true);
              final checkedWidget = physicalCheckbox(document);
              expect(
                checkedWidget.state.isChecked(checkedWidget.control.key),
                true,
              );

              var resetField = physicalResetField();
              expect(
                resetField.state.valueFor(resetField.field.key),
                'original',
              );
              final editor = find.descendant(
                of: find.byKey(
                  resetField.state.editorKeyFor(resetField.field.key),
                ),
                matching: find.byType(EditableText),
              );
              expect(editor, findsOneWidget);
              await tester.ensureVisible(editor);
              await tester.enterText(editor, 'changed');
              await until(document, () {
                final field = physicalResetField();
                return field.state.valueFor(field.field.key) == 'changed';
              }, 'native text field accepts the changed value');

              // Dismiss the IME as a phone user can, then reveal the reset
              // button below the edited field without the caret scroll racing it.
              await SystemChannels.textInput.invokeMethod<void>(
                'TextInput.hide',
              );
              await tester.pumpAndSettle();
              await tapButton('Physical reset');
              await until(document, () {
                final reset = _elementJson(document, '#physical-result');
                if (reset == null || reset['reset'] == null) return false;
                final observation = _map(reset['reset']);
                return _rows(observation['events']).length == 1 &&
                    observation['value'] == 'original';
              }, 'native reset button restores the text field once');
              physical = _elementJson(document, '#physical-result')!;
              physicalCheckboxResult = _map(physical['checkbox']);
              final physicalReset = _map(physical['reset']);
              final physicalResetEvents = _rows(physicalReset['events']);
              expect(physicalResetEvents.map((event) => event['type']), [
                'reset',
              ]);
              expect(physicalResetEvents.single['isTrusted'], true);
              final physicalFormObservations = _rows(
                physicalReset['formObservation'],
              );
              expect(
                physicalFormObservations.map((event) => event['targetId']),
                ['physical-reset-form'],
              );
              expect(
                physicalFormObservations.single['defaultPrevented'],
                false,
              );
              expect(physicalReset['value'], 'original');
              resetField = physicalResetField();
              expect(
                resetField.state.valueFor(resetField.field.key),
                'original',
              );

              final explicitLabel = find.byWidgetPredicate(
                (widget) =>
                    widget is RichText &&
                    widget.text.toPlainText().contains('Explicit label'),
              );
              expect(explicitLabel, findsOneWidget);
              FocusManager.instance.primaryFocus?.unfocus();
              await tester.pumpAndSettle();
              await tester.ensureVisible(explicitLabel);
              await tester.pumpAndSettle();
              final checkboxBeforeLabel = explicitCheckbox(document);
              expect(
                checkboxBeforeLabel.state.isChecked(
                  checkboxBeforeLabel.control.key,
                ),
                true,
              );
              final explicitCheckboxFinder = find.byWidgetPredicate(
                (widget) =>
                    widget is NativeHtmlControlWidget &&
                    widget.control.scriptId ==
                        _scriptIdFor(document, '#explicit-checkbox'),
              );
              final explicitFocusFinder = find.descendant(
                of: explicitCheckboxFinder,
                matching: find.byType(Focus),
              );
              expect(explicitFocusFinder, findsOneWidget);
              Offset labelPoint() {
                final paragraph = tester.renderObject<RenderParagraph>(
                  explicitLabel,
                );
                final offset = paragraph.text.toPlainText().indexOf(
                  'Explicit label',
                );
                final boxes = paragraph.getBoxesForSelection(
                  TextSelection(baseOffset: offset, extentOffset: offset + 1),
                );
                expect(boxes, isNotEmpty);
                return paragraph.localToGlobal(boxes.first.toRect().center);
              }

              // A RichText paragraph can contain several inline controls.
              // Reveal this label's glyph, rather than the paragraph's center.
              document.scroll.jumpTo(
                (document.scroll.offset + labelPoint().dy - 400).clamp(
                  document.scroll.position.minScrollExtent,
                  document.scroll.position.maxScrollExtent,
                ),
              );
              await tester.pumpAndSettle();
              expect(labelPoint().dy, inInclusiveRange(0, 844));
              final tappedLabelPoint = labelPoint();
              final labelHit = tester.hitTestOnBinding(tappedLabelPoint);
              final labelHitTargets = labelHit.path
                  .map((entry) => entry.target.runtimeType.toString())
                  .toList();
              expect(
                labelHit.path.any((entry) => entry.target is RenderParagraph),
                isTrue,
                reason: 'inline label glyph is hittable: $labelHitTargets',
              );
              await tester.tapAt(tappedLabelPoint);
              try {
                await until(
                  document,
                  () {
                    final control = explicitCheckbox(document);
                    final focus = tester.widget<Focus>(explicitFocusFinder);
                    return !control.state.isChecked(control.control.key) &&
                        focus.focusNode?.hasFocus == true;
                  },
                  'native label activation toggles and focuses its checkbox',
                );
              } catch (_) {
                final control = explicitCheckbox(document);
                debugPrintSynchronously(
                  'LABEL_DIAGNOSTIC ${jsonEncode({'width': width, 'theme': brightness.name, 'scale': scale, 'point': labelPoint().toString(), 'tappedPoint': tappedLabelPoint.toString(), 'hit': labelHitTargets, 'scroll': document.scroll.offset, 'checked': control.state.isChecked(control.control.key), 'focused': tester.widget<Focus>(explicitFocusFinder).focusNode?.hasFocus, 'insets': tester.view.viewInsets.toString()})}',
                );
                rethrow;
              }
              final checkboxAfterLabel = explicitCheckbox(document);
              final explicitFocus = tester.widget<Focus>(explicitFocusFinder);
              final hostLabel = {
                'checked': checkboxAfterLabel.state.isChecked(
                  checkboxAfterLabel.control.key,
                ),
                'focused': explicitFocus.focusNode?.hasFocus ?? false,
              };
              expect(hostLabel, {'checked': false, 'focused': true});

              expect(hostSubmissions, 0);
              expect(document.scripts!.diagnostics, isEmpty);
              expect(tester.takeException(), isNull);

              debugPrintSynchronously(
                'NATIVE_ACTIVATION ${jsonEncode({'width': width, 'theme': brightness.name, 'scale': scale, 'result': result, 'physical': physical, 'hostLabel': hostLabel, 'hostSubmissions': hostSubmissions})}',
              );
            } finally {
              await tester.pumpWidget(const SizedBox());
              document.dispose();
              await document.scripts?.closed;
            }
          }
        }
      }

      tester.view.reset();
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
