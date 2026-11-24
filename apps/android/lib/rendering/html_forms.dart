import 'render_l10n.dart';
import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import 'html_buttons.dart';
import 'html_date.dart';
import 'html_file.dart';
import 'html_controls.dart';
import 'html_form_submission.dart';
import 'html_form_validation.dart';
import 'html_range.dart';
import 'html_select.dart';
import 'html_text_fields.dart';

/// Reads current native control state. Browser navigation and rendering its
/// response are delegated to the document's typed submission callback.
class NativeHtmlForms extends ChangeNotifier {
  NativeHtmlForms({
    required String source,
    required this.textFields,
    required this.controls,
    required this.ranges,
    required this.selects,
    required this.buttons,
    this.dates,
    this.files,
    this.onSubmit,
    this.onSubmitEvent,
    this.onRequestSubmit,
  }) : _document = html.parseFragment(source) {
    for (final element in _document.querySelectorAll('*')) {
      final id = element.attributes['id'];
      if (id != null) _firstById.putIfAbsent(id, () => element);
      if (element.localName == 'form') {
        _formKeys[element] = 'form-${_formKeys.length}';
      }
    }
    _fields = _document.querySelectorAll('input,textarea,select');
    for (final state in [
      textFields,
      controls,
      ranges,
      selects,
      ?dates,
      ?files,
    ]) {
      state.addListener(dismiss);
    }
    textFields.onSubmit = implicitSubmit;
    dates?.onSubmit = implicitSubmit;
  }

  final dom.DocumentFragment _document;
  final NativeHtmlTextFieldState textFields;
  final NativeHtmlControlState controls;
  final NativeHtmlRangeState ranges;
  final NativeHtmlSelectState selects;
  final NativeHtmlButtonState buttons;
  final NativeHtmlDateState? dates;
  final NativeHtmlFileInputState? files;
  ValueChanged<NativeHtmlFormSubmission>? onSubmit;
  Future<bool> Function(dom.Element form, dom.Element? submitter)?
  onSubmitEvent;
  Future<void> Function(dom.Element form, dom.Element? submitter)?
  onRequestSubmit;
  final Map<String, dom.Element> _firstById = {};
  final Map<dom.Element, String> _formKeys = {};
  late final List<dom.Element> _fields;
  final Map<String, GlobalKey> _anchors = {};
  final GlobalKey documentAnchor = GlobalKey();
  String? message;
  String? invalidKey;
  HtmlValidationResult? invalidResult;
  bool _disposed = false;

  String? keyFor(dom.Element element) =>
      textFields.resolveControl(element)?.key ??
      controls.resolveControl(element)?.key ??
      ranges.resolveControl(element)?.key ??
      selects.resolveControl(element)?.key ??
      dates?.resolveControl(element)?.key ??
      files?.resolveControl(element)?.key;

  GlobalKey? anchorFor(dom.Element element) {
    final key = keyFor(element);
    return key == null ? null : _anchors.putIfAbsent(key, () => GlobalKey());
  }

  GlobalKey get activeAnchor => _anchors[invalidKey] ?? documentAnchor;

  dom.Element? _owner(dom.Element element) {
    if (element.attributes.containsKey('form')) {
      final target = _firstById[element.attributes['form']];
      return target?.localName == 'form' ? target : null;
    }
    for (var p = element.parent; p != null; p = p.parent) {
      if (p.localName == 'form') return p;
    }
    return null;
  }

  List<dom.Element> _owned(dom.Element form) =>
      _fields.where((e) => identical(_owner(e), form)).toList();

  /// Constraint state for a DOM ID, using live edits and native group state.
  HtmlValidationResult? validityForId(String id) {
    final element = _firstById[id];
    if (element == null || !_fields.contains(element)) return null;
    final owner = _owner(element);
    return HtmlFormValidation.validate(
      _snapshot(element),
      formControls:
          (owner == null
                  ? _fields.where((e) => _owner(e) == null)
                  : _owned(owner))
              .map(_snapshot),
    );
  }

  dom.Element? formForButton(dom.Element clicked) {
    final key = buttons.resolveControl(clicked)?.key;
    if (key == null) return null;
    final button = _document
        .querySelectorAll('button,input')
        .where((element) => buttons.resolveControl(element)?.key == key)
        .firstOrNull;
    return button == null ? null : _owner(button);
  }

  /// Declarative default submit action after a real button activation.
  void submitButton(dom.Element clicked) {
    final key = buttons.resolveControl(clicked)?.key;
    if (key == null) return;
    final submitter = _document
        .querySelectorAll('button,input')
        .where((e) => buttons.resolveControl(e)?.key == key)
        .firstOrNull;
    final form = submitter == null ? null : _owner(submitter);
    if (form == null || _disabled(submitter!)) return;
    _submit(form, submitter);
  }

  /// Enter uses the first submit button, including a disabled default button.
  /// Without a submit button, only a form with <=1 blocking input may submit.
  void implicitSubmit(String fieldKey) {
    final field = _fields.where((e) => keyFor(e) == fieldKey).firstOrNull;
    if (field == null || field.localName == 'textarea') return;
    final form = _owner(field);
    if (form == null) return;
    final submitter = _document.querySelectorAll('button,input').where((e) {
      if (!identical(_owner(e), form)) return false;
      final type = (e.attributes['type'] ?? '').toLowerCase();
      return e.localName == 'button'
          ? !const {'button', 'reset'}.contains(type)
          : const {'submit', 'image'}.contains(type);
    }).firstOrNull;
    if (submitter != null) {
      if (_disabled(submitter)) return;
      final button = buttons.resolveControl(submitter);
      if (button == null) {
        _show(
          null,
          tr("This form uses a submit control that is not yet supported."),
        );
        return;
      }
      // Run copy/default activation through the same path as pointer/Space.
      buttons.activate(button.key, implicit: true);
      return;
    }
    const blocking = {
      '',
      'text',
      'search',
      'url',
      'tel',
      'email',
      'password',
      'date',
      'month',
      'week',
      'time',
      'datetime-local',
      'number',
    };
    final count = _owned(form)
        .where(
          (e) =>
              e.localName == 'input' &&
              blocking.contains((e.attributes['type'] ?? '').toLowerCase()),
        )
        .length;
    if (count <= 1) _submit(form, null);
  }

  /// Script validation uses the same sanitized input and edit metadata.
  Map<String, dynamic> scriptControlState(dom.Element control) {
    final snapshot = _snapshot(control);
    return {
      'value': snapshot.value,
      'userEdited': snapshot.userEdited,
      'badInput': snapshot.badInput,
    };
  }

  void showScriptInvalid(String controlId, String message) {
    if (_disposed) return;
    final control = _fields
        .where(
          (element) => element.attributes['data-pirc-script-id'] == controlId,
        )
        .firstOrNull;
    if (control == null || _disabled(control)) return;
    _show(keyFor(control), message);
    _focus(control);
  }

  void showScriptError(String message) {
    if (!_disposed) _show(null, message);
  }

  void submitScriptForm(String formId, String? submitterId) {
    if (_disposed) return;
    final form = _document
        .querySelectorAll('form')
        .where((e) => e.attributes['data-pirc-script-id'] == formId)
        .firstOrNull;
    if (form == null) return;
    final submitter = submitterId == null
        ? null
        : _document
              .querySelectorAll('button,input')
              .where(
                (e) =>
                    e.attributes['data-pirc-script-id'] == submitterId &&
                    identical(_owner(e), form),
              )
              .firstOrNull;
    _submit(form, submitter, afterScript: true);
  }

  Future<void> _submit(
    dom.Element form,
    dom.Element? submitter, {
    bool afterScript = false,
  }) async {
    if (_disposed) return;
    final scriptedRequest = onRequestSubmit;
    if (!afterScript && scriptedRequest != null) {
      await scriptedRequest(form, submitter);
      return;
    }
    dismiss();
    final elements = _owned(form);
    final snapshots = elements.map(_snapshot).toList();
    final skipValidation =
        form.attributes.containsKey('novalidate') ||
        (submitter?.attributes.containsKey('formnovalidate') ?? false);
    if (!afterScript && !skipValidation) {
      // Hidden input and disabled controls never participate in validation.
      // Unsupported enabled control types must not be silently judged valid.
      for (var i = 0; i < elements.length; i++) {
        final element = elements[i];
        if (_disabled(element) ||
            const {
              'hidden',
              'button',
              'reset',
              'submit',
              'image',
            }.contains(_type(element))) {
          continue;
        }
        final result = HtmlFormValidation.validate(
          snapshots[i],
          formControls: snapshots,
        );
        if (!result.supported) {
          _show(
            keyFor(element),
            buttons.locale.languageCode == 'zh'
                ? tr("此表單使用尚未支援的內容，無法送出。")
                : tr("This form uses content that is not yet supported."),
            result,
          );
          return;
        }
        if (result.willValidate == true && result.valid == false) {
          _show(
            keyFor(element),
            _validationMessage(
              result,
              element,
              buttons.locale,
              snapshots[i].value,
            ),
            result,
          );
          _focus(element);
          return;
        }
      }
    }
    final callback = onSubmitEvent;
    if (!afterScript &&
        callback != null &&
        form.attributes.containsKey('data-pirc-script-id')) {
      final prevented = await callback(form, submitter);
      if (_disposed || prevented) return;
    }
    final entries = <NativeHtmlFormEntry>[];
    for (final element in elements) {
      if (_disabled(element)) continue;
      final name = element.attributes['name'];
      if (name == null || name.isEmpty) continue;
      if (element.attributes.containsKey('dirname')) {
        _show(
          keyFor(element),
          tr("Directional form entries are not yet supported."),
        );
        return;
      }
      final type = _type(element);
      if (const {'submit', 'reset', 'button', 'image'}.contains(type)) continue;
      if ((type == 'file' && files?.resolveControl(element) == null) ||
          (type != 'hidden' &&
              snapshots[elements.indexOf(element)].kind ==
                  HtmlValidationControlKind.unsupported)) {
        _show(
          keyFor(element),
          tr("This form includes a control that is not yet supported."),
        );
        return;
      }
      final file = files?.resolveControl(element);
      if (file != null) {
        final selected = files!.filesFor(file.key);
        if (selected.isEmpty) {
          entries.add(NativeHtmlFormEntry.file(name));
        } else {
          entries.addAll(
            selected.map((f) => NativeHtmlFormEntry.file(name, file: f)),
          );
        }
        continue;
      }
      final check = controls.resolveControl(element);
      if (check != null && !controls.isChecked(check.key)) continue;
      final select = selects.resolveControl(element);
      if (select != null) {
        for (final i in selects.selectedIndices(select.key)) {
          final option = select.options[i];
          if (!option.disabled) {
            entries.add(NativeHtmlFormEntry(name, option.value));
          }
        }
      } else {
        final value = type == 'hidden'
            ? (name == '_charset_'
                  ? 'UTF-8'
                  : element.attributes['value'] ?? '')
            : check != null
            ? element.attributes['value'] ?? 'on'
            : _snapshot(element).value;
        entries.add(NativeHtmlFormEntry(name, value));
      }
    }
    final submitterName = submitter?.attributes['name'];
    if (submitterName != null && submitterName.isNotEmpty) {
      // Insert at the submitter's position, rather than sorting/grouping names.
      final position = _document.querySelectorAll(
        'input,textarea,select,button',
      );
      final before = position
          .takeWhile((e) => !identical(e, submitter))
          .toSet();
      var index = 0;
      for (final e in elements.where(before.contains)) {
        if (_disabled(e) || (e.attributes['name'] ?? '').isEmpty) continue;
        if (const {'submit', 'reset', 'button', 'image'}.contains(_type(e))) {
          continue;
        }
        final check = controls.resolveControl(e);
        if (check != null && !controls.isChecked(check.key)) continue;
        final file = files?.resolveControl(e);
        if (file != null) {
          final count = files!.filesFor(file.key).length;
          index += count == 0 ? 1 : count;
          continue;
        }
        final select = selects.resolveControl(e);
        index += select == null
            ? 1
            : selects
                  .selectedIndices(select.key)
                  .where((i) => !select.options[i].disabled)
                  .length;
      }
      entries.insert(
        index,
        NativeHtmlFormEntry(
          submitterName,
          submitter!.attributes['value'] ??
              (submitter.localName == 'input'
                  ? buttons.defaultCaption(NativeHtmlButtonType.submit)
                  : ''),
        ),
      );
    }
    final request = NativeHtmlFormSubmission(
      action:
          submitter?.attributes['formaction'] ??
          form.attributes['action'] ??
          '',
      method:
          submitter?.attributes['formmethod'] ??
          form.attributes['method'] ??
          'get',
      enctype:
          submitter?.attributes['formenctype'] ??
          form.attributes['enctype'] ??
          'application/x-www-form-urlencoded',
      noopener: nativeHtmlFormNoopener(form.attributes['rel']),
      targetSpecified:
          (submitter?.attributes.containsKey('formtarget') ?? false) ||
          form.attributes.containsKey('target'),
      target:
          submitter?.attributes['formtarget'] ??
          form.attributes['target'] ??
          '',
      entries: entries,
      submitterId: submitter?.attributes['id'],
    );
    try {
      request.buildRequest();
    } on UnsupportedError catch (error) {
      _show(null, error.message.toString());
      return;
    }
    if (onSubmit == null) {
      _show(
        null,
        tr("Form navigation is not yet available in this native document."),
      );
      return;
    }
    onSubmit!(request);
  }

  HtmlValidationControl _snapshot(dom.Element element) {
    final text = textFields.resolveControl(element);
    final check = controls.resolveControl(element);
    final range = ranges.resolveControl(element);
    final select = selects.resolveControl(element);
    final date = dates?.resolveControl(element);
    final file = files?.resolveControl(element);
    final type = _type(element);
    final kind = text != null
        ? switch (text.kind) {
            NativeHtmlTextFieldKind.textarea =>
              HtmlValidationControlKind.textarea,
            NativeHtmlTextFieldKind.email => HtmlValidationControlKind.email,
            NativeHtmlTextFieldKind.url => HtmlValidationControlKind.url,
            NativeHtmlTextFieldKind.number => HtmlValidationControlKind.number,
            _ => HtmlValidationControlKind.text,
          }
        : check != null
        ? (check.type == NativeHtmlControlType.radio
              ? HtmlValidationControlKind.radio
              : HtmlValidationControlKind.checkbox)
        : range != null
        ? HtmlValidationControlKind.range
        : select != null
        ? HtmlValidationControlKind.select
        : file != null || type == 'file'
        ? HtmlValidationControlKind.file
        : date != null || type == 'date'
        ? HtmlValidationControlKind.date
        : HtmlValidationControlKind.unsupported;
    var value = text != null
        ? textFields.valueFor(text.key)
        : range != null
        ? ranges.valueFor(range.key)
        : select != null
        ? selects.valueFor(select.key)
        : date != null
        ? dates!.valueFor(date.key)
        : file != null
        ? ''
        : element.attributes['value'] ?? (check != null ? 'on' : '');
    var badInput = date != null && dates!.validityFor(date.key).badInput;
    if (kind == HtmlValidationControlKind.number && value.isNotEmpty) {
      badInput =
          !RegExp(
            r'^-?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?$',
          ).hasMatch(value) ||
          !(double.tryParse(value)?.isFinite ?? false);
      if (badInput) value = '';
    }
    if (kind == HtmlValidationControlKind.email ||
        kind == HtmlValidationControlKind.url) {
      String trim(String s) =>
          s.replaceAll(RegExp(r'^[\t\n\f\r ]+|[\t\n\f\r ]+$'), '');
      value =
          kind == HtmlValidationControlKind.email &&
              element.attributes.containsKey('multiple')
          ? value.split(',').map(trim).join(',')
          : trim(value);
    }
    final optionElements = element.querySelectorAll('option');
    return HtmlValidationControl(
      id: keyFor(element) ?? 'unsupported-${_fields.indexOf(element)}',
      kind: kind,
      value: value,
      name: element.attributes['name'],
      formOwner: _formKeys[_owner(element)],
      valueAttribute: element.attributes['value'],
      required: element.attributes.containsKey('required'),
      checked: check != null && controls.isChecked(check.key),
      selectedFileCount: file == null ? 0 : files!.filesFor(file.key).length,
      disabled: _disabled(element),
      readOnly: element.attributes.containsKey('readonly'),
      multiple: element.attributes.containsKey('multiple'),
      size: select == null ? 1 : (select.size == 0 ? 1 : select.size),
      options: select == null
          ? const []
          : [
              for (var i = 0; i < select.options.length; i++)
                HtmlValidationOption(
                  value: select.options[i].value,
                  selected: selects.selectedIndices(select.key).contains(i),
                  disabled: select.options[i].disabled,
                  directChild:
                      i < optionElements.length &&
                      identical(optionElements[i].parent, element),
                ),
            ],
      userEdited: text != null && textFields.wasUserEdited(text.key),
      badInput: badInput,
      min: element.attributes['min'],
      max: element.attributes['max'],
      step: element.attributes['step'],
      pattern: element.attributes['pattern'],
      minLength: text?.minLength,
      maxLength: text?.maxLength,
    );
  }

  void _focus(dom.Element e) {
    final text = textFields.resolveControl(e);
    final check = controls.resolveControl(e);
    final range = ranges.resolveControl(e);
    final select = selects.resolveControl(e);
    final date = dates?.resolveControl(e);
    final file = files?.resolveControl(e);
    if (text != null) {
      textFields.focusControl(text.key);
    } else if (check != null) {
      controls.focusControl(check.key);
    } else if (range != null) {
      ranges.focusControl(range.key);
    } else if (select != null) {
      selects.focusControl(select.key);
    } else if (date != null) {
      dates!.focusControl(date.key);
    } else if (file != null) {
      files!.focusControl(file.key);
    }
  }

  void _show(String? key, String text, [HtmlValidationResult? result]) {
    invalidKey = key;
    final translated = {
      'Form navigation is not yet available in this native document.': tr(
        "此原生頁面尚未支援表單導覽。",
      ),
      'This form uses a submit control that is not yet supported.': tr(
        "此表單使用尚未支援的提交控制項。",
      ),
      'Directional form entries are not yet supported.': tr("此表單使用尚未支援的欄位格式。"),
      'This form includes a control that is not yet supported.': tr(
        "此表單包含尚未支援的控制項，無法送出。",
      ),
    };
    message = buttons.locale.languageCode == 'zh'
        ? translated[text] ??
              (text.startsWith('Native HTML form') ? tr("此表單的送出格式尚未支援。") : text)
        : text;
    invalidResult = result;
    notifyListeners();
  }

  void dismiss() {
    if (_disposed || message == null) return;
    message = null;
    invalidKey = null;
    invalidResult = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    textFields.onSubmit = null;
    dates?.onSubmit = null;
    for (final state in [
      textFields,
      controls,
      ranges,
      selects,
      ?dates,
      ?files,
    ]) {
      state.removeListener(dismiss);
    }
    super.dispose();
  }
}

String _type(dom.Element e) => e.localName == 'textarea'
    ? 'textarea'
    : e.localName == 'select'
    ? 'select'
    : (e.attributes['type'] ?? '').toLowerCase();

bool _disabled(dom.Element e) {
  if (e.attributes.containsKey('disabled')) return true;
  for (var p = e.parent; p != null; p = p.parent) {
    if (p.localName != 'fieldset' || !p.attributes.containsKey('disabled')) {
      continue;
    }
    final first = p.children.where((e) => e.localName == 'legend').firstOrNull;
    var exempt = false;
    if (first != null) {
      for (dom.Element? n = e; n != null; n = n.parent) {
        if (identical(n, first)) {
          exempt = true;
          break;
        }
      }
    }
    if (exempt) continue;
    return true;
  }
  return false;
}

String _validationMessage(
  HtmlValidationResult result,
  dom.Element element,
  Locale locale,
  String value,
) {
  if (result.has(HtmlValidityFlag.badInput)) {
    if (_type(element) == 'date') {
      return locale.languageCode == 'zh'
          ? tr("請輸入有效值。")
          : tr("Please enter a valid value.");
    }
    return tr("Please enter a number.");
  }
  if (result.has(HtmlValidityFlag.valueMissing)) {
    if (locale.languageCode == 'zh') {
      return switch (_type(element)) {
        'checkbox' => tr("如果你要繼續執行，請勾選這個核取方塊。"),
        'radio' => tr("請選取其中一個選項。"),
        'select' => tr("請選取一個清單中的項目。"),
        'file' =>
          element.attributes.containsKey('multiple')
              ? tr("請選取一或多個檔案。")
              : tr("請選取檔案。"),
        _ => tr("請填寫這個欄位。"),
      };
    }
    return switch (_type(element)) {
      'checkbox' => tr("Please check this box if you want to proceed."),
      'radio' => tr("Please select one of these options."),
      'select' => tr("Please select an item in the list."),
      'file' =>
        element.attributes.containsKey('multiple')
            ? tr("Please select one or more files.")
            : tr("Please select a file."),
      _ => tr("Please fill out this field."),
    };
  }
  if (result.has(HtmlValidityFlag.typeMismatch)) {
    if (locale.languageCode == 'zh') {
      if (_type(element) == 'url') return tr("請輸入網址。");
      if (!value.contains('@')) {
        return tr("請在電子郵件地址中包含「@」。「{0}」未包含「@」。", [value]);
      }
      return tr("請輸入有效的電子郵件地址。");
    }
    return _type(element) == 'url'
        ? tr("Please enter a URL.")
        : tr("Please enter an email address.");
  }
  if (result.has(HtmlValidityFlag.patternMismatch)) {
    return locale.languageCode == 'zh'
        ? tr("請符合要求的格式。")
        : tr("Please match the requested format.");
  }
  if (result.has(HtmlValidityFlag.rangeUnderflow)) {
    return tr("Value must be greater than or equal to {0}.", [
      element.attributes['min'],
    ]);
  }
  if (result.has(HtmlValidityFlag.rangeOverflow)) {
    return tr("Value must be less than or equal to {0}.", [
      element.attributes['max'],
    ]);
  }
  if (result.has(HtmlValidityFlag.tooShort)) {
    return tr("Please lengthen this text to {0} characters or more.", [
      element.attributes['minlength'],
    ]);
  }
  if (result.has(HtmlValidityFlag.tooLong)) {
    return tr("Please shorten this text to {0} characters or less.", [
      element.attributes['maxlength'],
    ]);
  }
  return tr("Please enter a valid value.");
}
