import 'render_l10n.dart';
import 'html_date_validation.dart';

/// Pure HTML constraint validation for supported form controls.
///
/// This data-only module does not parse markup, submit forms, or display browser
/// UI. Callers should resolve disabled-fieldset ancestry and pass that state in
/// disabledByFieldset; descendants of a disabled fieldset are disabled except
/// descendants of its first legend child. Include related radios in formControls.
enum HtmlValidationControlKind {
  text,
  textarea,
  email,
  url,
  number,
  checkbox,
  radio,
  range,
  select,

  date,
  file,

  /// Any form-control type outside this module's supported validation subset.
  unsupported,
}

/// Relevant state of an option in a select element.
final class HtmlValidationOption {
  const HtmlValidationOption({
    required this.value,
    this.selected = false,
    this.disabled = false,
    this.directChild = true,
  });

  final String value;
  final bool selected;
  final bool disabled;

  /// False for options nested in optgroup.
  final bool directChild;
}

/// Immutable current state for one HTML control.
///
/// value is the current DOM-like value after type-specific sanitization.
/// valueAttribute is kept separately because number/range step alignment uses
/// it as the fallback step base after min.
final class HtmlValidationControl {
  HtmlValidationControl({
    required this.id,
    required this.kind,
    required this.value,
    this.name,
    this.formOwner,
    this.treeScope = 'document',
    this.valueAttribute,
    this.required = false,
    this.checked = false,
    this.selectedFileCount = 0,
    this.disabled = false,
    this.disabledByFieldset = false,
    this.readOnly = false,
    this.multiple = false,
    this.size = 1,
    Iterable<HtmlValidationOption> options = const [],
    this.userEdited = false,
    this.badInput = false,
    this.customError = false,
    this.min,
    this.max,
    this.step,
    this.pattern,
    this.minLength,
    this.maxLength,
  }) : options = List.unmodifiable(options);

  /// Unique identity within the current form/tree. Used for ungrouped radios.
  final String id;
  final HtmlValidationControlKind kind;
  final String value;
  final String? name;
  final String? formOwner;

  /// Radio groups do not cross tree scopes.
  final String treeScope;

  /// Raw authored value attribute, used only as the numeric step-base fallback.
  final String? valueAttribute;

  final bool required;
  final bool checked;

  /// Current FileList length; value attributes never select files.
  final int selectedFileCount;
  final bool disabled;

  /// Pre-resolved disabled-fieldset state, including the first-legend rule.
  final bool disabledByFieldset;

  final bool readOnly;
  final bool multiple;

  /// Select display size. HTML defaults to 1.
  final int size;

  /// Current option selectedness and structure for select validation.
  final List<HtmlValidationOption> options;

  /// True after a user edit event. Initial markup and programmatic assignments
  /// alone do not make minlength/maxlength constraints apply in Chromium.
  final bool userEdited;

  /// Browser state for an incomplete localized number token.
  final bool badInput;
  final bool customError;

  final String? min;
  final String? max;
  final String? step;
  final String? pattern;
  final int? minLength;
  final int? maxLength;
}

enum HtmlValidityFlag {
  badInput,
  customError,
  patternMismatch,
  rangeOverflow,
  rangeUnderflow,
  stepMismatch,
  tooLong,
  tooShort,
  typeMismatch,
  valueMissing,
}

final class HtmlValidationResult {
  HtmlValidationResult._({
    required this.supported,
    required this.willValidate,
    required this.valid,
    required Set<HtmlValidityFlag> flags,
    this.unsupportedReason,
  }) : flags = Set.unmodifiable(flags);

  /// False means the caller must not treat this control as valid.
  final bool supported;

  /// Null when validation for the control kind is unsupported.
  final bool? willValidate;

  /// Null when validation for the control kind is unsupported.
  final bool? valid;

  final Set<HtmlValidityFlag> flags;
  final String? unsupportedReason;

  bool has(HtmlValidityFlag flag) => flags.contains(flag);

  factory HtmlValidationResult.unsupported(String reason) =>
      HtmlValidationResult._(
        supported: false,
        willValidate: null,
        valid: null,
        flags: const {},
        unsupportedReason: reason,
      );
}

/// Evaluates supported HTML constraint-validation rules.
///
/// This module uses current values, not authored attributes alone. In
/// particular, callers must pass all form controls when evaluating radios,
/// preserve valueAttribute for step base, supply userEdited for length rules,
/// and resolve fieldset ancestry before calling validate. Unsupported kinds
/// return an explicit unsupported result rather than valid=true.
abstract final class HtmlFormValidation {
  static HtmlValidationResult validate(
    HtmlValidationControl control, {
    Iterable<HtmlValidationControl> formControls = const [],
  }) {
    if (control.kind == HtmlValidationControlKind.unsupported) {
      return HtmlValidationResult.unsupported(
        tr("Unsupported HTML control kind: {0}", [control.kind.name]),
      );
    }

    if (control.kind == HtmlValidationControlKind.date) {
      final date = NativeHtmlDateValidation.evaluate(
        value: control.value,
        required: control.required,
        disabled: control.disabled || control.disabledByFieldset,
        readOnly: control.readOnly,
        min: control.min,
        max: control.max,
        step: control.step,
        valueAttribute: control.valueAttribute,
        badInput: control.badInput,
      );
      final flags = <HtmlValidityFlag>{
        if (date.valueMissing) HtmlValidityFlag.valueMissing,
        if (date.badInput) HtmlValidityFlag.badInput,
        if (date.rangeUnderflow) HtmlValidityFlag.rangeUnderflow,
        if (date.rangeOverflow) HtmlValidityFlag.rangeOverflow,
        if (date.stepMismatch) HtmlValidityFlag.stepMismatch,
        if (control.customError) HtmlValidityFlag.customError,
      };
      return HtmlValidationResult._(
        supported: true,
        willValidate: date.willValidate,
        valid: flags.isEmpty,
        flags: flags,
      );
    }
    if (control.kind == HtmlValidationControlKind.file) {
      final flags = <HtmlValidityFlag>{
        if (control.required && control.selectedFileCount == 0)
          HtmlValidityFlag.valueMissing,
        if (control.customError) HtmlValidityFlag.customError,
      };
      return HtmlValidationResult._(
        supported: true,
        willValidate: !control.disabled && !control.disabledByFieldset,
        valid: flags.isEmpty,
        flags: flags,
      );
    }

    final barred =
        control.disabled ||
        control.disabledByFieldset ||
        (control.readOnly && _supportsReadOnly(control.kind));
    // Chromium preserves a required select's valueMissing state even when the
    // select is disabled; willValidate still tells form submission to skip it.
    if (barred && control.kind != HtmlValidationControlKind.select) {
      return HtmlValidationResult._(
        supported: true,
        willValidate: false,
        valid: true,
        flags: const {},
      );
    }

    final flags = <HtmlValidityFlag>{};
    if (control.badInput) flags.add(HtmlValidityFlag.badInput);
    if (control.customError) flags.add(HtmlValidityFlag.customError);

    if (control.kind == HtmlValidationControlKind.radio) {
      final group = _radioGroup(control, formControls);
      if (group.any((member) => member.required) &&
          !group.any((member) => member.checked)) {
        flags.add(HtmlValidityFlag.valueMissing);
      }
    } else if (control.required) {
      if (control.kind == HtmlValidationControlKind.checkbox) {
        if (!control.checked) flags.add(HtmlValidityFlag.valueMissing);
      } else if (control.kind == HtmlValidationControlKind.select) {
        if (_selectValueMissing(control)) {
          flags.add(HtmlValidityFlag.valueMissing);
        }
      } else if (control.value.isEmpty) {
        flags.add(HtmlValidityFlag.valueMissing);
      }
    }

    if (control.kind == HtmlValidationControlKind.email &&
        control.value.isNotEmpty &&
        !_validEmailValue(control.value, multiple: control.multiple)) {
      flags.add(HtmlValidityFlag.typeMismatch);
    } else if (control.kind == HtmlValidationControlKind.url &&
        control.value.isNotEmpty) {
      final urlValidity = _validUrlValue(control.value);
      if (urlValidity == null) {
        return HtmlValidationResult.unsupported(
          tr("URL syntax is outside the supported parser subset: {0}", [
            control.value,
          ]),
        );
      }
      if (!urlValidity) flags.add(HtmlValidityFlag.typeMismatch);
    }

    if (_supportsPattern(control.kind) &&
        control.pattern != null &&
        control.value.isNotEmpty) {
      if (_hasUnsupportedVPatternSyntax(control.pattern!)) {
        return HtmlValidationResult.unsupported(
          tr(
            "Pattern requires JavaScript Unicode-sets v syntax not modeled by Dart RegExp: {0}",
            [control.pattern!],
          ),
        );
      }
      final pattern = control.pattern!;
      if (!_obviouslyInvalidPattern(pattern)) {
        try {
          final expression = RegExp('^(?:$pattern)\$', unicode: true);
          final values = control.kind == HtmlValidationControlKind.email
              ? (control.multiple ? control.value.split(',') : [control.value])
                    .map(_trimAsciiWhitespace)
              : [control.value];
          if (values.any((value) => !expression.hasMatch(value))) {
            flags.add(HtmlValidityFlag.patternMismatch);
          }
        } on FormatException {
          // Chromium ignores an invalid pattern attribute. V-only operators
          // are detected above and returned as unsupported instead.
        } on ArgumentError {
          // See the FormatException case above.
        }
      }
    }

    if (_supportsLength(control.kind) &&
        control.value.isNotEmpty &&
        control.userEdited) {
      final minLength = control.minLength;
      if (minLength != null &&
          minLength >= 0 &&
          control.value.length < minLength) {
        flags.add(HtmlValidityFlag.tooShort);
      }
      final maxLength = control.maxLength;
      if (maxLength != null &&
          maxLength >= 0 &&
          control.value.length > maxLength) {
        flags.add(HtmlValidityFlag.tooLong);
      }
    }

    if (_supportsNumericConstraints(control.kind) && control.value.isNotEmpty) {
      final value = _Decimal.parse(control.value);
      if (value != null) {
        final min = _Decimal.parse(control.min);
        final max = _Decimal.parse(control.max);
        if (min != null && value.compareTo(min) < 0) {
          flags.add(HtmlValidityFlag.rangeUnderflow);
        }
        if (max != null && value.compareTo(max) > 0) {
          flags.add(HtmlValidityFlag.rangeOverflow);
        }

        if (!_stepIsAny(control.step)) {
          final step = _validStep(control.step);
          final base =
              min ?? _Decimal.parse(control.valueAttribute) ?? _Decimal.zero;
          if (step != null && !_isStepAligned(value, base, step)) {
            flags.add(HtmlValidityFlag.stepMismatch);
          }
        }
      }
    }

    return HtmlValidationResult._(
      supported: true,
      willValidate: !barred,
      valid: flags.isEmpty,
      flags: flags,
    );
  }

  static bool _selectValueMissing(HtmlValidationControl control) {
    final selected = control.options
        .where((option) => option.selected)
        .toList();
    if (selected.isEmpty) return true;

    if (!control.multiple && control.size == 1 && control.options.isNotEmpty) {
      final first = control.options.first;
      final isPlaceholder = first.directChild && first.value.isEmpty;
      if (isPlaceholder && selected.any((option) => identical(option, first))) {
        return true;
      }
    }
    return false;
  }

  static List<HtmlValidationControl> _radioGroup(
    HtmlValidationControl control,
    Iterable<HtmlValidationControl> formControls,
  ) {
    if (control.kind != HtmlValidationControlKind.radio) return [control];
    final name = control.name;
    if (name == null || name.isEmpty) return [control];

    final members = <HtmlValidationControl>[control];
    for (final candidate in formControls) {
      if (identical(candidate, control) ||
          candidate.kind != HtmlValidationControlKind.radio ||
          candidate.name != name ||
          candidate.formOwner != control.formOwner ||
          candidate.treeScope != control.treeScope) {
        continue;
      }
      if (!members.any((member) => identical(member, candidate))) {
        members.add(candidate);
      }
    }
    return members;
  }

  static bool _supportsReadOnly(HtmlValidationControlKind kind) =>
      switch (kind) {
        HtmlValidationControlKind.text ||
        HtmlValidationControlKind.textarea ||
        HtmlValidationControlKind.email ||
        HtmlValidationControlKind.url ||
        HtmlValidationControlKind.number ||
        HtmlValidationControlKind.range => true,
        HtmlValidationControlKind.checkbox ||
        HtmlValidationControlKind.radio ||
        HtmlValidationControlKind.select ||
        HtmlValidationControlKind.date ||
        HtmlValidationControlKind.file ||
        HtmlValidationControlKind.unsupported => false,
      };

  static bool _supportsPattern(HtmlValidationControlKind kind) =>
      switch (kind) {
        HtmlValidationControlKind.text ||
        HtmlValidationControlKind.email ||
        HtmlValidationControlKind.url => true,
        HtmlValidationControlKind.textarea ||
        HtmlValidationControlKind.number ||
        HtmlValidationControlKind.checkbox ||
        HtmlValidationControlKind.radio ||
        HtmlValidationControlKind.range ||
        HtmlValidationControlKind.select ||
        HtmlValidationControlKind.date ||
        HtmlValidationControlKind.file ||
        HtmlValidationControlKind.unsupported => false,
      };

  static bool _supportsLength(HtmlValidationControlKind kind) => switch (kind) {
    HtmlValidationControlKind.text ||
    HtmlValidationControlKind.textarea ||
    HtmlValidationControlKind.email ||
    HtmlValidationControlKind.url => true,
    HtmlValidationControlKind.number ||
    HtmlValidationControlKind.checkbox ||
    HtmlValidationControlKind.radio ||
    HtmlValidationControlKind.range ||
    HtmlValidationControlKind.select ||
    HtmlValidationControlKind.date ||
    HtmlValidationControlKind.file ||
    HtmlValidationControlKind.unsupported => false,
  };

  static bool _supportsNumericConstraints(HtmlValidationControlKind kind) =>
      kind == HtmlValidationControlKind.number ||
      kind == HtmlValidationControlKind.range;

  static bool _stepIsAny(String? rawStep) => rawStep?.toLowerCase() == 'any';

  static _Decimal? _validStep(String? rawStep) {
    final parsed = _Decimal.parse(rawStep);
    if (parsed == null || parsed.compareTo(_Decimal.zero) <= 0) {
      return _Decimal.one;
    }
    return parsed;
  }

  static bool _isStepAligned(_Decimal value, _Decimal base, _Decimal step) {
    final differenceNumerator =
        (value.numerator * base.denominator -
            base.numerator * value.denominator) *
        step.denominator;
    final differenceDenominator =
        value.denominator * base.denominator * step.numerator;
    if (differenceDenominator == BigInt.zero) return true;
    return differenceNumerator % differenceDenominator == BigInt.zero;
  }

  static bool _validEmailValue(String value, {required bool multiple}) {
    final addresses = (multiple ? value.split(',') : [value])
        .map(_trimAsciiWhitespace)
        .toList();
    if (addresses.isEmpty) return false;
    return addresses.every(_validEmailAddress);
  }

  static String _trimAsciiWhitespace(String value) {
    var start = 0;
    var end = value.length;
    while (start < end && _isAsciiWhitespace(value.codeUnitAt(start))) {
      start++;
    }
    while (end > start && _isAsciiWhitespace(value.codeUnitAt(end - 1))) {
      end--;
    }
    return value.substring(start, end);
  }

  static bool _isAsciiWhitespace(int unit) =>
      unit == 0x09 ||
      unit == 0x0a ||
      unit == 0x0c ||
      unit == 0x0d ||
      unit == 0x20;

  static bool _validEmailAddress(String address) {
    final separator = address.indexOf('@');
    if (separator <= 0 || separator != address.lastIndexOf('@')) return false;
    final local = address.substring(0, separator);
    final domain = address.substring(separator + 1);
    if (domain.isEmpty) return false;
    if (!RegExp(r"^[A-Za-z0-9.!#$%&'*+/=?^_\x60{|}~-]+$").hasMatch(local)) {
      return false;
    }
    final labels = domain.split('.');
    if (labels.any((label) => label.isEmpty || label.length > 63)) return false;
    return labels.every(
      (label) =>
          RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$').hasMatch(label),
    );
  }

  static bool? _validUrlValue(String value) {
    if (RegExp(r'[\u0000-\u0008\u000e-\u001f\u007f]').hasMatch(value)) {
      return false;
    }
    final schemeColon = value.indexOf(':');
    if (schemeColon <= 0) return false;
    final scheme = value.substring(0, schemeColon).toLowerCase();
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*$').hasMatch(scheme)) return false;
    final rest = value.substring(schemeColon + 1);
    if (rest.isEmpty) return false;

    const specialSchemes = {'http', 'https', 'ftp', 'ws', 'wss'};
    if (specialSchemes.contains(scheme)) {
      final slashNormalized = rest.replaceAll(String.fromCharCode(0x5c), '/');
      final body = slashNormalized.replaceFirst(RegExp(r'^/+'), '');
      if (body.isEmpty) return false;
      final authority = body.split(RegExp(r'[/?#]')).first;
      if (authority.isEmpty || authority.contains(' ')) return false;
      if (authority.contains('%')) return null;
      final uri = Uri.tryParse(
        '$scheme://${_escapeUrlSpacesAndPercents(body)}',
      );
      if (uri == null) return false;
      if (!uri.hasAuthority || uri.host.isEmpty) return false;
      return true;
    }

    final uri = Uri.tryParse(_escapeUrlSpacesAndPercents(value));
    if (uri == null) return null;
    return uri.hasScheme;
  }

  static String _escapeUrlSpacesAndPercents(String value) {
    final result = StringBuffer();
    for (var index = 0; index < value.length; index++) {
      final unit = value.codeUnitAt(index);
      if (unit == 0x20) {
        result.write('%20');
      } else if (unit == 0x25 &&
          (index + 2 >= value.length ||
              !_isHex(value.codeUnitAt(index + 1)) ||
              !_isHex(value.codeUnitAt(index + 2)))) {
        result.write('%25');
      } else {
        result.writeCharCode(unit);
      }
    }
    return result.toString();
  }

  static bool _isHex(int unit) =>
      (unit >= 0x30 && unit <= 0x39) ||
      (unit >= 0x41 && unit <= 0x46) ||
      (unit >= 0x61 && unit <= 0x66);

  static bool _hasUnsupportedVPatternSyntax(String pattern) {
    var escaped = false;
    var inClass = false;
    for (var index = 0; index < pattern.length; index++) {
      final character = pattern[index];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (character.codeUnitAt(0) == 0x5c) {
        escaped = true;
        continue;
      }
      if (character == '[') {
        if (inClass) return true;
        inClass = true;
        continue;
      }
      if (character == ']') {
        inClass = false;
        continue;
      }
      if (inClass) {
        final atClassStart = index > 0 && pattern[index - 1] == '[';
        final atClassEnd =
            index + 1 < pattern.length && pattern[index + 1] == ']';
        if (character == '-' && (atClassStart || atClassEnd)) return true;
        if (index + 1 < pattern.length) {
          final pair = pattern.substring(index, index + 2);
          if (pair == '&&' || pair == '--') return true;
        }
      }
    }
    return pattern.contains(r'\q{');
  }

  static bool _obviouslyInvalidPattern(String pattern) {
    var escaped = false;
    var inClass = false;
    for (var index = 0; index < pattern.length; index++) {
      final character = pattern[index];
      if (escaped) {
        escaped = false;
      } else if (character.codeUnitAt(0) == 0x5c) {
        escaped = true;
      } else if (character == '[') {
        inClass = true;
      } else if (character == ']' && inClass) {
        inClass = false;
      }
    }
    return escaped || inClass;
  }
}

/// Exact decimal arithmetic for number/range min, max and step constraints.
final class _Decimal implements Comparable<_Decimal> {
  const _Decimal._(this.numerator, this.denominator);

  static final zero = _Decimal._(BigInt.zero, BigInt.one);
  static final one = _Decimal._(BigInt.one, BigInt.one);

  final BigInt numerator;
  final BigInt denominator;

  static final RegExp _syntax = RegExp(
    r'^(-)?(?:(\d+)(?:\.(\d+))?|\.(\d+))(?:[eE]([+-]?\d+))?$',
  );

  static _Decimal? parse(String? source) {
    if (source == null || source.isEmpty || source.length > 512) return null;
    final match = _syntax.firstMatch(source);
    if (match == null) return null;

    final whole = match.group(2) ?? '';
    final fraction = match.group(3) ?? match.group(4) ?? '';
    final exponent = int.tryParse(match.group(5) ?? '0');
    if (exponent == null || exponent.abs() > 512) return null;

    final digits = whole + fraction;
    var numerator = BigInt.parse(digits);
    if (match.group(1) == '-') numerator = -numerator;

    final scale = fraction.length - exponent;
    var denominator = BigInt.one;
    if (scale > 0) {
      denominator = BigInt.from(10).pow(scale);
    } else if (scale < 0) {
      numerator *= BigInt.from(10).pow(-scale);
    }

    final divisor = numerator.abs().gcd(denominator);
    return _Decimal._(numerator ~/ divisor, denominator ~/ divisor);
  }

  @override
  int compareTo(_Decimal other) =>
      (numerator * other.denominator).compareTo(other.numerator * denominator);
}
