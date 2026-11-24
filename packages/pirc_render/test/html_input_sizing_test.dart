import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_input_sizing.dart';

const _expectedPath =
    '../../fixtures/mobile-parity/html-input-sizing-expected.json';
const _fixturePath = '../../fixtures/mobile-parity/html-input-sizing.json';

Map<String, dynamic> _map(Object? value) =>
    (value as Map<dynamic, dynamic>).cast<String, dynamic>();

List<Map<String, dynamic>> _numberControls(Map<String, dynamic> expectedCase) =>
    (expectedCase['controls'] as List)
        .map(_map)
        .where((control) => control['type'] == 'number')
        .toList();

Map<String, dynamic> _attributes(Map<String, dynamic> control) =>
    _map(control['attributes']);

void main() {
  test('intrinsic average rounding matches captured Arial UA input width', () {
    // Chrome 154 raw document probe: x advance 6.66499, 20 characters,
    // ascent/max 12 and 8px total UA border/padding -> 153px border box.
    final average = HtmlInputSizing.effectiveAverageCharacterWidth(6.66499);
    expect(average, 7);
    expect(
      HtmlInputSizing.textFieldIntrinsicInlineSize(
            preferredCharacterCount: 20,
            averageCharacterWidth: average,
            maximumCharacterWidth: 12,
          ) +
          8,
      153,
    );
    // The current Blink consumer deliberately keeps lower fractions; rounding
    // every average would shrink those controls.
    expect(HtmlInputSizing.effectiveAverageCharacterWidth(6.4), 6.4);
    expect(HtmlInputSizing.effectiveAverageCharacterWidth(6.5), 7);
  });

  late Map<String, dynamic> fixture;
  late Map<String, dynamic> expected;

  setUpAll(() {
    fixture =
        jsonDecode(File(_fixturePath).readAsStringSync())
            as Map<String, dynamic>;
    expected =
        jsonDecode(File(_expectedPath).readAsStringSync())
            as Map<String, dynamic>;
  });

  test('matches every Chromium 154 number-size oracle case', () {
    expect(expected['fixture'], fixture['id']);
    expect(expected['reference'], fixture['webRevision']);
    expect(expected['browserVersion'], '154.0.8037.93');

    const expectedCounts = <String, int>{
      'number-default': 20,
      'number-explicit-size-2': 20,
      'number-explicit-size-2-bounded': 1,
      'number-one-digit-bounds-default-step': 1,
      'number-one-digit-bounds-step-2': 1,
      'number-fractional-step': 4,
      'number-negative-bounds': 2,
      'number-negative-fraction-bounds': 6,
      'number-step-exponent': 5,
      'number-step-any': 20,
      'number-missing-min': 20,
      'number-missing-max': 20,
      'number-invalid-min': 20,
      'number-invalid-step-zero': 1,
      'number-unbounded-negative-step': 5,
      'number-invalid-step-negative': 4,
    };

    final themes = _map(expected['themes']);
    for (final themeEntry in themes.entries) {
      for (final rawViewport in _map(themeEntry.value)['widths'] as List) {
        final viewport = _map(rawViewport);
        final sizingCase = (_map(viewport)['cases'] as List)
            .map(_map)
            .firstWhere((testCase) => testCase['id'] == 'number-size-rules');
        final controls = _numberControls(sizingCase);
        final actualIds = controls.map((control) => control['id']).toSet();
        expect(
          actualIds,
          expectedCounts.keys.toSet(),
          reason: '${themeEntry.key}, width ${viewport['width']}',
        );

        final defaultControl = controls.firstWhere(
          (control) => control['id'] == 'number-default',
        );
        final baselineWidth = _map(defaultControl['box'])['width'] as num;
        final averageAdvance =
            _map(_map(defaultControl['fontMetrics'])['sampleWidths'])['x']
                as num;
        expect(averageAdvance, greaterThan(0));

        for (final control in controls) {
          final id = control['id'] as String;
          final attributes = _attributes(control);
          final actualCount =
              HtmlInputSizing.numberInputPreferredCharacterCount(
                min: attributes['min'] as String?,
                max: attributes['max'] as String?,
                step: attributes['step'] as String?,
              );
          expect(actualCount, expectedCounts[id], reason: id);

          // The browser's measured number-field preferred width is affine in
          // the measured x advance: its unbounded default is 20 characters,
          // and each changed preferred character adds one x advance.
          final predictedWidth =
              baselineWidth + (actualCount - 20) * averageAdvance;
          final measuredWidth = _map(control['box'])['width'] as num;
          expect(
            measuredWidth,
            closeTo(predictedWidth.toDouble(), 0.001),
            reason: '$id width in ${themeEntry.key}/${viewport['width']}',
          );
        }
      }
    }
  });

  test('uses the parsed bounds and raw step for number field sizing', () {
    int count({String? min, String? max, String? step}) =>
        HtmlInputSizing.numberInputPreferredCharacterCount(
          min: min,
          max: max,
          step: step,
        );

    expect(count(min: '1', max: '9'), 1); // Missing step defaults to 1.
    expect(count(min: '1', max: '9', step: 'broken'), 1);
    expect(count(min: '1', max: '9', step: '0'), 1);
    expect(count(min: '1', max: '9', step: '-234'), 4);
    expect(count(min: '-9', max: '9', step: '1'), 2);
    expect(count(min: '-1.5', max: '2.75', step: '0.125'), 6);
    expect(count(min: '1', max: '9', step: '1e-3'), 5);
    expect(count(min: '1', max: '9', step: 'any'), 20);

    // Both bounds must be finite HTML number values. Leading plus is not in
    // the number-state grammar, and missing or malformed values use 20.
    expect(count(max: '9', step: '2'), 20);
    expect(count(min: '1', step: '2'), 20);
    expect(count(min: '+1', max: '9', step: '2'), 20);
    expect(count(min: '1', max: '1e309', step: '2'), 20);
  });

  test('uses positive size and cols, otherwise the HTML default of 20', () {
    for (final value in <int?>[null, 0, -1]) {
      expect(HtmlInputSizing.textInputPreferredCharacterCount(value), 20);
      expect(HtmlInputSizing.textareaPreferredColumnCount(value), 20);
    }
    expect(HtmlInputSizing.textInputPreferredCharacterCount(1), 1);
    expect(HtmlInputSizing.textInputPreferredCharacterCount(37), 37);
    expect(HtmlInputSizing.textareaPreferredColumnCount(2), 2);
    expect(HtmlInputSizing.textareaPreferredColumnCount(80), 80);
  });

  test(
    'computes intrinsic text and textarea inline sizes before decorations',
    () {
      expect(
        HtmlInputSizing.textFieldIntrinsicInlineSize(
          preferredCharacterCount: 2,
          averageCharacterWidth: 8,
          maximumCharacterWidth: 15.1,
        ),
        24,
      );
      expect(
        HtmlInputSizing.textFieldIntrinsicInlineSize(
          preferredCharacterCount: 0,
          averageCharacterWidth: 8,
          maximumCharacterWidth: 15.1,
          spinButtonInlineSize: 12,
        ),
        180,
      );
      expect(
        HtmlInputSizing.textareaIntrinsicInlineSize(
          preferredColumnCount: 10,
          averageCharacterWidth: 8.1,
          scrollbarThickness: 15,
        ),
        96,
      );
    },
  );
}
