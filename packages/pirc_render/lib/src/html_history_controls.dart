import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import 'html_controls.dart';
import 'html_date.dart';
import 'html_range.dart';
import 'html_select.dart';
import 'html_text_fields.dart';

enum NativeHtmlHistoryValueKind { text, checked, range, select, date }

/// One saved native HTML control value.
@immutable
class NativeHtmlHistoryControlValue {
  const NativeHtmlHistoryControlValue._({
    required this.kind,
    this.text,
    this.selection,
    this.checked,
    this.range,
    this.date,
    this.optionSelectedness = const {},
  });

  final NativeHtmlHistoryValueKind kind;
  final String? text;
  final TextSelection? selection;
  final bool? checked;
  final String? range;
  final NativeHtmlDateHistoryEntry? date;

  /// Option identity to selectedness. This preserves deselected defaults as
  /// well as selected options, without storing markup or scripting state.
  final Map<String, bool> optionSelectedness;

  factory NativeHtmlHistoryControlValue.text(
    String value, {
    TextSelection? selection,
  }) => NativeHtmlHistoryControlValue._(
    kind: NativeHtmlHistoryValueKind.text,
    text: value,
    selection: selection,
  );

  factory NativeHtmlHistoryControlValue.checked(bool value) =>
      NativeHtmlHistoryControlValue._(
        kind: NativeHtmlHistoryValueKind.checked,
        checked: value,
      );

  factory NativeHtmlHistoryControlValue.range(String value) =>
      NativeHtmlHistoryControlValue._(
        kind: NativeHtmlHistoryValueKind.range,
        range: value,
      );

  factory NativeHtmlHistoryControlValue.date(
    NativeHtmlDateHistoryEntry value,
  ) => NativeHtmlHistoryControlValue._(
    kind: NativeHtmlHistoryValueKind.date,
    date: value,
  );

  factory NativeHtmlHistoryControlValue.select(Map<String, bool> value) =>
      NativeHtmlHistoryControlValue._(
        kind: NativeHtmlHistoryValueKind.select,
        optionSelectedness: Map.unmodifiable(value),
      );
}

/// Immutable snapshot of eligible native HTML form-control edits.
///
/// Keys encode structural form/control identity, never the random registry
/// markers used by the renderer. Text and range values are captured only when
/// they differ from their source defaults; checkedness and select selectedness
/// are captured for eligible controls because Chrome restores them even when
/// the response's defaults change.
@immutable
class NativeHtmlControlSnapshot {
  NativeHtmlControlSnapshot._(Map<String, NativeHtmlHistoryControlValue> values)
    : controls = Map.unmodifiable(values);

  static final NativeHtmlControlSnapshot empty = NativeHtmlControlSnapshot._(
    const {},
  );

  final Map<String, NativeHtmlHistoryControlValue> controls;

  bool get isEmpty => controls.isEmpty;
  int get length => controls.length;

  /// Projects the history state eligible for a reconstructed response.
  /// Date values (including pristine and partial values) remain eligible;
  /// autocomplete=off, password and file exclusions are applied at capture.
  NativeHtmlControlSnapshot forFreshResponse() =>
      NativeHtmlControlSnapshot._(controls);
}

/// Internal document adapter used by [NativeHtmlHistoryController].
abstract interface class NativeHtmlHistoryBinding {
  NativeHtmlControlSnapshot? captureNativeHtmlHistory();
  void restoreNativeHtmlHistory(NativeHtmlControlSnapshot snapshot);
}

/// Holds the control state associated with a fetched document's history entry.
///
/// Call [restore] before the destination document widget attaches to queue a
/// snapshot. The next attached document consumes that queued snapshot once.
class NativeHtmlHistoryController {
  NativeHtmlHistoryBinding? _binding;
  NativeHtmlControlSnapshot? _pending;
  bool _pendingFromDetach = false;
  bool _disposed = false;

  bool get isDisposed => _disposed;

  /// Returns eligible live edits or their queued snapshot while detached.
  /// Password, file and autocomplete-off values stay outside this projection.
  NativeHtmlControlSnapshot? capture() {
    if (_disposed) return null;
    final binding = _binding;
    if (binding == null) return _pending;
    return binding.captureNativeHtmlHistory() ??
        NativeHtmlControlSnapshot.empty;
  }

  void restore(NativeHtmlControlSnapshot snapshot) {
    if (_disposed) return;
    final binding = _binding;
    if (binding == null) {
      _pending = snapshot;
      _pendingFromDetach = false;
    } else {
      binding.restoreNativeHtmlHistory(snapshot);
    }
  }

  /// Attaches the live renderer. A queued snapshot is applied after the
  /// renderer has finished building its control registries.
  void attach(
    NativeHtmlHistoryBinding binding, {
    bool retainedControls = false,
  }) {
    if (_disposed) return;
    _binding = binding;
    final pending = _pending;
    final applyPending = !retainedControls || !_pendingFromDetach;
    _pending = null;
    _pendingFromDetach = false;
    if (pending != null && applyPending) {
      binding.restoreNativeHtmlHistory(pending);
    }
  }

  /// Detaches only the renderer that currently owns this controller. A static
  /// owner may queue eligible controls for remount; script publications use
  /// their current DOM state instead.
  void detach(
    NativeHtmlHistoryBinding binding, {
    NativeHtmlControlSnapshot? snapshot,
  }) {
    if (!identical(_binding, binding)) return;
    _binding = null;
    if (snapshot != null) {
      _pending = snapshot;
      _pendingFromDetach = true;
    }
  }

  /// Clears queued and live state when its fetched document is discarded.
  void dispose() {
    _disposed = true;
    _pending = null;
    _pendingFromDetach = false;
    _binding = null;
  }
}

/// Captures and applies only the supported, declarative control state.
class NativeHtmlHistoryControls {
  const NativeHtmlHistoryControls._();

  static NativeHtmlControlSnapshot? capture({
    required String htmlSource,
    required NativeHtmlControlState controls,
    required NativeHtmlTextFieldState textFields,
    bool scripted = false,
    required NativeHtmlRangeState ranges,
    required NativeHtmlSelectState selects,
    NativeHtmlDateState? dates,
  }) {
    final document = _HistoryDocument.parse(htmlSource);
    final values = <String, NativeHtmlHistoryControlValue>{};
    final dateValues = dates?.captureHistory().values;
    final radioGroups = <String, List<dom.Element>>{};

    for (final control in document.controls) {
      final element = control.element;
      final checkable = controls.resolveControl(element);
      if (checkable != null) {
        final identity = document.identityFor(element);
        final group = document.radioGroupFor(element, identity: identity);
        if (checkable.type == NativeHtmlControlType.radio) {
          (radioGroups[group] ??= []).add(element);
        } else if (_eligible(element, checkable.disabled, false, document)) {
          values[identity] = NativeHtmlHistoryControlValue.checked(
            controls.isChecked(checkable.key),
          );
        }
        continue;
      }

      final text = textFields.resolveControl(element);
      if (text != null) {
        if (text.kind == NativeHtmlTextFieldKind.password ||
            !_eligible(element, text.disabled, text.readOnly, document)) {
          continue;
        }
        final controller = textFields.controllerFor(text.key);
        final defaultValue = scripted
            ? element.attributes['data-pirc-history-default-value'] ??
                  text.initialValue
            : text.initialValue;
        if (controller.text == defaultValue) continue;
        final selection = controller.selection;
        values[document.identityFor(
          element,
        )] = NativeHtmlHistoryControlValue.text(
          controller.text,
          selection: selection.isValid ? selection : null,
        );
        continue;
      }

      final date = dates?.resolveControl(element);
      if (date != null) {
        if (!_eligible(element, date.disabled, date.readOnly, document)) {
          continue;
        }
        final entry = dateValues?[date.key];
        if (entry != null) {
          values[document.identityFor(element)] =
              NativeHtmlHistoryControlValue.date(entry);
        }
        continue;
      }

      final range = ranges.resolveControl(element);
      if (range != null) {
        if (!_eligible(element, range.disabled, range.readOnly, document)) {
          continue;
        }
        final currentValue = ranges.valueFor(range.key);
        final defaultValue = scripted
            ? element.attributes['data-pirc-history-default-value'] ??
                  range.initialValue
            : range.initialValue;
        if (currentValue == defaultValue) continue;
        values[document.identityFor(element)] =
            NativeHtmlHistoryControlValue.range(currentValue);
        continue;
      }

      final select = selects.resolveControl(element);
      if (select != null) {
        if (!_eligible(element, select.disabled, false, document)) continue;
        final selected = selects.selectedIndices(select.key).toSet();
        final options = _optionIdentities(element, select);
        values[document.identityFor(
          element,
        )] = NativeHtmlHistoryControlValue.select({
          for (var index = 0; index < options.length; index++)
            options[index]: selected.contains(index),
        });
      }
    }

    // Checkedness and select selectedness are restored even when untouched:
    // Chrome keeps the prior document's values across a same-context response
    // whose newly authored defaults differ. Text and range values are saved
    // only while they differ from their original defaults.
    // Saving each radio group member also preserves its all-unchecked state.
    for (final group in radioGroups.values) {
      for (final element in group) {
        final descriptor = controls.resolveControl(element);
        if (descriptor == null ||
            !_eligible(element, descriptor.disabled, false, document)) {
          continue;
        }
        values[document.identityFor(
          element,
        )] = NativeHtmlHistoryControlValue.checked(
          controls.isChecked(descriptor.key),
        );
      }
    }

    return values.isEmpty ? null : NativeHtmlControlSnapshot._(values);
  }

  static void restore({
    required String htmlSource,
    required NativeHtmlControlSnapshot snapshot,
    required NativeHtmlControlState controls,
    required NativeHtmlTextFieldState textFields,
    required NativeHtmlRangeState ranges,
    required NativeHtmlSelectState selects,
    NativeHtmlDateState? dates,
  }) {
    final document = _HistoryDocument.parse(htmlSource);
    final checkedness = <String, bool>{};

    for (final control in document.controls) {
      final element = control.element;
      final checkable = controls.resolveControl(element);
      if (checkable != null) {
        if (!_eligible(element, checkable.disabled, false, document)) continue;
        final identity = document.identityFor(element);
        final value = snapshot.controls[identity];
        if (value?.kind == NativeHtmlHistoryValueKind.checked) {
          checkedness[checkable.key] = value!.checked!;
        }
        continue;
      }

      final text = textFields.resolveControl(element);
      if (text != null) {
        if (text.kind == NativeHtmlTextFieldKind.password ||
            !_eligible(element, text.disabled, text.readOnly, document)) {
          continue;
        }
        final value = snapshot.controls[document.identityFor(element)];
        if (value?.kind != NativeHtmlHistoryValueKind.text) continue;
        final controller = textFields.controllerFor(text.key);
        final savedText = value!.text!;
        final textChanged = controller.text != savedText;
        controller.value = TextEditingValue(
          text: savedText,
          selection: _restoreSelection(value.selection, savedText.length),
          composing: TextRange.empty,
        );
        // Same-document snapshot carries can restore an identical value while
        // Enter is awaiting its script handler. That bookkeeping is not a new
        // edit and must not cancel the pending default submission.
        textFields.recordUserEdit(
          text.key,
          invalidatePendingKeyEvent: textChanged,
        );
        continue;
      }

      final date = dates?.resolveControl(element);
      if (date != null) {
        if (!_eligible(element, date.disabled, date.readOnly, document)) {
          continue;
        }
        final value = snapshot.controls[document.identityFor(element)];
        if (value?.kind == NativeHtmlHistoryValueKind.date &&
            value?.date != null) {
          dates!.restoreHistory(
            NativeHtmlDateHistorySnapshot({date.key: value!.date!}),
          );
        }
        continue;
      }

      final range = ranges.resolveControl(element);
      if (range != null) {
        if (!_eligible(element, range.disabled, range.readOnly, document)) {
          continue;
        }
        final value = snapshot.controls[document.identityFor(element)];
        final number = value?.range == null
            ? null
            : double.tryParse(value!.range!);
        if (value?.kind == NativeHtmlHistoryValueKind.range && number != null) {
          ranges.setRangeValue(range.key, number);
        }
        continue;
      }

      final select = selects.resolveControl(element);
      if (select != null) {
        if (!_eligible(element, select.disabled, false, document)) continue;
        final identity = document.identityFor(element);
        final value = snapshot.controls[identity];
        if (value?.kind != NativeHtmlHistoryValueKind.select) continue;
        final options = _optionIdentities(element, select);
        selects.restoreHistorySelectedness(select.key, {
          for (var index = 0; index < options.length; index++)
            if (value!.optionSelectedness.containsKey(options[index]))
              index: value.optionSelectedness[options[index]]!,
        });
      }
    }

    controls.restoreHistoryCheckedness(checkedness);
  }
}

TextSelection _restoreSelection(TextSelection? selection, int textLength) {
  if (selection == null) return TextSelection.collapsed(offset: textLength);
  int clamp(int offset) => offset.clamp(0, textLength);
  return TextSelection(
    baseOffset: clamp(selection.baseOffset),
    extentOffset: clamp(selection.extentOffset),
    affinity: selection.affinity,
    isDirectional: selection.isDirectional,
  );
}

bool _eligible(
  dom.Element element,
  bool disabled,
  bool readOnly,
  _HistoryDocument document,
) {
  if (disabled ||
      readOnly ||
      element.localName == 'input' &&
          const {
            'password',
            'file',
          }.contains(element.attributes['type']?.toLowerCase())) {
    return false;
  }
  final form = document.formFor(element);
  return !_autocompleteOff(element.attributes['autocomplete']) &&
      !_autocompleteOff(form?.attributes['autocomplete']);
}

bool _autocompleteOff(String? value) =>
    value?.toLowerCase().split(RegExp(r'\s+')).contains('off') ?? false;

List<String> _optionIdentities(
  dom.Element select,
  NativeHtmlSelectDescriptor descriptor,
) {
  final counts = <String, int>{};
  final result = <String>[];
  for (var index = 0; index < descriptor.options.length; index++) {
    final option = descriptor.options[index];
    final valueKey = jsonEncode(option.value);
    final ordinal = counts.update(valueKey, (n) => n + 1, ifAbsent: () => 0);
    // The renderer's descriptor and parsed source preserve option order.
    // Including the source ordinal prevents repeated values from colliding.
    result.add(jsonEncode([valueKey, ordinal]));
  }
  return result;
}

class _HistoryControl {
  const _HistoryControl(this.element);

  final dom.Element element;
}

class _HistoryDocument {
  _HistoryDocument(
    this.controls,
    this._formByControl,
    this._formIdentities,
    this._controlIdentities,
    this._controlTypes,
  );

  final List<_HistoryControl> controls;
  final Map<dom.Element, dom.Element?> _formByControl;
  final Map<dom.Element, String> _formIdentities;
  final Map<dom.Element, String> _controlIdentities;
  final Map<dom.Element, String> _controlTypes;

  static _HistoryDocument parse(String source) {
    final root = html.parseFragment(source);
    final elements = _elements(root).toList();
    final forms = elements
        .where((element) => element.localName == 'form')
        .toList();
    final firstFormById = <String, dom.Element>{};
    final idCounts = <String, int>{};
    final nameCounts = <String, int>{};
    final formIdentity = <dom.Element, String>{};
    for (var index = 0; index < forms.length; index++) {
      final form = forms[index];
      final id = form.attributes['id'];
      final name = form.attributes['name'];
      final identity = id != null && id.isNotEmpty
          ? jsonEncode([
              'form-id',
              id,
              idCounts.update(id, (n) => n + 1, ifAbsent: () => 0),
            ])
          : name != null && name.isNotEmpty
          ? jsonEncode([
              'form-name',
              name,
              nameCounts.update(name, (n) => n + 1, ifAbsent: () => 0),
            ])
          : jsonEncode(['form-ordinal', index]);
      formIdentity[form] = identity;
      if (id != null && id.isNotEmpty) {
        firstFormById.putIfAbsent(id, () => form);
      }
    }

    final formByControl = <dom.Element, dom.Element?>{};
    final recognized = <_HistoryControl>[];
    for (final element in elements) {
      if (!{'input', 'textarea', 'select'}.contains(element.localName)) {
        continue;
      }
      dom.Element? form;
      if (element.attributes.containsKey('form')) {
        form = firstFormById[element.attributes['form']];
      } else {
        for (
          var parent = element.parent;
          parent != null;
          parent = parent.parent
        ) {
          if (parent.localName == 'form') {
            form = parent;
            break;
          }
        }
      }
      formByControl[element] = form;
      recognized.add(_HistoryControl(element));
    }
    final controlIdentities = <dom.Element, String>{};
    final controlTypes = <dom.Element, String>{};
    final ordinals = <String, int>{};
    for (final control in recognized) {
      final element = control.element;
      final form = formByControl[element];
      final formToken = form == null
          ? 'document-controls'
          : formIdentity[form]!;
      final type = _controlType(element);
      final name = element.attributes['name'];
      final group = jsonEncode([
        formToken,
        element.localName,
        type,
        name != null,
        name ?? '',
      ]);
      final ordinal = ordinals.update(
        group,
        (value) => value + 1,
        ifAbsent: () => 0,
      );
      controlTypes[element] = type;
      controlIdentities[element] = jsonEncode([group, ordinal]);
    }
    return _HistoryDocument(
      recognized,
      formByControl,
      formIdentity,
      controlIdentities,
      controlTypes,
    );
  }

  dom.Element? formFor(dom.Element control) => _formByControl[control];

  String identityFor(dom.Element element) => _controlIdentities[element]!;

  String radioGroupFor(dom.Element element, {required String identity}) {
    final form = formFor(element);
    final formIdentity = form == null
        ? 'document-controls'
        : _formIdentities[form]!;
    final name = element.attributes['name'];
    if (name == null || name.isEmpty) {
      return jsonEncode([
        formIdentity,
        _controlTypes[element],
        'unnamed',
        identity,
      ]);
    }
    return jsonEncode([formIdentity, _controlTypes[element], name]);
  }
}

String _controlType(dom.Element element) {
  if (element.localName == 'textarea') return 'textarea';
  if (element.localName == 'select') {
    return element.attributes.containsKey('multiple')
        ? 'select-multiple'
        : 'select-single';
  }
  final type = (element.attributes['type'] ?? '').toLowerCase();
  return switch (type) {
    '' || 'text' => 'text',
    'checkbox' ||
    'radio' ||
    'range' ||
    'password' ||
    'number' ||
    'search' ||
    'email' ||
    'url' ||
    'tel' ||
    'color' ||
    'date' ||
    'datetime-local' ||
    'month' ||
    'time' ||
    'week' ||
    'button' ||
    'file' ||
    'hidden' ||
    'image' ||
    'reset' ||
    'submit' => type,
    _ => 'text',
  };
}

Iterable<dom.Element> _elements(dom.Node parent) sync* {
  for (final node in parent.nodes) {
    if (node is! dom.Element) continue;
    yield node;
    yield* _elements(node);
  }
}
