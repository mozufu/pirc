import 'render_l10n.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import 'html_control_box_style.dart';
import 'html_control_border_painter.dart';
import 'html_control_intrinsic.dart';
import 'html_date_calendar.dart';
import 'html_date_locale.dart';
import 'html_date_validation.dart';

export 'html_date_locale.dart' show NativeHtmlDateLocale;

enum NativeHtmlDateSegment { month, day, year }

@immutable
class NativeHtmlDateDescriptor {
  const NativeHtmlDateDescriptor({
    required this.key,
    required this.initialValue,
    required this.valueAttribute,
    required this.min,
    required this.max,
    required this.step,
    required this.stepBase,
    required this.disabled,
    required this.readOnly,
    required this.visible,
    required this.required,
    required this.name,
    required this.label,
    required this.hint,
    this.scriptId,
  });

  final String key;

  /// Sanitized HTML `value` content attribute, also used for form reset.
  final String initialValue;

  /// Valid value content attribute used by the HTML step-base algorithm.
  final String? valueAttribute;
  final String? min;
  final String? max;
  final String? step;
  final NativeHtmlDateValue stepBase;
  final bool disabled;
  final bool readOnly;
  final bool visible;
  final bool required;
  final String? name;
  final String label;
  final String hint;
  final String? scriptId;

  bool get mutable => !disabled && !readOnly;
  bool get willValidate => mutable;
}

@immutable
class NativeHtmlDateFormValue {
  const NativeHtmlDateFormValue({required this.name, required this.value});

  final String name;
  final String value;
}

@immutable
class NativeHtmlDateHistoryEntry {
  const NativeHtmlDateHistoryEntry({
    required this.value,
    required this.month,
    required this.day,
    required this.year,
    required this.badInput,
    required this.userEdited,
  });

  final String value;
  final String month;
  final String day;
  final String year;
  final bool badInput;
  final bool userEdited;
}

@immutable
class NativeHtmlDateHistorySnapshot {
  NativeHtmlDateHistorySnapshot(Map<String, NativeHtmlDateHistoryEntry> values)
    : values = Map.unmodifiable(values);

  final Map<String, NativeHtmlDateHistoryEntry> values;

  bool get isEmpty => values.isEmpty;
}

/// Per-document state for native HTML `<input type="date">` controls.
///
/// Values exposed to forms are always canonical HTML date strings or empty.
/// Incomplete/invalid segmented input remains in [captureHistory] as UI state
/// and sets `badInput`; it is never submitted as arbitrary text.
class NativeHtmlDateState extends ChangeNotifier {
  NativeHtmlDateState._(this._source, this._nonce);

  factory NativeHtmlDateState.fromHtml(String sanitizedHtml) {
    final nonce = List.generate(
      12,
      (_) =>
          math.Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final state = NativeHtmlDateState._(sanitizedHtml, nonce);
    state._scanAndAnnotate();
    return state;
  }

  static const _controlAttribute = 'data-pirc-native-date-id';
  static const _labelAttribute = 'data-pirc-native-date-for';
  static const _markerPrefix = 'data-pirc-native-date-';

  final String _source;
  final String _nonce;
  late final String _annotatedHtml;
  final Map<String, _DateRecord> _records = {};
  bool _disposed = false;

  void Function(String key, String type)? onUserEvent;

  ValueChanged<String>? onSubmit;

  String annotateHtml(String sanitizedHtml) {
    if (sanitizedHtml != _source) {
      throw ArgumentError.value(
        sanitizedHtml,
        'sanitizedHtml',
        tr("Must be the exact fragment used to create this date state."),
      );
    }
    return _annotatedHtml;
  }

  NativeHtmlDateDescriptor? resolveControl(dom.Element element) {
    if (element.localName != 'input' ||
        (element.attributes['type'] ?? '').toLowerCase() != 'date') {
      return null;
    }
    final key = element.attributes[_controlAttribute];
    final record = key == null ? null : _records[key];
    return record?.descriptor;
  }

  NativeHtmlDateDescriptor? resolveLabel(dom.Element label) {
    if (label.localName != 'label') return null;
    final key = label.attributes[_labelAttribute];
    return key == null ? null : _records[key]?.descriptor;
  }

  void activateLabel(dom.Element label) {
    final descriptor = resolveLabel(label);
    if (descriptor == null || descriptor.disabled || !descriptor.visible) {
      return;
    }
    focusControl(descriptor.key);
  }

  void focusControl(String key) {
    final record = _recordFor(key);
    final descriptor = record.descriptor;
    if (descriptor.disabled || !descriptor.visible) return;
    focusSegment(key, record.displayOrder.first);
  }

  void setDisplayOrder(String key, List<NativeHtmlDateSegment> order) {
    if (order.length != NativeHtmlDateSegment.values.length) return;
    _recordFor(key).displayOrder = List.unmodifiable(order);
  }

  void focusSegment(String key, NativeHtmlDateSegment segment) {
    final record = _recordFor(key);
    if (record.descriptor.disabled || !record.descriptor.visible) return;
    record.focusNodes[segment]!.requestFocus();
  }

  String valueFor(String key) => _recordFor(key).value;

  NativeHtmlDateValue? dateFor(String key) =>
      NativeHtmlDateValue.parse(valueFor(key));

  bool badInputFor(String key) => _recordFor(key).badInput;

  bool wasUserEdited(String key) => _recordFor(key).userEdited;

  /// A revision token for an operation that should not overwrite a newer
  /// user/reset/source state when its asynchronous work completes.
  int? revisionFor(String key) => _disposed ? null : _records[key]?.revision;

  TextEditingController segmentControllerFor(
    String key,
    NativeHtmlDateSegment segment,
  ) => _recordFor(key).controllers[segment]!;

  FocusNode segmentFocusNodeFor(String key, NativeHtmlDateSegment segment) =>
      _recordFor(key).focusNodes[segment]!;

  GlobalKey widgetKeyFor(String key) => _recordFor(key).widgetKey;

  NativeHtmlDateValidity validityFor(String key) {
    final record = _recordFor(key);
    final field = record.descriptor;
    return NativeHtmlDateValidation.evaluate(
      value: record.value,
      required: field.required,
      disabled: field.disabled,
      readOnly: field.readOnly,
      min: field.min,
      max: field.max,
      step: field.step,
      valueAttribute: field.valueAttribute,
      stepBase: field.stepBase,
      badInput: record.badInput,
    );
  }

  /// Applies one visible segment edit, sanitizes it to ASCII digits, and
  /// updates the canonical date as soon as all three segments form a date.
  void updateSegment(
    String key,
    NativeHtmlDateSegment segment,
    String proposed,
  ) {
    final record = _recordFor(key);
    if (!record.descriptor.mutable) return;
    final previousSegment = record.lastSegmentValues[segment] ?? '';
    final previousValue = record.value;
    final previousBadInput = record.badInput;
    final normalized = proposed.replaceAll(RegExp(r'[^0-9]'), '');
    final controller = record.controllers[segment]!;
    if (controller.text != normalized) {
      controller.value = TextEditingValue(
        text: normalized,
        selection: TextSelection.collapsed(offset: normalized.length),
      );
    }
    record.lastSegmentValues[segment] = normalized;
    _recomputeValue(record);
    record.userEdited = true;
    record.revision++;
    notifyListeners();
    if (previousSegment != normalized ||
        previousValue != record.value ||
        previousBadInput != record.badInput) {
      _emitUserChange(key);
    }
  }

  /// Sets a programmatic HTML date value. Invalid strings sanitize to empty
  /// without marking the field as bad input.
  void setValue(String key, String value) {
    final record = _recordFor(key);
    final parsed = NativeHtmlDateValue.parse(value);
    final canonical = parsed?.canonical ?? '';
    if (canonical == record.value && !record.badInput) return;
    _setDateRecord(record, parsed, badInput: false);
    record.userEdited = false;
    record.revision++;
    notifyListeners();
  }

  /// Applies an actual calendar selection or a valid keyboard-completed date.
  void setDate(String key, NativeHtmlDateValue? date) {
    final record = _recordFor(key);
    if (!record.descriptor.mutable) return;
    final before = _interactionState(record);
    _setDateRecord(record, date, badInput: false);
    record.userEdited = true;
    record.revision++;
    notifyListeners();
    if (before != _interactionState(record)) _emitUserChange(key);
  }

  /// Applies an asynchronous picker result only if the field has not been
  /// reset, replaced, or edited since the picker was opened.
  bool setDateIfUnchanged(
    String key,
    int expectedRevision,
    NativeHtmlDateValue date,
  ) {
    if (_disposed) return false;
    final record = _records[key];
    if (record == null ||
        record.revision != expectedRevision ||
        !record.descriptor.mutable) {
      return false;
    }
    setDate(key, date);
    return true;
  }

  void clear(String key) {
    final record = _recordFor(key);
    if (!record.descriptor.mutable) return;
    final before = _interactionState(record);
    _setDateRecord(record, null, badInput: false);
    record.userEdited = true;
    record.revision++;
    notifyListeners();
    if (before != _interactionState(record)) _emitUserChange(key);
  }

  void submit(String key) => onSubmit?.call(key);

  /// Returns the canonical values for requested control keys.
  Map<String, String> valuesFor([Iterable<String>? keys]) {
    final selected = keys ?? _records.keys;
    return Map.unmodifiable({
      for (final key in selected)
        if (_records.containsKey(key)) key: _records[key]!.value,
    });
  }

  /// Values eligible for form submission, in document order. A named enabled
  /// date input contributes one canonical value, including the empty string.
  List<NativeHtmlDateFormValue> successfulValues([Iterable<String>? keys]) {
    final selected = keys ?? _records.keys;
    return List.unmodifiable([
      for (final key in selected)
        if (_records[key] case final record?)
          if (!record.descriptor.disabled &&
              (record.descriptor.name?.isNotEmpty ?? false))
            NativeHtmlDateFormValue(
              name: record.descriptor.name!,
              value: record.value,
            ),
    ]);
  }

  /// HTML form reset restores the value content attribute, including on
  /// disabled and readonly controls.
  void resetDefaults([Iterable<String>? keys]) {
    final selected = keys ?? _records.keys;
    for (final key in selected) {
      final record = _records[key];
      if (record == null) continue;
      record.userEdited = false;
      _setDateRecord(
        record,
        NativeHtmlDateValue.parse(record.descriptor.initialValue),
        badInput: false,
      );
      record.revision++;
    }
    notifyListeners();
  }

  NativeHtmlDateHistorySnapshot captureHistory() =>
      NativeHtmlDateHistorySnapshot({
        for (final entry in _records.entries)
          entry.key: NativeHtmlDateHistoryEntry(
            value: entry.value.value,
            month: entry.value.controllers[NativeHtmlDateSegment.month]!.text,
            day: entry.value.controllers[NativeHtmlDateSegment.day]!.text,
            year: entry.value.controllers[NativeHtmlDateSegment.year]!.text,
            badInput: entry.value.badInput,
            userEdited: entry.value.userEdited,
          ),
      });

  /// Restores only controls whose stable state key still exists. This restores
  /// incomplete segmented input too, without ever promoting it to a submitted
  /// string.
  void restoreHistory(NativeHtmlDateHistorySnapshot snapshot) {
    for (final entry in snapshot.values.entries) {
      final record = _records[entry.key];
      if (record == null) continue;
      final value = NativeHtmlDateValue.parse(entry.value.value);
      final month = _digits(entry.value.month);
      final day = _digits(entry.value.day);
      final year = _digits(entry.value.year);
      _setSegments(record, month: month, day: day, year: year);
      record.value = value?.canonical ?? '';
      record.badInput = entry.value.badInput && value == null;
      record.userEdited = entry.value.userEdited;
      record.revision++;
    }
    notifyListeners();
  }

  /// Transfers segmented-editor resources for controls with unique script IDs.
  /// The fresh state keeps its parsed descriptor and canonical value.
  /// [preserveValues] is for presentation changes of an unchanged static DOM;
  /// script publications keep fresh DOM values and authored reset defaults.
  void adoptInteractionState(
    NativeHtmlDateState previous, {
    bool preserveValues = false,
  }) {
    if (identical(this, previous)) return;
    final oldById = _uniqueRecordsByScriptId(previous._records);
    final newById = _uniqueRecordsByScriptId(_records);
    for (final entry in newById.entries) {
      final old = oldById[entry.key];
      if (old == null) continue;
      final oldRecord = old.value;
      final newRecord = entry.value.value;
      if (preserveValues) newRecord.value = oldRecord.value;
      final sameValue = oldRecord.value == newRecord.value;
      final desiredSegments = {
        for (final segment in NativeHtmlDateSegment.values)
          segment: sameValue
              ? oldRecord.controllers[segment]!.text
              : newRecord.lastSegmentValues[segment] ?? '',
      };
      if (sameValue) {
        // Partial segmented input has an empty canonical value. A snapshot
        // echoing that value must not erase the user's unfinished date.
        newRecord.badInput = oldRecord.badInput;
        newRecord.userEdited = oldRecord.userEdited;
        newRecord.revision = oldRecord.revision;
      } else {
        newRecord.revision = oldRecord.revision + 1;
      }

      for (final controller in newRecord.controllers.values) {
        controller.dispose();
      }
      for (final focus in newRecord.focusNodes.values) {
        focus.dispose();
      }
      newRecord.controllers
        ..clear()
        ..addAll(oldRecord.controllers);
      newRecord.focusNodes
        ..clear()
        ..addAll(oldRecord.focusNodes);
      for (final focus in newRecord.focusNodes.values) {
        focus
          ..canRequestFocus =
              !newRecord.descriptor.disabled && newRecord.descriptor.visible
          ..skipTraversal =
              newRecord.descriptor.disabled || !newRecord.descriptor.visible;
      }
      newRecord.widgetKey = oldRecord.widgetKey;
      newRecord.displayOrder = oldRecord.displayOrder;
      for (final segment in NativeHtmlDateSegment.values) {
        final text = desiredSegments[segment]!;
        _setController(newRecord.controllers[segment]!, text);
        newRecord.lastSegmentValues[segment] = text;
      }
      previous._records.remove(old.key);
    }
  }

  Map<String, MapEntry<String, _DateRecord>> _uniqueRecordsByScriptId(
    Map<String, _DateRecord> records,
  ) {
    final grouped = <String, List<MapEntry<String, _DateRecord>>>{};
    for (final entry in records.entries) {
      final id = entry.value.descriptor.scriptId;
      if (id == null || id.isEmpty) continue;
      (grouped[id] ??= []).add(entry);
    }
    return {
      for (final entry in grouped.entries)
        if (entry.value.length == 1) entry.key: entry.value.single,
    };
  }

  (String, bool, String, String, String) _interactionState(
    _DateRecord record,
  ) => (
    record.value,
    record.badInput,
    record.lastSegmentValues[NativeHtmlDateSegment.month] ?? '',
    record.lastSegmentValues[NativeHtmlDateSegment.day] ?? '',
    record.lastSegmentValues[NativeHtmlDateSegment.year] ?? '',
  );

  void _emitUserChange(String key) {
    final callback = onUserEvent;
    callback?.call(key, 'input');
    callback?.call(key, 'change');
  }

  _DateRecord _recordFor(String key) {
    final record = _records[key];
    if (record == null) {
      throw StateError(tr("Unknown HTML date field: {0}", [key]));
    }
    return record;
  }

  void _scanAndAnnotate() {
    final fragment = html.parseFragment(_source);
    final elements = _elements(fragment).toList();
    for (final element in elements) {
      for (final attribute
          in element.attributes.keys
              .where((name) => '$name'.startsWith(_markerPrefix))
              .toList()) {
        element.attributes.remove(attribute);
      }
    }

    final firstById = <String, dom.Element>{};
    for (final element in elements) {
      final id = element.attributes['id'];
      if (id != null && id.isNotEmpty) firstById.putIfAbsent(id, () => element);
    }

    final pending = <_PendingDate>[];
    var ordinal = 0;
    for (final element in elements) {
      if (element.localName != 'input' ||
          (element.attributes['type'] ?? '').toLowerCase() != 'date') {
        continue;
      }
      final key = '$_nonce-${ordinal++}';
      final valueAttribute = NativeHtmlDateValue.parse(
        element.attributes['value'] ?? '',
      );
      final min = NativeHtmlDateValue.parse(element.attributes['min'] ?? '');
      final max = NativeHtmlDateValue.parse(element.attributes['max'] ?? '');
      final stepBase =
          min ?? valueAttribute ?? NativeHtmlDateValue.parse('1970-01-01')!;
      final field = _PendingDate(
        key: key,
        element: element,
        initialValue: valueAttribute?.canonical ?? '',
        valueAttribute: valueAttribute?.canonical,
        min: min?.canonical,
        max: max?.canonical,
        step: element.attributes['step'],
        stepBase: stepBase,
        disabled:
            element.attributes.containsKey('disabled') ||
            _disabledByFieldset(element),
        readOnly: element.attributes.containsKey('readonly'),
        visible: _visibleForNavigation(element),
        required: element.attributes.containsKey('required'),
        name: element.attributes['name'],
      );
      element.attributes[_controlAttribute] = key;
      pending.add(field);
    }

    final pendingByElement = {
      for (final field in pending) field.element: field,
    };
    final labels = <String, List<String>>{};
    for (final label in elements.where(
      (element) => element.localName == 'label',
    )) {
      final target = _labelTarget(label, firstById, pendingByElement);
      if (target == null) continue;
      final key = pendingByElement[target]!.key;
      label.attributes[_labelAttribute] = key;
      final text = _normalize(label.text);
      if (text.isNotEmpty) (labels[key] ??= []).add(text);
    }

    for (final field in pending) {
      final labelledBy = _referencedText(
        field.element.attributes['aria-labelledby'],
        firstById,
      );
      final describedBy = _referencedText(
        field.element.attributes['aria-describedby'],
        firstById,
      );
      final ariaLabel = field.element.attributes['aria-label']?.trim();
      final associated = labels[field.key] ?? const <String>[];
      final label = labelledBy.isNotEmpty
          ? labelledBy
          : ariaLabel?.isNotEmpty == true
          ? ariaLabel!
          : associated.isNotEmpty
          ? associated.join(' ')
          : _normalize(field.element.attributes['title'] ?? '');
      final hint = describedBy.isNotEmpty
          ? describedBy
          : _normalize(field.element.attributes['aria-description'] ?? '');
      final descriptor = NativeHtmlDateDescriptor(
        key: field.key,
        initialValue: field.initialValue,
        valueAttribute: field.valueAttribute,
        min: field.min,
        max: field.max,
        step: field.step,
        stepBase: field.stepBase,
        disabled: field.disabled,
        readOnly: field.readOnly,
        visible: field.visible,
        required: field.required,
        name: field.name,
        label: label,
        hint: hint,
        scriptId: field.element.attributes['data-pirc-script-id'],
      );
      _records[field.key] = _DateRecord(
        descriptor: descriptor,
        value: field.initialValue,
        badInput: false,
        controllers: {
          NativeHtmlDateSegment.month: TextEditingController(
            text:
                NativeHtmlDateValue.parse(
                  field.initialValue,
                )?.month.toString().padLeft(2, '0') ??
                '',
          ),
          NativeHtmlDateSegment.day: TextEditingController(
            text:
                NativeHtmlDateValue.parse(
                  field.initialValue,
                )?.day.toString().padLeft(2, '0') ??
                '',
          ),
          NativeHtmlDateSegment.year: TextEditingController(
            text:
                NativeHtmlDateValue.parse(
                  field.initialValue,
                )?.year.toString().padLeft(4, '0') ??
                '',
          ),
        },
        focusNodes: {
          for (final segment in NativeHtmlDateSegment.values)
            segment: FocusNode(
              debugLabel: label.isEmpty
                  ? 'HTML date ${segment.name}'
                  : '$label ${segment.name}',
              canRequestFocus: !field.disabled && field.visible,
              skipTraversal: field.disabled || !field.visible,
            ),
        },
        widgetKey: GlobalKey(),
      );
    }
    _annotatedHtml = fragment.outerHtml;
  }

  void _recomputeValue(_DateRecord record) {
    final month = record.controllers[NativeHtmlDateSegment.month]!.text;
    final day = record.controllers[NativeHtmlDateSegment.day]!.text;
    final year = record.controllers[NativeHtmlDateSegment.year]!.text;
    if (month.isEmpty && day.isEmpty && year.isEmpty) {
      record.value = '';
      record.badInput = false;
      return;
    }
    if (month.isEmpty || day.isEmpty || year.isEmpty) {
      record.value = '';
      record.badInput = true;
      return;
    }
    final value = NativeHtmlDateValue.parse(
      '${year.padLeft(4, '0')}-'
      '${month.padLeft(2, '0')}-'
      '${day.padLeft(2, '0')}',
    );
    record.value = value?.canonical ?? '';
    record.badInput = value == null;
  }

  void _setDateRecord(
    _DateRecord record,
    NativeHtmlDateValue? date, {
    required bool badInput,
  }) {
    if (date == null) {
      _setSegments(record, month: '', day: '', year: '');
      record.value = '';
    } else {
      _setSegments(
        record,
        month: date.month.toString().padLeft(2, '0'),
        day: date.day.toString().padLeft(2, '0'),
        year: date.year.toString().padLeft(4, '0'),
      );
      record.value = date.canonical;
    }
    record.badInput = badInput;
  }

  void _setSegments(
    _DateRecord record, {
    required String month,
    required String day,
    required String year,
  }) {
    _setController(record.controllers[NativeHtmlDateSegment.month]!, month);
    _setController(record.controllers[NativeHtmlDateSegment.day]!, day);
    _setController(record.controllers[NativeHtmlDateSegment.year]!, year);
    record.lastSegmentValues
      ..[NativeHtmlDateSegment.month] = month
      ..[NativeHtmlDateSegment.day] = day
      ..[NativeHtmlDateSegment.year] = year;
  }

  void _setController(TextEditingController controller, String value) {
    if (controller.text == value) return;
    controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  String _digits(String value) => value.replaceAll(RegExp(r'[^0-9]'), '');

  dom.Element? _labelTarget(
    dom.Element label,
    Map<String, dom.Element> firstById,
    Map<dom.Element, _PendingDate> fields,
  ) {
    if (label.attributes.containsKey('for')) {
      final id = label.attributes['for'];
      final target = id == null ? null : firstById[id];
      return target != null && fields.containsKey(target) ? target : null;
    }
    for (final element in _labelDescendants(label)) {
      if (element.localName == 'input' &&
          (element.attributes['type'] ?? '').toLowerCase() == 'date') {
        return fields.containsKey(element) ? element : null;
      }
    }
    return null;
  }

  String _referencedText(String? ids, Map<String, dom.Element> firstById) {
    if (ids == null) return '';
    return _normalize(
      ids
          .split(RegExp(r'\s+'))
          .where((id) => id.isNotEmpty)
          .map((id) => firstById[id]?.text ?? '')
          .where((text) => text.isNotEmpty)
          .join(' '),
    );
  }

  bool _disabledByFieldset(dom.Element element) {
    dom.Node? parent = element.parentNode;
    while (parent is dom.Element) {
      if (parent.localName == 'fieldset' &&
          parent.attributes.containsKey('disabled')) {
        dom.Element? firstLegend;
        for (final candidate in parent.children) {
          if (candidate.localName == 'legend') {
            firstLegend = candidate;
            break;
          }
        }
        if (firstLegend == null || !_isWithin(element, firstLegend)) {
          return true;
        }
      }
      parent = parent.parentNode;
    }
    return false;
  }

  bool _isWithin(dom.Node node, dom.Node ancestor) {
    for (
      dom.Node? current = node;
      current != null;
      current = current.parentNode
    ) {
      if (identical(current, ancestor)) return true;
    }
    return false;
  }

  bool _visibleForNavigation(dom.Element element) {
    for (
      dom.Element? current = element;
      current != null;
      current = current.parent
    ) {
      if (current.attributes.containsKey('hidden') ||
          current.localName == 'template' ||
          _styleHides(current.attributes['style'] ?? '')) {
        return false;
      }
    }
    return true;
  }

  bool _styleHides(String style) {
    for (final declaration in style.split(';')) {
      final colon = declaration.indexOf(':');
      if (colon < 0) continue;
      final property = declaration.substring(0, colon).trim().toLowerCase();
      final value = declaration
          .substring(colon + 1)
          .trim()
          .toLowerCase()
          .replaceAll(RegExp(r'\s*!important\s*$'), '');
      if ((property == 'display' && value == 'none') ||
          (property == 'visibility' &&
              (value == 'hidden' || value == 'collapse'))) {
        return true;
      }
    }
    return false;
  }

  static Iterable<dom.Element> _labelDescendants(dom.Element parent) sync* {
    for (final child in parent.children) {
      if (child.localName == 'label') continue;
      yield child;
      yield* _labelDescendants(child);
    }
  }

  static Iterable<dom.Element> _elements(dom.Node parent) sync* {
    for (final child in parent.nodes) {
      if (child is dom.Element) {
        yield child;
        yield* _elements(child);
      }
    }
  }

  static String _normalize(String value) =>
      value.replaceAll(RegExp(r'\s+'), ' ').trim();

  @override
  void dispose() {
    _disposed = true;
    for (final record in _records.values) {
      for (final controller in record.controllers.values) {
        controller.dispose();
      }
      for (final focus in record.focusNodes.values) {
        focus.dispose();
      }
    }
    _records.clear();
    super.dispose();
  }
}

class NativeHtmlDateInput extends StatelessWidget {
  const NativeHtmlDateInput({
    super.key,
    required this.state,
    required this.control,
    required this.textStyle,
    this.boxStyle,
    this.hostLocale,
  });

  final NativeHtmlDateState state;
  final NativeHtmlDateDescriptor control;
  final TextStyle textStyle;
  final NativeHtmlControlBoxStyle? boxStyle;

  /// Host browser-chrome locale, independent of the document's `lang` value.
  /// Defaults to the current platform locale.
  final Locale? hostLocale;

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    if (!control.visible) return const SizedBox.shrink();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final enabled = !control.disabled;
    final border = dark ? const Color(0xff858585) : const Color(0xff767676);
    final disabledBorder = border.withValues(alpha: .3);
    final background = control.disabled
        ? (dark ? const Color(0xff3b3b3b) : const Color(0xffefefef))
        : (dark ? const Color(0xff3b3b3b) : Colors.white);
    final color =
        textStyle.color ?? (dark ? Colors.white : const Color(0xff111111));
    final locale = NativeHtmlDateLocale.forLocale(
      hostLocale ?? WidgetsBinding.instance.platformDispatcher.locale,
    );
    final format = locale.order
        .map(
          (part) => NativeHtmlDateSegment.values.firstWhere(
            (segment) => segment.name == part,
          ),
        )
        .toList(growable: false);
    state.setDisplayOrder(control.key, format);
    final inputTextStyle = textStyle.copyWith(height: kTextHeightNone);
    final metrics = _measure(context, locale, format, inputTextStyle);
    final segments = <Widget>[];
    for (var index = 0; index < format.length; index++) {
      final segment = format[index];
      final maxLength = segment == NativeHtmlDateSegment.year ? null : 2;
      segments.add(
        Semantics(
          label: control.label.isEmpty
              ? locale.labelFor(segment.name)
              : '${control.label}, ${locale.labelFor(segment.name)}',
          child: SizedBox(
            width: metrics.segmentWidths[segment]!,
            child: TextField(
              key: ValueKey(
                'native-html-date-segment-${control.key}-${segment.name}',
              ),
              controller: state.segmentControllerFor(control.key, segment),
              focusNode: state.segmentFocusNodeFor(control.key, segment),
              enabled: enabled,
              readOnly: control.readOnly,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              style: inputTextStyle,
              maxLines: 1,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                if (maxLength != null)
                  LengthLimitingTextInputFormatter(maxLength),
              ],
              onChanged: (value) {
                state.updateSegment(control.key, segment, value);
                if (maxLength != null &&
                    value.length >= maxLength &&
                    index + 1 < format.length) {
                  state.focusSegment(control.key, format[index + 1]);
                }
              },
              onSubmitted: (_) {
                if (index + 1 < format.length) {
                  state.focusSegment(control.key, format[index + 1]);
                } else {
                  state.submit(control.key);
                }
              },
              decoration: InputDecoration.collapsed(
                hintText: locale.placeholder(segment.name),
                hintStyle: inputTextStyle.copyWith(
                  color: color.withValues(alpha: .55),
                ),
              ),
            ),
          ),
        ),
      );
      if (index + 1 < format.length) {
        segments.add(Text(locale.separator, style: inputTextStyle));
      }
    }

    Widget calendarButton(double width) => NativeHtmlDateCalendarButton(
      state: state,
      control: control,
      locale: locale,
      width: width,
      height: metrics.rowHeight,
      iconSize: metrics.calendarIconSize,
    );

    Widget rowForWidth(double availableWidth) {
      final width = math.max(0.0, availableWidth);
      final buttonWidth = math.min(metrics.calendarWidth, width);
      final segmentViewportWidth = math.max(0.0, width - buttonWidth);
      final segmentRow = Row(
        mainAxisSize: MainAxisSize.min,
        children: segments,
      );
      final segmentContent =
          segmentViewportWidth >= metrics.rowWidth - metrics.calendarWidth
          ? segmentRow
          : SizedBox(
              width: segmentViewportWidth,
              height: metrics.rowHeight,
              child: ClipRect(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: segmentRow,
                ),
              ),
            );
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [segmentContent, calendarButton(buttonWidth)],
      );
    }

    final child = boxStyle == null
        ? LayoutBuilder(
            builder: (context, constraints) {
              final naturalWidth = metrics.rowWidth + 5;
              final width = constraints.constrainWidth(naturalWidth);
              return Container(
                width: width,
                height: metrics.rowHeight + 4,
                padding: const EdgeInsets.only(left: 1),
                decoration: BoxDecoration(
                  color: background,
                  border: Border.all(
                    color: enabled ? border : disabledBorder,
                    width: 2,
                  ),
                ),
                child: rowForWidth(math.max(0.0, width - 1)),
              );
            },
          )
        : LayoutBuilder(
            builder: (context, constraints) {
              final style = boxStyle!;
              final styledBorder = style.borderForEnabledState(
                enabled: enabled,
                disabledBorderColor: disabledBorder,
              );
              final padding = style.resolvePadding(constraints);
              final intrinsic = Size(
                metrics.rowWidth +
                    padding.horizontal +
                    styledBorder.dimensions.horizontal,
                metrics.rowHeight +
                    padding.vertical +
                    styledBorder.dimensions.vertical,
              );
              final layout = style.resolveLayout(
                intrinsicBorderBoxSize: intrinsic,
                constraints: constraints,
              );
              final contentWidth = math.max(
                0.0,
                layout.size.width -
                    padding.horizontal -
                    styledBorder.dimensions.horizontal,
              );
              return CustomPaint(
                foregroundPainter: NativeHtmlControlBorderPainter(
                  border: styledBorder,
                  styleNames: style.borderStyleNames,
                  borderRadius: layout.borderRadius,
                ),
                child: Container(
                  width: layout.size.width,
                  height: layout.size.height,
                  padding:
                      layout.padding +
                      styledBorder.dimensions.resolve(
                        Directionality.of(context),
                      ),
                  decoration: BoxDecoration(
                    color: style.hasAuthoredBackground
                        ? layout.backgroundColor
                        : background,
                    borderRadius: layout.borderRadius,
                  ),
                  child: rowForWidth(contentWidth),
                ),
              );
            },
          );
    final semantics = Semantics(
      key: ValueKey('native-html-date-${control.key}'),
      container: true,
      label: control.label.isEmpty ? null : control.label,
      hint: control.hint.isEmpty ? null : control.hint,
      enabled: enabled,
      readOnly: control.readOnly,
      textField: true,
      child: Focus(
        canRequestFocus: false,
        onKeyEvent: (context, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
            state.submit(control.key);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: ListenableBuilder(
          listenable: state,
          builder: (context, _) => child,
        ),
      ),
    );
    final intrinsicSize = boxStyle == null
        ? Size(metrics.rowWidth + 5, metrics.rowHeight + 4)
        : _cssIntrinsicSize(boxStyle!, metrics);
    final direction = Directionality.of(context);
    return NativeHtmlControlIntrinsic(
      intrinsicSize: intrinsicSize,
      baselineFromTop: boxStyle == null
          ? 2 + metrics.rowBaseline
          : boxStyle!.border.dimensions.resolve(direction).top +
                boxStyle!.resolvePadding(const BoxConstraints()).top +
                metrics.rowBaseline,
      child: semantics,
    );
  }

  _NativeHtmlDateMetrics _measure(
    BuildContext context,
    NativeHtmlDateLocale locale,
    List<NativeHtmlDateSegment> segments,
    TextStyle measurementStyle,
  ) {
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    TextPainter measure(String text) => TextPainter(
      text: TextSpan(text: text, style: measurementStyle),
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    )..layout();

    final widths = <NativeHtmlDateSegment, double>{};
    var lineHeight = 0.0;
    final currentDate = state.dateFor(control.key);
    final maximumYear = NativeHtmlDateValue.parse(control.max ?? '')?.year;
    final minimumYear = NativeHtmlDateValue.parse(control.min ?? '')?.year;
    // Chromium's default date editor reserves the platform maximum year
    // (275760) when max is absent; a finite max narrows the year segment.
    // Keep a wider min/current year visible when range constraints conflict.
    final yearDigits = <int>[
      maximumYear?.toString().length ?? 6,
      minimumYear?.toString().length ?? 0,
      currentDate?.year.toString().length ?? 0,
      4,
    ].reduce(math.max);
    final effectiveFontSize = scaler.scale(measurementStyle.fontSize ?? 14);
    for (final segment in segments) {
      final placeholder = locale.placeholder(segment.name);
      final currentText = state.segmentControllerFor(control.key, segment).text;
      final sample = switch (segment) {
        NativeHtmlDateSegment.month || NativeHtmlDateSegment.day => '88',
        NativeHtmlDateSegment.year => '0' * yearDigits,
      };
      final sampleLayout = measure(sample);
      final placeholderLayout = measure(placeholder);
      final displayedLayout = measure(
        currentText.isEmpty ? placeholder : currentText,
      );
      lineHeight = math.max(lineHeight, displayedLayout.height);
      widths[segment] =
          math.max(
            math.max(sampleLayout.width, placeholderLayout.width),
            displayedLayout.width,
          ) +
          2;
    }

    var separatorWidth = 0.0;
    for (var index = 0; index + 1 < segments.length; index++) {
      separatorWidth += measure(locale.separator).width;
    }
    final segmentWidth = widths.values.fold<double>(
      0,
      (sum, width) => sum + width,
    );
    final baselineText = segments
        .map((segment) {
          final value = state.segmentControllerFor(control.key, segment).text;
          return value.isEmpty ? locale.placeholder(segment.name) : value;
        })
        .join(locale.separator);
    final baselineLayout = measure(baselineText);
    // Blink date-edit fields have 1px block padding on each side.
    final rowBaseline =
        1 +
        (lineHeight - baselineLayout.height) / 2 +
        (baselineLayout.computeDistanceToActualBaseline(
          TextBaseline.alphabetic,
        ));
    final calendarWidth = effectiveFontSize + 4;
    return _NativeHtmlDateMetrics(
      segmentWidths: widths,
      rowHeight: lineHeight + 2,
      rowBaseline: rowBaseline,
      calendarWidth: calendarWidth,
      calendarIconSize: effectiveFontSize,
      rowWidth: segmentWidth + separatorWidth + calendarWidth,
    );
  }

  Size _cssIntrinsicSize(
    NativeHtmlControlBoxStyle style,
    _NativeHtmlDateMetrics metrics,
  ) {
    const constraints = BoxConstraints();
    final padding = style.resolvePadding(constraints);
    final border = style.border;
    final natural = Size(
      metrics.rowWidth + padding.horizontal + border.dimensions.horizontal,
      metrics.rowHeight + padding.vertical + border.dimensions.vertical,
    );
    return style
        .resolveLayout(
          intrinsicBorderBoxSize: natural,
          constraints: constraints,
        )
        .size;
  }
}

class _NativeHtmlDateMetrics {
  const _NativeHtmlDateMetrics({
    required this.segmentWidths,
    required this.rowHeight,
    required this.rowBaseline,
    required this.calendarWidth,
    required this.calendarIconSize,
    required this.rowWidth,
  });

  final Map<NativeHtmlDateSegment, double> segmentWidths;
  final double rowHeight;
  final double rowBaseline;
  final double calendarWidth;
  final double calendarIconSize;
  final double rowWidth;
}

/// The compact calendar button and anchored overlay for one date field.
class NativeHtmlDateCalendarButton extends StatefulWidget {
  const NativeHtmlDateCalendarButton({
    super.key,
    required this.state,
    required this.control,
    required this.locale,
    required this.width,
    required this.height,
    required this.iconSize,
  });

  final NativeHtmlDateState state;
  final NativeHtmlDateDescriptor control;
  final NativeHtmlDateLocale locale;
  final double width;
  final double height;
  final double iconSize;

  @override
  State<NativeHtmlDateCalendarButton> createState() =>
      _NativeHtmlDateCalendarButtonState();
}

class _NativeHtmlDateCalendarButtonState
    extends State<NativeHtmlDateCalendarButton> {
  final LayerLink _layerLink = LayerLink();
  final GlobalKey _anchorKey = GlobalKey();
  OverlayEntry? _popupEntry;
  NativeHtmlDateState? _observedState;
  int? _openRevision;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Document windows are retained offstage. Their OverlayEntries are rooted
    // above the document subtree, so explicitly dismiss this popup when its
    // owning surface is made inactive.
    if (!TickerMode.valuesOf(context).enabled && _popupEntry != null) {
      _closePopup();
    }
  }

  @override
  void didUpdateWidget(covariant NativeHtmlDateCalendarButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state ||
        oldWidget.control.key != widget.control.key) {
      _closePopup();
    }
  }

  @override
  void dispose() {
    _closePopup();
    super.dispose();
  }

  void _openPopup(BuildContext context) {
    if (!widget.control.mutable || _popupEntry != null) return;
    final state = widget.state;
    final control = widget.control;
    final revision = state.revisionFor(control.key);
    if (revision == null) return;

    final supportedFirst = NativeHtmlDateValue.parse('0001-01-01')!;
    final supportedLast = NativeHtmlDateValue.parse('9999-12-31')!;
    final minValue = NativeHtmlDateValue.parse(control.min ?? '');
    final maxValue = NativeHtmlDateValue.parse(control.max ?? '');
    final first = minValue != null && minValue > supportedFirst
        ? minValue
        : supportedFirst;
    final last = maxValue != null && maxValue < supportedLast
        ? maxValue
        : supportedLast;
    if (first > last) return;
    final firstSelectable = NativeHtmlDateValidation.firstSelectable(
      from: first,
      through: last,
      min: control.min,
      max: control.max,
      step: control.step,
      valueAttribute: control.valueAttribute,
      stepBase: control.stepBase,
    );
    final minimumDate = first.toDateTime();
    final maximumDate = last.toDateTime();
    final firstDate = firstSelectable?.toDateTime();
    if (minimumDate == null || maximumDate == null || firstDate == null) {
      return;
    }

    final existing = state.dateFor(control.key)?.toDateTime();
    final initial =
        existing != null &&
            !existing.isBefore(minimumDate) &&
            !existing.isAfter(maximumDate) &&
            NativeHtmlDateValidation.isSelectable(
              date: NativeHtmlDateValue.fromDateTime(existing)!,
              min: control.min,
              max: control.max,
              step: control.step,
              valueAttribute: control.valueAttribute,
              stepBase: control.stepBase,
            )
        ? existing
        : _todayIfSelectable(minimumDate, maximumDate, firstDate, control);

    final anchor = _anchorKey.currentContext?.findRenderObject();
    final overlay = Overlay.of(context);
    final overlayRender = overlay.context.findRenderObject();
    if (anchor is! RenderBox || overlayRender is! RenderBox) return;
    final anchorOrigin = anchor.localToGlobal(
      Offset.zero,
      ancestor: overlayRender,
    );
    final anchorRect = anchorOrigin & anchor.size;
    final overlaySize = overlayRender.size;
    final inputTextScaler = MediaQuery.textScalerOf(context);
    final textScale = inputTextScaler.scale(1);
    final requestedWidth = math.max(216.0, 216.0 * textScale);
    final popupWidth = math
        .min(requestedWidth, math.max(180.0, overlaySize.width - 16))
        .toDouble();
    final estimatedHeight = 292.0 * textScale;
    final alignRight = anchorRect.right + popupWidth > overlaySize.width - 8;
    final above =
        overlaySize.height - anchorRect.bottom < estimatedHeight &&
        anchorRect.top > estimatedHeight;
    final targetAnchor = Alignment(alignRight ? 1 : -1, above ? -1 : 1);
    final followerAnchor = Alignment(alignRight ? 1 : -1, above ? 1 : -1);
    final idealLeft = alignRight
        ? anchorRect.right - popupWidth
        : anchorRect.left;
    final clampedLeft = idealLeft.clamp(
      8.0,
      math.max(8.0, overlaySize.width - popupWidth - 8),
    );
    final horizontalOffset = clampedLeft - idealLeft;

    _openRevision = revision;
    _observedState = state..addListener(_onStateChanged);
    _popupEntry = OverlayEntry(
      builder: (overlayContext) => Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: Semantics(
              label: widget.locale.dismiss,
              button: true,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _closePopup,
                child: const ColoredBox(color: Colors.transparent),
              ),
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            child: CompositedTransformFollower(
              link: _layerLink,
              showWhenUnlinked: false,
              targetAnchor: targetAnchor,
              followerAnchor: followerAnchor,
              offset: Offset(horizontalOffset, above ? -8 : 8),
              child: SizedBox(
                width: popupWidth,
                child: MediaQuery(
                  data: MediaQuery.of(
                    overlayContext,
                  ).copyWith(textScaler: inputTextScaler),
                  child: NativeHtmlDateCalendar(
                    locale: widget.locale,
                    initialMonth: initial,
                    initialFocusDate: initial,
                    selectedDate: existing,
                    minimum: minimumDate,
                    maximum: maximumDate,
                    min: control.min,
                    max: control.max,
                    step: control.step,
                    valueAttribute: control.valueAttribute,
                    stepBase: control.stepBase,
                    width: popupWidth,
                    onSelect: (date) =>
                        _selectDate(state, control, revision, date),
                    onDismiss: _closePopup,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    overlay.insert(_popupEntry!);
  }

  DateTime _todayIfSelectable(
    DateTime minimum,
    DateTime maximum,
    DateTime fallback,
    NativeHtmlDateDescriptor control,
  ) {
    final now = DateTime.now();
    final today = DateTime.utc(now.year, now.month, now.day);
    if (today.isBefore(minimum) || today.isAfter(maximum)) return fallback;
    final value = NativeHtmlDateValue.fromDateTime(today);
    if (value == null) return fallback;
    return NativeHtmlDateValidation.isSelectable(
          date: value,
          min: control.min,
          max: control.max,
          step: control.step,
          valueAttribute: control.valueAttribute,
          stepBase: control.stepBase,
        )
        ? today
        : fallback;
  }

  void _selectDate(
    NativeHtmlDateState state,
    NativeHtmlDateDescriptor control,
    int revision,
    NativeHtmlDateValue? value,
  ) {
    if (!mounted ||
        _popupEntry == null ||
        !TickerMode.valuesOf(context).enabled ||
        state.revisionFor(control.key) != revision) {
      _closePopup();
      return;
    }
    if (value == null) {
      state.clear(control.key);
    } else {
      state.setDateIfUnchanged(control.key, revision, value);
    }
    _closePopup();
  }

  void _onStateChanged() {
    final state = _observedState;
    final key = widget.control.key;
    if (state == null || state.revisionFor(key) != _openRevision) {
      _closePopup();
    }
  }

  void _closePopup() {
    final observed = _observedState;
    if (observed != null) observed.removeListener(_onStateChanged);
    _observedState = null;
    _openRevision = null;
    final entry = _popupEntry;
    _popupEntry = null;
    if (entry != null) {
      entry.remove();
      entry.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    final width = widget.width;
    final height = widget.height;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return CompositedTransformTarget(
      key: _anchorKey,
      link: _layerLink,
      child: IconButton(
        key: ValueKey('native-html-date-calendar-${widget.control.key}'),
        tooltip: widget.locale.chooseDate,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: BoxConstraints.tightFor(width: width, height: height),
        style: IconButton.styleFrom(
          minimumSize: Size(width, height),
          maximumSize: Size(width, height),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: dark ? Colors.white70 : const Color(0xff303030),
        ),
        onPressed: widget.control.mutable ? () => _openPopup(context) : null,
        icon: Icon(Icons.calendar_today_outlined, size: widget.iconSize),
      ),
    );
  }
}

class _DateRecord {
  _DateRecord({
    required this.descriptor,
    required this.value,
    required this.badInput,
    required this.controllers,
    required this.focusNodes,
    required this.widgetKey,
  }) : lastSegmentValues = {
         for (final segment in NativeHtmlDateSegment.values)
           segment: controllers[segment]?.text ?? '',
       };

  final NativeHtmlDateDescriptor descriptor;
  String value;
  bool badInput;
  bool userEdited = false;
  int revision = 0;
  List<NativeHtmlDateSegment> displayOrder = const [
    NativeHtmlDateSegment.month,
    NativeHtmlDateSegment.day,
    NativeHtmlDateSegment.year,
  ];
  final Map<NativeHtmlDateSegment, TextEditingController> controllers;
  final Map<NativeHtmlDateSegment, FocusNode> focusNodes;
  final Map<NativeHtmlDateSegment, String> lastSegmentValues;
  GlobalKey widgetKey;
}

class _PendingDate {
  const _PendingDate({
    required this.key,
    required this.element,
    required this.initialValue,
    required this.valueAttribute,
    required this.min,
    required this.max,
    required this.step,
    required this.stepBase,
    required this.disabled,
    required this.readOnly,
    required this.visible,
    required this.required,
    required this.name,
  });

  final String key;
  final dom.Element element;
  final String initialValue;
  final String? valueAttribute;
  final String? min;
  final String? max;
  final String? step;
  final NativeHtmlDateValue stepBase;
  final bool disabled;
  final bool readOnly;
  final bool visible;
  final bool required;
  final String? name;
}
