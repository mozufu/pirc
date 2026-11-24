import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_date_validation.dart';

void main() {
  group('NativeHtmlDateValue', () {
    test('parses and serializes valid Gregorian date strings', () {
      expect(NativeHtmlDateValue.parse('2024-02-29')?.canonical, '2024-02-29');
      expect(NativeHtmlDateValue.parse('2000-02-29')?.canonical, '2000-02-29');
      expect(NativeHtmlDateValue.parse('1900-02-29'), isNull);
      expect(NativeHtmlDateValue.parse('2023-02-29'), isNull);
      expect(NativeHtmlDateValue.parse('2024-04-31'), isNull);
      expect(NativeHtmlDateValue.parse('2024-2-09'), isNull);
      expect(NativeHtmlDateValue.parse('0000-01-01'), isNull);
      expect(NativeHtmlDateValue.parse('0001-01-01')?.canonical, '0001-01-01');
      expect(
        NativeHtmlDateValue.parse('12024-01-02')?.canonical,
        '12024-01-02',
      );
    });

    test('epoch-day conversion is timezone-free and reversible', () {
      for (final value in [
        '0001-01-01',
        '1969-12-31',
        '1970-01-01',
        '2000-02-29',
        '2024-12-31',
        '12024-03-01',
      ]) {
        final parsed = NativeHtmlDateValue.parse(value)!;
        expect(
          NativeHtmlDateValue.fromEpochDays(parsed.epochDays)?.canonical,
          value,
        );
      }
      expect(NativeHtmlDateValue.parse('1970-01-01')!.epochDays, BigInt.zero);
      expect(
        NativeHtmlDateValue.parse('1969-12-31')!.epochDays,
        BigInt.from(-1),
      );
    });

    test('invalid values sanitize to the HTML empty value', () {
      expect(NativeHtmlDateValidation.sanitize('2024-02-29'), '2024-02-29');
      for (final invalid in [
        '',
        '2023-02-29',
        '2024-2-09',
        ' 2024-02-09',
        '2024-02-09 ',
      ]) {
        expect(NativeHtmlDateValidation.sanitize(invalid), isEmpty);
      }
    });
  });

  group('NativeHtmlDateValidation', () {
    test('checks required, min, max, step, and bad input independently', () {
      final empty = NativeHtmlDateValidation.evaluate(
        value: '',
        required: true,
        disabled: false,
        readOnly: false,
      );
      expect(empty.willValidate, isTrue);
      expect(empty.valueMissing, isTrue);
      expect(empty.valid, isFalse);

      final underflow = NativeHtmlDateValidation.evaluate(
        value: '2024-02-09',
        required: false,
        disabled: false,
        readOnly: false,
        min: '2024-02-10',
      );
      expect(underflow.rangeUnderflow, isTrue);

      final overflow = NativeHtmlDateValidation.evaluate(
        value: '2024-02-21',
        required: false,
        disabled: false,
        readOnly: false,
        max: '2024-02-20',
      );
      expect(overflow.rangeOverflow, isTrue);

      final mismatch = NativeHtmlDateValidation.evaluate(
        value: '2024-02-13',
        required: false,
        disabled: false,
        readOnly: false,
        min: '2024-02-10',
        step: '2',
      );
      expect(mismatch.stepMismatch, isTrue);
      expect(
        NativeHtmlDateValidation.evaluate(
          value: '2024-02-14',
          required: false,
          disabled: false,
          readOnly: false,
          min: '2024-02-10',
          step: '2',
        ).stepMismatch,
        isFalse,
      );

      final badInput = NativeHtmlDateValidation.evaluate(
        value: '',
        required: false,
        disabled: false,
        readOnly: false,
        badInput: true,
      );
      expect(badInput.badInput, isTrue);
      expect(badInput.valid, isFalse);
    });

    test('step base follows min, value attribute, then the epoch', () {
      final minBase = NativeHtmlDateValidation.evaluate(
        value: '2024-02-12',
        required: false,
        disabled: false,
        readOnly: false,
        min: '2024-02-10',
        valueAttribute: '2024-02-11',
        step: '2',
      );
      expect(minBase.stepMismatch, isFalse);

      final valueBase = NativeHtmlDateValidation.evaluate(
        value: '2024-02-13',
        required: false,
        disabled: false,
        readOnly: false,
        valueAttribute: '2024-02-11',
        step: '2',
      );
      expect(valueBase.stepMismatch, isFalse);

      final epochBase = NativeHtmlDateValidation.evaluate(
        value: '1970-01-02',
        required: false,
        disabled: false,
        readOnly: false,
        step: '2',
      );
      expect(epochBase.stepMismatch, isTrue);
      expect(
        NativeHtmlDateValidation.evaluate(
          value: '1970-01-02',
          required: false,
          disabled: false,
          readOnly: false,
          step: 'any',
        ).stepMismatch,
        isFalse,
      );
    });

    test('fractional day steps use exact arithmetic', () {
      for (final value in ['2024-02-10', '2024-02-11', '2024-02-12']) {
        expect(
          NativeHtmlDateValidation.evaluate(
            value: value,
            required: false,
            disabled: false,
            readOnly: false,
            min: '2024-02-10',
            step: '0.5',
          ).stepMismatch,
          isFalse,
        );
      }
      expect(
        NativeHtmlDateValidation.evaluate(
          value: '2024-02-11',
          required: false,
          disabled: false,
          readOnly: false,
          min: '2024-02-10',
          step: '1.5',
        ).stepMismatch,
        isTrue,
      );
    });

    test('readonly and disabled controls are barred from validation', () {
      final readonly = NativeHtmlDateValidation.evaluate(
        value: '',
        required: true,
        disabled: false,
        readOnly: true,
        badInput: true,
      );
      expect(readonly.willValidate, isFalse);
      expect(readonly.valid, isTrue);
      expect(readonly.valueMissing, isFalse);
      expect(readonly.badInput, isFalse);

      final disabledUnderflow = NativeHtmlDateValidation.evaluate(
        value: '2024-02-29',
        required: false,
        disabled: true,
        readOnly: false,
        min: '2024-03-01',
      );
      expect(disabledUnderflow.willValidate, isFalse);
      expect(disabledUnderflow.rangeUnderflow, isTrue);
      expect(disabledUnderflow.valid, isFalse);

      final readonlyUnderflow = NativeHtmlDateValidation.evaluate(
        value: '2024-02-29',
        required: false,
        disabled: false,
        readOnly: true,
        min: '2024-03-01',
      );
      expect(readonlyUnderflow.willValidate, isFalse);
      expect(readonlyUnderflow.rangeUnderflow, isTrue);
      expect(readonlyUnderflow.valid, isFalse);

      final readonlyStep = NativeHtmlDateValidation.evaluate(
        value: '2024-03-02',
        required: false,
        disabled: false,
        readOnly: true,
        min: '2024-03-01',
        step: '7',
      );
      expect(readonlyStep.willValidate, isFalse);
      expect(readonlyStep.stepMismatch, isTrue);
      expect(readonlyStep.valid, isFalse);

      final disabledStep = NativeHtmlDateValidation.evaluate(
        value: '2024-03-02',
        required: false,
        disabled: true,
        readOnly: false,
        min: '2024-03-01',
        step: '7',
      );
      expect(disabledStep.willValidate, isFalse);
      expect(disabledStep.stepMismatch, isTrue);
      expect(disabledStep.valid, isFalse);

      final disabledMissing = NativeHtmlDateValidation.evaluate(
        value: '',
        required: true,
        disabled: true,
        readOnly: false,
      );
      expect(disabledMissing.willValidate, isFalse);
      expect(disabledMissing.valueMissing, isFalse);
      expect(disabledMissing.valid, isTrue);
    });

    test('finds a first selectable step-aligned day in a bounded interval', () {
      final first = NativeHtmlDateValidation.firstSelectable(
        from: NativeHtmlDateValue.parse('2024-02-02')!,
        through: NativeHtmlDateValue.parse('2024-02-10')!,
        min: '2024-02-01',
        step: '7',
      );
      expect(first?.canonical, '2024-02-08');
      expect(
        NativeHtmlDateValidation.firstSelectable(
          from: NativeHtmlDateValue.parse('2024-02-02')!,
          through: NativeHtmlDateValue.parse('2024-02-07')!,
          min: '2024-02-01',
          step: '7',
        ),
        isNull,
      );
    });
  });
}
