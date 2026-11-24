import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_form_validation.dart';

const _unsupportedPatternIds = <String>{
  'pattern-v-intersection',
  'pattern-v-subtraction',
  'pattern-v-trailing-hyphen',
};

const _fixturePath = '../../fixtures/mobile-parity/html-form-validation.json';
const _expectedPath =
    '../../fixtures/mobile-parity/html-form-validation-expected.json';

Map<String, dynamic> _map(Object? value) =>
    (value as Map<dynamic, dynamic>).cast<String, dynamic>();

HtmlValidationControl _control(
  Map<String, dynamic> field, {
  bool userEdited = false,
}) {
  final attributes = _map(field['attributes']);
  final type = field['type'] as String?;
  final kind = switch (field['tag'] as String) {
    'textarea' => HtmlValidationControlKind.textarea,
    'select' => HtmlValidationControlKind.select,
    _ => switch (type) {
      'email' => HtmlValidationControlKind.email,
      'url' => HtmlValidationControlKind.url,
      'number' => HtmlValidationControlKind.number,
      'checkbox' => HtmlValidationControlKind.checkbox,
      'radio' => HtmlValidationControlKind.radio,
      'range' => HtmlValidationControlKind.range,
      'date' => HtmlValidationControlKind.date,
      'file' => HtmlValidationControlKind.file,
      'hidden' => HtmlValidationControlKind.unsupported,
      _ => HtmlValidationControlKind.text,
    },
  };
  final disabledAttribute = field['disabledAttribute'] == true;
  final disabledByBrowser = field['disabledByBrowser'] == true;
  final rawOptions = field['options'];
  final options = rawOptions is List
      ? rawOptions.map((raw) {
          final option = _map(raw);
          return HtmlValidationOption(
            value: option['value'] as String,
            selected: option['selected'] == true,
            disabled: option['disabled'] == true,
            directChild: option['directChild'] == true,
          );
        }).toList()
      : const <HtmlValidationOption>[];
  final minLength = field['minLength'] as int?;
  final maxLength = field['maxLength'] as int?;
  final validity = _map(field['validity']);

  return HtmlValidationControl(
    id: field['id'] as String,
    kind: kind,
    value: field['value'] as String,
    name: field['name'] as String?,
    formOwner: field['formOwner'] as String?,
    valueAttribute: attributes['value'] as String?,
    required: field['required'] == true,
    checked: field['checked'] == true,
    disabled: disabledAttribute,
    disabledByFieldset: disabledByBrowser && !disabledAttribute,
    readOnly: field['readOnly'] == true,
    multiple: field['multiple'] == true,
    size: (field['size'] as int?) ?? 1,
    options: options,
    userEdited: userEdited,
    badInput: validity['badInput'] == true,
    customError: validity['customError'] == true,
    min: field['min'] as String?,
    max: field['max'] as String?,
    step: field['step'] as String?,
    pattern: field['pattern'] as String?,
    minLength: minLength != null && minLength >= 0 ? minLength : null,
    maxLength: maxLength != null && maxLength >= 0 ? maxLength : null,
  );
}

List<Map<String, dynamic>> _fieldMaps(Map<String, dynamic> snapshot) =>
    (snapshot['fields'] as List).map(_map).toList();

void _expectMatchesBrowser(
  HtmlValidationResult result,
  Map<String, dynamic> field,
) {
  final kind = _control(field).kind;
  final pattern = field['pattern'] as String?;
  if (pattern != null &&
      (_unsupportedPatternIds.contains(field['id']) ||
          pattern.contains('&&') ||
          pattern.contains('--'))) {
    expect(result.supported, isFalse, reason: field['id'] as String);
    expect(result.valid, isNull, reason: field['id'] as String);
    expect(result.willValidate, isNull, reason: field['id'] as String);
    expect(result.unsupportedReason, isNotEmpty);
    return;
  }
  if (kind == HtmlValidationControlKind.unsupported) {
    expect(result.supported, isFalse, reason: field['id'] as String);
    expect(result.valid, isNull, reason: field['id'] as String);
    expect(result.willValidate, isNull, reason: field['id'] as String);
    expect(result.unsupportedReason, isNotEmpty);
    return;
  }

  final validity = _map(field['validity']);
  final id = field['id'] as String;
  expect(result.supported, isTrue, reason: id);
  expect(
    result.willValidate,
    field['willValidate'],
    reason: '$id willValidate',
  );
  expect(result.valid, validity['valid'], reason: '$id validity.valid');
  for (final flag in HtmlValidityFlag.values) {
    expect(
      result.has(flag),
      validity[flag.name],
      reason: '$id validity.${flag.name}',
    );
  }
}

void main() {
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

  test('matches pinned sanitizer and Chromium 154 validity states', () {
    expect(expected['fixture'], fixture['id']);
    expect(expected['reference'], fixture['webRevision']);
    expect((expected['browserVersion'] as String).startsWith('154.'), isTrue);
    final initial = _map(expected['initial']);
    final fields = _fieldMaps(initial);
    expect(fields, isNotEmpty);

    final controls = fields.map(_control).toList();
    for (var index = 0; index < fields.length; index++) {
      _expectMatchesBrowser(
        HtmlFormValidation.validate(controls[index], formControls: controls),
        fields[index],
      );
    }

    final sanitizedHtml = initial['sanitizedHtml'] as String;
    expect(sanitizedHtml, contains('pattern="[A-Z]{3}"'));
    expect(sanitizedHtml, contains('minlength="3"'));
    expect(sanitizedHtml, contains('maxlength="3"'));
  });

  test('uses user-edited values for minlength and keeps maxlength capped', () {
    final initial = _fieldMaps(_map(expected['initial']));
    final actions = (expected['actions'] as List).map(_map);
    for (final action in actions) {
      final actionField = _map(action['field']);
      final editedControl = _control(actionField, userEdited: true);
      final controls =
          initial
              .where((field) => field['id'] != actionField['id'])
              .map(_control)
              .toList()
            ..add(editedControl);
      _expectMatchesBrowser(
        HtmlFormValidation.validate(editedControl, formControls: controls),
        actionField,
      );
    }

    final maximumEdit = actions.firstWhere(
      (action) => action['id'] == 'maxlength-after-user-edit',
    );
    expect(_map(maximumEdit['field'])['value'], 'abc');
    final shortEmojiEdit = actions.firstWhere(
      (action) => action['id'] == 'minlength-emoji-after-user-edit',
    );
    expect(_map(shortEmojiEdit['field'])['validity']['tooShort'], isTrue);
  });

  test('leaves Chromium v-mode set operations explicitly unsupported', () {
    final fields = _fieldMaps(_map(expected['initial']));
    for (final id in ['pattern-v-intersection', 'pattern-v-subtraction']) {
      final field = fields.firstWhere((field) => field['id'] == id);
      final validity = _map(field['validity']);
      expect(validity['patternMismatch'], isTrue);
      final result = HtmlFormValidation.validate(_control(field));
      expect(result.supported, isFalse);
      expect(result.valid, isNull);
    }

    final trailingHyphen = fields.firstWhere(
      (field) => field['id'] == 'pattern-v-trailing-hyphen',
    );
    expect(_map(trailingHyphen['validity'])['valid'], isTrue);
    final unsupportedTrailingHyphen = HtmlFormValidation.validate(
      _control(trailingHyphen),
    );
    expect(unsupportedTrailingHyphen.supported, isFalse);
    expect(unsupportedTrailingHyphen.valid, isNull);

    final invalidPattern = fields.firstWhere(
      (field) => field['id'] == 'pattern-invalid',
    );
    final ignored = HtmlFormValidation.validate(_control(invalidPattern));
    expect(ignored.supported, isTrue);
    expect(ignored.valid, isTrue);
    expect(ignored.has(HtmlValidityFlag.patternMismatch), isFalse);
  });

  test('matches Chromium email whitespace and local-part rules', () {
    final fields = _fieldMaps(_map(expected['initial']));
    Map<String, dynamic> field(String id) =>
        fields.firstWhere((candidate) => candidate['id'] == id);

    for (final id in [
      'email-dot-leading',
      'email-dot-trailing',
      'email-dot-repeated',
      'email-local-dot',
    ]) {
      final candidate = field(id);
      expect(_map(candidate['validity'])['valid'], isTrue, reason: id);
      expect(HtmlFormValidation.validate(_control(candidate)).valid, isTrue);
    }

    expect(field('email-ascii-whitespace')['value'], 'ada@example.com');
    expect(
      field('email-multiple-ascii-whitespace')['value'],
      'ada@example.com,bob@example.com',
    );
    for (final id in [
      'email-unicode-whitespace-leading',
      'email-unicode-whitespace-trailing',
      'email-multiple-unicode-whitespace',
    ]) {
      final candidate = field(id);
      expect(_map(candidate['validity'])['typeMismatch'], isTrue, reason: id);
      expect(
        HtmlFormValidation.validate(
          _control(candidate),
        ).has(HtmlValidityFlag.typeMismatch),
        isTrue,
        reason: id,
      );
    }
  });

  test('uses Chromium full-match and per-address email pattern semantics', () {
    final fields = _fieldMaps(_map(expected['initial']));
    for (final id in [
      'pattern-alternation-backtrack',
      'email-multiple-pattern',
    ]) {
      final field = fields.firstWhere((candidate) => candidate['id'] == id);
      expect(_map(field['validity'])['patternMismatch'], isFalse, reason: id);
      expect(
        HtmlFormValidation.validate(
          _control(field),
        ).has(HtmlValidityFlag.patternMismatch),
        isFalse,
        reason: id,
      );
    }
  });

  test('does not group radios across forms or tree scopes', () {
    final required = HtmlValidationControl(
      id: 'required',
      kind: HtmlValidationControlKind.radio,
      value: 'on',
      name: 'choice',
      formOwner: 'first-form',
      required: true,
    );
    final otherForm = HtmlValidationControl(
      id: 'other-form',
      kind: HtmlValidationControlKind.radio,
      value: 'on',
      name: 'choice',
      formOwner: 'second-form',
      checked: true,
    );
    final result = HtmlFormValidation.validate(
      required,
      formControls: [required, otherForm],
    );
    expect(result.has(HtmlValidityFlag.valueMissing), isTrue);

    final otherTree = HtmlValidationControl(
      id: 'other-tree',
      kind: HtmlValidationControlKind.radio,
      value: 'on',
      name: 'choice',
      formOwner: 'first-form',
      treeScope: 'shadow-root',
      checked: true,
    );
    final treeResult = HtmlFormValidation.validate(
      required,
      formControls: [required, otherTree],
    );
    expect(treeResult.has(HtmlValidityFlag.valueMissing), isTrue);
  });

  test('uses exact decimal step arithmetic and authored step base', () {
    final aligned = HtmlValidationControl(
      id: 'aligned',
      kind: HtmlValidationControlKind.number,
      value: '0.3',
      min: '0.1',
      step: '0.2',
    );
    final mismatched = HtmlValidationControl(
      id: 'mismatched',
      kind: HtmlValidationControlKind.number,
      value: '0.4',
      min: '0.1',
      step: '0.2',
    );
    final valueAttributeBase = HtmlValidationControl(
      id: 'attribute-base',
      kind: HtmlValidationControlKind.number,
      value: '1.5',
      valueAttribute: '0.5',
    );
    expect(
      HtmlFormValidation.validate(aligned).has(HtmlValidityFlag.stepMismatch),
      isFalse,
    );
    expect(
      HtmlFormValidation.validate(
        mismatched,
      ).has(HtmlValidityFlag.stepMismatch),
      isTrue,
    );
    expect(
      HtmlFormValidation.validate(
        valueAttributeBase,
      ).has(HtmlValidityFlag.stepMismatch),
      isFalse,
    );
  });

  test('validates required date and file controls', () {
    for (final kind in [
      HtmlValidationControlKind.date,
      HtmlValidationControlKind.file,
    ]) {
      final result = HtmlFormValidation.validate(
        HtmlValidationControl(
          id: kind.name,
          kind: kind,
          value: '',
          required: true,
        ),
      );
      expect(result.supported, isTrue);
      expect(result.valid, isFalse);
      expect(result.willValidate, isTrue);
      expect(result.has(HtmlValidityFlag.valueMissing), isTrue);
    }
  });
}
