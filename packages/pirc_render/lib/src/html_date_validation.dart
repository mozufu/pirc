import 'package:flutter/foundation.dart';

/// A Gregorian calendar date in the canonical HTML `yyyy-mm-dd` value format.
///
/// The year is unbounded like an HTML valid date string. [epochDays] is exact
/// integer arithmetic relative to 1970-01-01 and never passes through a local
/// timezone or a floating-point millisecond value.
@immutable
class NativeHtmlDateValue implements Comparable<NativeHtmlDateValue> {
  const NativeHtmlDateValue._({
    required this.year,
    required this.month,
    required this.day,
    required this.epochDays,
  });

  final BigInt year;
  final int month;
  final int day;
  final BigInt epochDays;

  static NativeHtmlDateValue? parse(String value) {
    final match = RegExp(
      r'^([0-9]{4,})-([0-9]{2})-([0-9]{2})$',
    ).firstMatch(value);
    if (match == null) return null;
    final year = BigInt.tryParse(match.group(1)!);
    final month = int.tryParse(match.group(2)!);
    final day = int.tryParse(match.group(3)!);
    if (year == null || year <= BigInt.zero || month == null || day == null) {
      return null;
    }
    if (month < 1 || month > 12 || day < 1 || day > _daysInMonth(year, month)) {
      return null;
    }
    return NativeHtmlDateValue._(
      year: year,
      month: month,
      day: day,
      epochDays: _daysFromCivil(year, month, day),
    );
  }

  static NativeHtmlDateValue? fromDateTime(DateTime date) => parse(
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}',
  );

  static NativeHtmlDateValue? fromEpochDays(BigInt epochDays) {
    final shifted = epochDays + BigInt.from(719468);
    final era = shifted >= BigInt.zero
        ? shifted ~/ BigInt.from(146097)
        : (shifted - BigInt.from(146096)) ~/ BigInt.from(146097);
    final dayOfEra = shifted - era * BigInt.from(146097);
    final yearOfEra =
        (dayOfEra -
            dayOfEra ~/ BigInt.from(1460) +
            dayOfEra ~/ BigInt.from(36524) -
            dayOfEra ~/ BigInt.from(146096)) ~/
        BigInt.from(365);
    var year = yearOfEra + era * BigInt.from(400);
    final dayOfYear =
        dayOfEra -
        (BigInt.from(365) * yearOfEra +
            yearOfEra ~/ BigInt.from(4) -
            yearOfEra ~/ BigInt.from(100));
    final monthPrime =
        (BigInt.from(5) * dayOfYear + BigInt.from(2)) ~/ BigInt.from(153);
    final day =
        dayOfYear -
        (BigInt.from(153) * monthPrime + BigInt.from(2)) ~/ BigInt.from(5) +
        BigInt.one;
    final month =
        monthPrime +
        (monthPrime < BigInt.from(10) ? BigInt.from(3) : BigInt.from(-9));
    if (month <= BigInt.from(2)) year += BigInt.one;
    if (year <= BigInt.zero) return null;
    return NativeHtmlDateValue._(
      year: year,
      month: month.toInt(),
      day: day.toInt(),
      epochDays: epochDays,
    );
  }

  /// Flutter's Material date picker supports years 1 through 9999.
  DateTime? toDateTime() {
    if (year < BigInt.one || year > BigInt.from(9999)) return null;
    return DateTime.utc(year.toInt(), month, day);
  }

  String get canonical =>
      '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';

  @override
  int compareTo(NativeHtmlDateValue other) =>
      epochDays.compareTo(other.epochDays);

  bool operator <(NativeHtmlDateValue other) => compareTo(other) < 0;
  bool operator <=(NativeHtmlDateValue other) => compareTo(other) <= 0;
  bool operator >(NativeHtmlDateValue other) => compareTo(other) > 0;
  bool operator >=(NativeHtmlDateValue other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is NativeHtmlDateValue && epochDays == other.epochDays;

  @override
  int get hashCode => epochDays.hashCode;

  @override
  String toString() => canonical;
}

/// The constraint-validation flags for an HTML date control.
@immutable
class NativeHtmlDateValidity {
  const NativeHtmlDateValidity({
    required this.willValidate,
    required this.valueMissing,
    required this.badInput,
    required this.rangeUnderflow,
    required this.rangeOverflow,
    required this.stepMismatch,
  });

  final bool willValidate;
  final bool valueMissing;
  final bool badInput;
  final bool rangeUnderflow;
  final bool rangeOverflow;
  final bool stepMismatch;

  bool get valid =>
      !valueMissing &&
      !badInput &&
      !rangeUnderflow &&
      !rangeOverflow &&
      !stepMismatch;
}

/// HTML date-value parsing and constraint validation.
class NativeHtmlDateValidation {
  const NativeHtmlDateValidation._();

  /// The HTML value-sanitization algorithm: invalid non-empty values become
  /// empty; valid values retain their canonical spelling.
  static String sanitize(String value) =>
      NativeHtmlDateValue.parse(value)?.canonical ?? '';

  /// Evaluates required, min, max, and step without timezone conversion.
  ///
  /// [stepBase] should be the control's valid `min`, then its valid value
  /// content attribute, then the epoch date. Supplying it lets a state object
  /// preserve that content-attribute base after a live edit changes [value].
  static NativeHtmlDateValidity evaluate({
    required String value,
    required bool required,
    required bool disabled,
    required bool readOnly,
    String? min,
    String? max,
    String? step,
    String? valueAttribute,
    NativeHtmlDateValue? stepBase,
    bool badInput = false,
  }) {
    final willValidate = !disabled && !readOnly;

    final date = NativeHtmlDateValue.parse(value);
    final sanitizedValue = date == null ? '' : value;
    final minimum = min == null ? null : NativeHtmlDateValue.parse(min);
    final maximum = max == null ? null : NativeHtmlDateValue.parse(max);
    final base =
        stepBase ??
        minimum ??
        (valueAttribute == null
            ? null
            : NativeHtmlDateValue.parse(valueAttribute));
    final baseDays = base?.epochDays ?? BigInt.zero;
    final allowedStep = _parseAllowedStep(step);
    final mismatch =
        date != null &&
        allowedStep != null &&
        !_isStepAligned(date.epochDays - baseDays, allowedStep);

    return NativeHtmlDateValidity(
      willValidate: willValidate,
      valueMissing: willValidate && required && sanitizedValue.isEmpty,
      badInput: willValidate && badInput,
      rangeUnderflow: date != null && minimum != null && date < minimum,
      rangeOverflow: date != null && maximum != null && date > maximum,
      stepMismatch: mismatch,
    );
  }

  /// Whether a valid calendar date meets only the date range and step rules.
  /// Required is deliberately excluded so an empty control can still open its
  /// picker; form submission uses [evaluate].
  static bool isSelectable({
    required NativeHtmlDateValue date,
    String? min,
    String? max,
    String? step,
    String? valueAttribute,
    NativeHtmlDateValue? stepBase,
  }) {
    final minimum = min == null ? null : NativeHtmlDateValue.parse(min);
    final maximum = max == null ? null : NativeHtmlDateValue.parse(max);
    if (minimum != null && date < minimum) return false;
    if (maximum != null && date > maximum) return false;
    final base =
        stepBase ??
        minimum ??
        (valueAttribute == null
            ? null
            : NativeHtmlDateValue.parse(valueAttribute)) ??
        NativeHtmlDateValue.parse('1970-01-01');
    final allowedStep = _parseAllowedStep(step);
    return allowedStep == null ||
        _isStepAligned(date.epochDays - base!.epochDays, allowedStep);
  }

  /// Finds the first step-aligned date inside an inclusive interval.
  static NativeHtmlDateValue? firstSelectable({
    required NativeHtmlDateValue from,
    required NativeHtmlDateValue through,
    String? min,
    String? max,
    String? step,
    String? valueAttribute,
    NativeHtmlDateValue? stepBase,
  }) {
    final minimum = min == null ? null : NativeHtmlDateValue.parse(min);
    final maximum = max == null ? null : NativeHtmlDateValue.parse(max);
    var low = from.epochDays;
    var high = through.epochDays;
    if (minimum != null && minimum.epochDays > low) low = minimum.epochDays;
    if (maximum != null && maximum.epochDays < high) high = maximum.epochDays;
    if (low > high) return null;

    final allowedStep = _parseAllowedStep(step);
    if (allowedStep == null) return NativeHtmlDateValue.fromEpochDays(low);
    final base =
        stepBase ??
        minimum ??
        (valueAttribute == null
            ? null
            : NativeHtmlDateValue.parse(valueAttribute)) ??
        NativeHtmlDateValue.parse('1970-01-01')!;
    final period =
        allowedStep.coefficient ~/
        _gcd(allowedStep.coefficient, _pow10(allowedStep.scale));
    final offset = (base.epochDays - low).remainder(period);
    final candidateDays = low + (offset.isNegative ? offset + period : offset);
    if (candidateDays > high) return null;
    return NativeHtmlDateValue.fromEpochDays(candidateDays);
  }

  static bool _isStepAligned(BigInt difference, _DateStep step) {
    final scaledDifference = difference * _pow10(step.scale);
    return scaledDifference.remainder(step.coefficient) == BigInt.zero;
  }

  static _DateStep? _parseAllowedStep(String? value) {
    if (value == 'any' || value?.toLowerCase() == 'any') return null;
    if (value == null) return _DateStep(BigInt.one, 0);

    final match = RegExp(
      r'^(-?)([0-9]+)(?:\.([0-9]*))?(?:[eE]([+-]?[0-9]+))?$',
    ).firstMatch(value);
    if (match == null) return _DateStep(BigInt.one, 0);
    final integerPart = match.group(2)!;
    final fractionalPart = match.group(3) ?? '';
    final exponent = int.tryParse(match.group(4) ?? '0');
    if (exponent == null || exponent.abs() > 308) {
      return _DateStep(BigInt.one, 0);
    }
    final parsedCoefficient = BigInt.tryParse('$integerPart$fractionalPart');
    if (parsedCoefficient == null || parsedCoefficient <= BigInt.zero) {
      return _DateStep(BigInt.one, 0);
    }
    if (match.group(1) == '-') return _DateStep(BigInt.one, 0);
    var coefficient = parsedCoefficient;
    var scale = fractionalPart.length - exponent;
    if (scale < 0) {
      coefficient *= _pow10(-scale);
      scale = 0;
    }
    if (scale > 308) return _DateStep(BigInt.one, 0);
    while (scale > 0 && coefficient.remainder(BigInt.from(10)) == BigInt.zero) {
      coefficient ~/= BigInt.from(10);
      scale--;
    }
    if (coefficient <= BigInt.zero) return _DateStep(BigInt.one, 0);
    return _DateStep(coefficient, scale);
  }

  static BigInt _pow10(int exponent) => BigInt.from(10).pow(exponent);
}

BigInt _gcd(BigInt left, BigInt right) {
  var a = left.abs();
  var b = right.abs();
  while (b != BigInt.zero) {
    final remainder = a.remainder(b);
    a = b;
    b = remainder;
  }
  return a;
}

class _DateStep {
  _DateStep(this.coefficient, this.scale);

  final BigInt coefficient;
  final int scale;
}

BigInt _daysFromCivil(BigInt year, int month, int day) {
  final adjustedYear = year - (month <= 2 ? BigInt.one : BigInt.zero);
  final era = adjustedYear ~/ BigInt.from(400);
  final yearOfEra = adjustedYear - era * BigInt.from(400);
  final monthPrime = BigInt.from(month + (month > 2 ? -3 : 9));
  final dayOfYear =
      (BigInt.from(153) * monthPrime + BigInt.from(2)) ~/ BigInt.from(5) +
      BigInt.from(day - 1);
  final dayOfEra =
      yearOfEra * BigInt.from(365) +
      yearOfEra ~/ BigInt.from(4) -
      yearOfEra ~/ BigInt.from(100) +
      dayOfYear;
  return era * BigInt.from(146097) + dayOfEra - BigInt.from(719468);
}

int _daysInMonth(BigInt year, int month) => switch (month) {
  2 => _isLeapYear(year) ? 29 : 28,
  4 || 6 || 9 || 11 => 30,
  _ => 31,
};

bool _isLeapYear(BigInt year) =>
    year.remainder(BigInt.from(4)) == BigInt.zero &&
    (year.remainder(BigInt.from(100)) != BigInt.zero ||
        year.remainder(BigInt.from(400)) == BigInt.zero);
