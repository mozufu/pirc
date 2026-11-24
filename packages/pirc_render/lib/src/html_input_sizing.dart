/// Chromium-compatible intrinsic sizing rules for HTML text controls.
///
/// This module computes preferred character counts and the font-metric part of
/// the intrinsic inline size. Callers must supply metrics for the font actually
/// used by the target renderer, then add UA padding, borders, and other control
/// decorations separately.
abstract final class HtmlInputSizing {
  /// Chromium's default preferred character count for text-like inputs and
  /// number inputs when number bounds cannot provide a preferred size.
  static const int defaultPreferredCharacterCount = 20;

  /// Returns the text input's preferred character count.
  ///
  /// HTML input `size` is a positive integer; missing, zero, or invalid values
  /// use Chromium's default of 20. The descriptor parser may already have
  /// applied this fallback, so this accepts a nullable integer.
  static int textInputPreferredCharacterCount(int? size) =>
      size != null && size > 0 ? size : defaultPreferredCharacterCount;

  /// Returns the textarea's preferred column count.
  ///
  /// HTML textarea `cols` is a positive integer; missing, zero, or invalid
  /// values use Chromium's default of 20.
  static int textareaPreferredColumnCount(int? cols) =>
      cols != null && cols > 0 ? cols : defaultPreferredCharacterCount;

  /// Returns Blink's preferred character count for `<input type="number">`.
  ///
  /// Chromium uses a default of 20 unless both `min` and `max` parse as finite
  /// HTML numbers and `step` is not exactly `any` (case-insensitive). A missing
  /// or invalid step is treated as 1. The number control's `size` attribute is
  /// not consulted by Blink's sizing path, so this API intentionally has no
  /// `size` parameter.
  ///
  /// For a parsed number, Blink counts its coefficient digits and decimal
  /// exponent, then combines the maximum integer and fractional digit counts
  /// from `min`, `max`, and `step`. A negative step is included as written by
  /// Chromium's sizing code even though it is invalid for step validation.
  static int numberInputPreferredCharacterCount({
    required String? min,
    required String? max,
    required String? step,
  }) {
    if (step?.toLowerCase() == 'any') {
      return defaultPreferredCharacterCount;
    }

    final minimum = _BlinkDecimal.parseNumberTypeValue(min);
    final maximum = _BlinkDecimal.parseNumberTypeValue(max);
    if (minimum == null || maximum == null) {
      return defaultPreferredCharacterCount;
    }

    final parsedStep =
        _BlinkDecimal.parseNumberTypeValue(step) ?? _BlinkDecimal.one;
    final size = _BlinkNumberRenderSize.fromDecimal(minimum)
        .max(_BlinkNumberRenderSize.fromDecimal(maximum))
        .max(_BlinkNumberRenderSize.fromDecimal(parsedStep));
    return size.preferredCharacterCount;
  }

  /// Blink's GetAvgCharWidth preserves fractions below 0.5 and rounds up
  /// fractions at or above 0.5 for a font with valid average-width metrics.
  /// https://github.com/chromium/chromium/blob/main/third_party/blink/renderer/core/layout/forms/layout_text_control.cc
  /// Platform font selection and fonts requiring the zero-glyph fallback are
  /// handled by the caller, not inferred from this numeric metric.
  static double effectiveAverageCharacterWidth(double measuredWidth) {
    final rounded = measuredWidth.roundToDouble();
    return rounded > measuredWidth ? rounded : measuredWidth;
  }

  /// Returns the intrinsic content inline size for a text-like input before
  /// CSS border and padding are added.
  ///
  /// `averageCharacterWidth` and `maximumCharacterWidth` must be measured or
  /// obtained from the effective font. On macOS Chromium uses a platform
  /// specific approximation (average glyph advance and font ascent); other
  /// Chromium platforms derive these metrics differently.
  static double textFieldIntrinsicInlineSize({
    required int preferredCharacterCount,
    required double averageCharacterWidth,
    required double maximumCharacterWidth,
    double spinButtonInlineSize = 0,
  }) {
    final count = preferredCharacterCount > 0
        ? preferredCharacterCount
        : defaultPreferredCharacterCount;
    final maxWidthCorrection = maximumCharacterWidth > 0
        ? maximumCharacterWidth - averageCharacterWidth
        : 0.0;
    return (averageCharacterWidth * count + maxWidthCorrection).ceilToDouble() +
        spinButtonInlineSize;
  }

  /// Returns the intrinsic content inline size for a textarea before CSS
  /// border and padding are added. Chromium includes scrollbar thickness even
  /// when no scrollbar is currently visible.
  static double textareaIntrinsicInlineSize({
    required int preferredColumnCount,
    required double averageCharacterWidth,
    required double scrollbarThickness,
  }) {
    final columns = preferredColumnCount > 0
        ? preferredColumnCount
        : defaultPreferredCharacterCount;
    return (averageCharacterWidth * columns).ceilToDouble() +
        scrollbarThickness;
  }
}

class _BlinkNumberRenderSize {
  const _BlinkNumberRenderSize(this.beforeDecimal, this.afterDecimal);

  final int beforeDecimal;
  final int afterDecimal;

  _BlinkNumberRenderSize max(_BlinkNumberRenderSize other) =>
      _BlinkNumberRenderSize(
        beforeDecimal > other.beforeDecimal
            ? beforeDecimal
            : other.beforeDecimal,
        afterDecimal > other.afterDecimal ? afterDecimal : other.afterDecimal,
      );

  int get preferredCharacterCount =>
      beforeDecimal + afterDecimal + (afterDecimal > 0 ? 1 : 0);

  factory _BlinkNumberRenderSize.fromDecimal(_BlinkDecimal value) {
    final digitCount = value.coefficient.abs().toString().length;
    final signCount = value.isNegative ? 1 : 0;
    final exponent = value.exponent;
    if (exponent >= 0) {
      return _BlinkNumberRenderSize(signCount + digitCount, 0);
    }

    final beforeDecimal = exponent + digitCount;
    if (beforeDecimal > 0) {
      return _BlinkNumberRenderSize(
        signCount + beforeDecimal,
        digitCount - beforeDecimal,
      );
    }

    return _BlinkNumberRenderSize(signCount + 1, -beforeDecimal + digitCount);
  }
}

/// The small subset of Blink's Decimal used by NumberInputType sizing.
///
/// Blink Decimal retains at most 18 significant digits. For integer digits
/// beyond that precision it shifts the exponent; extra fractional digits are
/// discarded. It preserves fractional trailing zeroes within that precision,
/// which affects NumberInputType's preferred size.
class _BlinkDecimal {
  const _BlinkDecimal(this.coefficient, this.exponent, this.isNegative);

  static const _precision = 18;
  static const _minExponent = -1023;
  static const _maxExponent = 1023;
  static const _maxDoubleCoefficient = 17976931348623157;
  static const _maxDoubleExponent = 292;
  static final one = _BlinkDecimal(BigInt.one, 0, false);
  static final zero = _BlinkDecimal(BigInt.zero, 0, false);
  static final _maxDouble = _BlinkDecimal(
    BigInt.from(_maxDoubleCoefficient),
    _maxDoubleExponent,
    false,
  );
  static final _htmlNumber = RegExp(
    r'^(-?)(?:([0-9]+)(?:\.([0-9]+))?|\.([0-9]+))'
    r'(?:[eE]([+-]?[0-9]+))?$',
  );

  final BigInt coefficient;
  final int exponent;
  final bool isNegative;

  static _BlinkDecimal? parseNumberTypeValue(String? source) {
    if (source == null || source.isEmpty) return null;

    // ParseToDecimalForNumberType rejects a leading plus and whitespace before
    // calling Decimal::FromString, even though Decimal itself accepts a plus.
    final first = source.codeUnitAt(0);
    final isDigit = first >= 0x30 && first <= 0x39;
    if (!isDigit && first != 0x2d && first != 0x2e) return null;

    final match = _htmlNumber.firstMatch(source);
    if (match == null) return null;

    final whole = match.group(2) ?? '';
    final fraction = match.group(3) ?? match.group(4) ?? '';
    final negative = match.group(1) == '-';
    var coefficient = BigInt.zero;
    var digitCount = 0;
    var fractionDigitCount = 0;
    var extraIntegerDigits = 0;
    var nonZeroIntegerSeen = false;

    // Decimal::FromString discards insignificant leading integer zeros, then
    // stores up to 18 digits and shifts any additional integer digits into the
    // exponent.
    for (final unit in whole.codeUnits) {
      final digit = unit - 0x30;
      if (!nonZeroIntegerSeen && digit == 0) continue;
      nonZeroIntegerSeen = true;
      if (digitCount < _precision) {
        digitCount++;
        coefficient = coefficient * BigInt.from(10) + BigInt.from(digit);
      } else {
        extraIntegerDigits++;
      }
    }

    // Fraction digits count toward Decimal's 18-digit precision. Digits past
    // the precision are ignored rather than shifting the exponent.
    for (final unit in fraction.codeUnits) {
      if (digitCount >= _precision) break;
      final digit = unit - 0x30;
      digitCount++;
      fractionDigitCount++;
      coefficient = coefficient * BigInt.from(10) + BigInt.from(digit);
    }

    final rawExponent = match.group(5);
    final parsedExponent = _parseExponent(rawExponent);
    if (parsedExponent == null) {
      // Blink short-circuits very large exponents to zero or infinity while
      // parsing. A zero coefficient remains a finite zero; otherwise positive
      // overflow is rejected and negative underflow normalizes to zero.
      if (coefficient == BigInt.zero) return zero;
      if (rawExponent != null && rawExponent.startsWith('-')) return zero;
      return null;
    }

    var exponent = parsedExponent - fractionDigitCount + extraIntegerDigits;
    if (coefficient == BigInt.zero || exponent < _minExponent) return zero;
    if (exponent > _maxExponent) return null;

    final result = _BlinkDecimal(coefficient, exponent, negative);
    if (_compareMagnitude(result, _maxDouble) > 0) return null;

    // ParseToDecimalForNumberType normalizes -0 to +0.
    if (result.coefficient == BigInt.zero) return zero;
    return result;
  }

  static int? _parseExponent(String? source) {
    if (source == null) return 0;
    var index = 0;
    var negative = false;
    if (source.startsWith('+') || source.startsWith('-')) {
      negative = source.startsWith('-');
      index++;
    }

    // Decimal::FromString returns zero/infinity after the explicit exponent
    // exceeds kExponentMax + kPrecision (1041).
    var value = 0;
    for (; index < source.length; index++) {
      final digit = source.codeUnitAt(index) - 0x30;
      value = value * 10 + digit;
      if (value > _maxExponent + _precision) return null;
    }
    return negative ? -value : value;
  }

  static int _compareMagnitude(_BlinkDecimal left, _BlinkDecimal right) {
    if (left.coefficient == BigInt.zero) {
      return right.coefficient == BigInt.zero ? 0 : -1;
    }
    if (right.coefficient == BigInt.zero) return 1;

    final leftDigits = left.coefficient.toString().length;
    final rightDigits = right.coefficient.toString().length;
    final leftOrder = leftDigits + left.exponent;
    final rightOrder = rightDigits + right.exponent;
    if (leftOrder != rightOrder) return leftOrder.compareTo(rightOrder);

    if (left.exponent == right.exponent) {
      return left.coefficient.compareTo(right.coefficient);
    }
    if (left.exponent > right.exponent) {
      final scaledLeft =
          left.coefficient *
          BigInt.from(10).pow(left.exponent - right.exponent);
      return scaledLeft.compareTo(right.coefficient);
    }
    final scaledRight =
        right.coefficient * BigInt.from(10).pow(right.exponent - left.exponent);
    return left.coefficient.compareTo(scaledRight);
  }
}
