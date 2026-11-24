import 'render_l10n.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

@immutable
class NativeHtmlRangeDescriptor {
  const NativeHtmlRangeDescriptor({
    required this.key,
    required this.initialValue,
    required this.min,
    required this.max,
    required this.step,
    required this.effectiveMin,
    required this.effectiveMax,
    required this.stepBase,
    required this.effectiveStep,
    required this.stepAny,
    required this.disabled,
    required this.readOnly,
    required this.visible,
    required this.required,
    required this.willValidate,
    required this.name,
    required this.label,
    required this.hint,
    this.scriptId,
  });

  final String key;

  /// The browser-sanitized default value restored by an HTML form reset.
  final String initialValue;

  /// Literal source attributes. Invalid attributes remain available as metadata.
  final String? min;
  final String? max;
  final String? step;

  /// Effective numeric range and increment after the browser defaults apply.
  final String effectiveMin;
  final String effectiveMax;
  final String stepBase;
  final String? effectiveStep;
  final bool stepAny;
  final bool disabled;
  final bool readOnly;
  final bool visible;
  final bool required;
  final bool willValidate;
  final String? name;
  final String label;
  final String hint;
  final String? scriptId;
}

/// Per-document state for sanitized `<input type="range">` controls.
///
/// Keep the state while rebuilding the same HTML fragment. Create and dispose
/// it when the document is replaced. Range values always remain numeric and
/// browser-sanitized; readonly is retained as metadata because Chromium range
/// controls remain keyboard and pointer interactive when that attribute exists.
class NativeHtmlRangeState extends ChangeNotifier {
  NativeHtmlRangeState._(this._source, this._nonce);

  factory NativeHtmlRangeState.fromHtml(String sanitizedHtml) {
    final nonce = List.generate(
      12,
      (_) =>
          math.Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final state = NativeHtmlRangeState._(sanitizedHtml, nonce);
    state._scanAndAnnotate();
    return state;
  }

  static const _controlAttribute = 'data-pirc-native-range-id';
  static const _labelAttribute = 'data-pirc-native-range-for';
  static const _markerPrefix = 'data-pirc-native-range-';

  final String _source;
  final String _nonce;
  late final String _annotatedHtml;
  final Map<String, _RangeRecord> _records = {};
  final Set<String> _pendingPointerChanges = {};

  void Function(String key, String type)? onUserEvent;

  String annotateHtml(String sanitizedHtml) {
    if (sanitizedHtml != _source) {
      throw ArgumentError.value(
        sanitizedHtml,
        'sanitizedHtml',
        tr("Must be the exact fragment used to create this range state."),
      );
    }
    return _annotatedHtml;
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

    final pending = <_PendingRange>[];
    var ordinal = 0;
    for (final element in elements) {
      if (!_isRange(element)) continue;
      final bounds = _boundsFor(element);
      final stepBase =
          _rangeNumber(element.attributes['min']) ??
          _rangeNumber(element.attributes['value']) ??
          _ExactRangeNumber.zero;
      final step = _stepFor(element.attributes['step'], stepBase);
      final initial = _initialValue(element, bounds, step);
      final key = '$_nonce-${ordinal++}';
      final item = _PendingRange(
        key: key,
        element: element,
        min: element.attributes['min'],
        max: element.attributes['max'],
        rawStep: element.attributes['step'],
        bounds: bounds,
        stepSpec: step,
        initialValue: initial.toString(),
        disabled:
            element.attributes.containsKey('disabled') ||
            _disabledByFieldset(element),
        readOnly: element.attributes.containsKey('readonly'),
        visible: _visibleForNavigation(element),
        required: element.attributes.containsKey('required'),
        name: element.attributes['name'],
      );
      element.attributes[_controlAttribute] = key;
      pending.add(item);
    }

    final pendingByElement = {for (final item in pending) item.element: item};
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

    for (final item in pending) {
      final labelledBy = _referencedText(
        item.element.attributes['aria-labelledby'],
        firstById,
      );
      final describedBy = _referencedText(
        item.element.attributes['aria-describedby'],
        firstById,
      );
      final ariaLabel = item.element.attributes['aria-label']?.trim();
      final associatedLabels = labels[item.key] ?? const <String>[];
      final label = labelledBy.isNotEmpty
          ? labelledBy
          : ariaLabel?.isNotEmpty == true
          ? ariaLabel!
          : associatedLabels.isNotEmpty
          ? associatedLabels.join(' ')
          : _normalize(item.element.attributes['title'] ?? '');
      final hint = describedBy.isNotEmpty
          ? describedBy
          : _normalize(item.element.attributes['aria-description'] ?? '');
      final descriptor = NativeHtmlRangeDescriptor(
        key: item.key,
        initialValue: item.initialValue,
        min: item.min,
        max: item.max,
        step: item.rawStep,
        effectiveMin: item.bounds.minimum.toString(),
        effectiveMax: item.bounds.maximum.toString(),
        stepBase: item.stepSpec.base.toString(),
        effectiveStep: item.stepSpec.value?.toString(),
        stepAny: item.stepSpec.any,
        disabled: item.disabled,
        readOnly: item.readOnly,
        visible: item.visible,
        required: item.required,
        willValidate: !item.disabled && !item.readOnly,
        name: item.name,
        label: label,
        hint: hint,
        scriptId: item.element.attributes['data-pirc-script-id'],
      );
      _records[item.key] = _RangeRecord(
        descriptor: descriptor,
        bounds: item.bounds,
        step: item.stepSpec,
        value: _ExactRangeNumber.parse(item.initialValue)!,
        focusNode: FocusNode(
          debugLabel: label.isEmpty ? 'HTML range' : label,
          canRequestFocus: !item.disabled && item.visible,
          skipTraversal: item.disabled || !item.visible,
        ),
        gestureKey: GlobalKey(),
      );
    }
    _annotatedHtml = fragment.outerHtml;
  }

  NativeHtmlRangeDescriptor? resolveControl(dom.Element element) {
    final key = element.attributes[_controlAttribute];
    final record = key == null ? null : _records[key];
    return record != null && _isRange(element) ? record.descriptor : null;
  }

  NativeHtmlRangeDescriptor? resolveLabel(dom.Element label) {
    if (label.localName != 'label') return null;
    final key = label.attributes[_labelAttribute];
    return key == null ? null : _records[key]?.descriptor;
  }

  void activateLabel(dom.Element label) {
    final control = resolveLabel(label);
    if (control == null || control.disabled || !control.visible) return;
    focusControl(control.key);
  }

  void focusControl(String key) {
    final record = _records[key];
    if (record == null ||
        record.descriptor.disabled ||
        !record.descriptor.visible) {
      return;
    }
    record.focusNode.requestFocus();
  }

  FocusNode focusNodeFor(String key) => _recordFor(key).focusNode;

  GlobalKey gestureKeyFor(String key) => _recordFor(key).gestureKey;

  String valueFor(String key) => _recordFor(key).value.toString();

  /// Preserves active native gesture/focus resources across a same-document
  /// script snapshot. Values and descriptors remain those of this new state.
  /// [preserveValues] is for presentation changes of an unchanged static DOM;
  /// script publications keep fresh DOM values and authored reset defaults.
  void adoptInteractionState(
    NativeHtmlRangeState previous, {
    bool preserveValues = false,
  }) {
    if (identical(this, previous)) return;
    final oldById = _uniqueRecordsByScriptId(previous._records);
    final newById = _uniqueRecordsByScriptId(_records);
    for (final entry in newById.entries) {
      final old = oldById[entry.key];
      if (old == null) continue;
      final oldKey = old.key;
      final newKey = entry.value.key;
      final oldRecord = old.value;
      final newRecord = entry.value.value;
      if (preserveValues) newRecord.value = oldRecord.value;
      newRecord.focusNode.dispose();
      newRecord
        ..focusNode = oldRecord.focusNode
        ..focusNode.canRequestFocus =
            !newRecord.descriptor.disabled && newRecord.descriptor.visible
        ..focusNode.skipTraversal =
            newRecord.descriptor.disabled || !newRecord.descriptor.visible
        ..gestureKey = oldRecord.gestureKey;
      if (previous._pendingPointerChanges.remove(oldKey)) {
        _pendingPointerChanges.add(newKey);
      }
      previous._records.remove(oldKey);
    }
  }

  Map<String, MapEntry<String, _RangeRecord>> _uniqueRecordsByScriptId(
    Map<String, _RangeRecord> records,
  ) {
    final grouped = <String, List<MapEntry<String, _RangeRecord>>>{};
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

  /// Restore each specified control's browser-sanitized source default.
  /// Disabled and readonly controls are reset too, as in an HTML form reset.
  void resetDefaults(Iterable<String> keys) {
    var changed = false;
    for (final key in keys) {
      _pendingPointerChanges.remove(key);
      final record = _records[key];
      if (record == null) continue;
      final initial = _ExactRangeNumber.parse(record.descriptor.initialValue)!;
      if (initial == record.value) continue;
      record.value = initial;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// Apply one keyboard step. Page Up/Down pass `multiplier: 10`.
  bool stepRange(String key, {required int direction, int multiplier = 1}) {
    final record = _records[key];
    if (!_canChange(record) || direction == 0 || multiplier <= 0) return false;
    _pendingPointerChanges.remove(key);
    final range = record!.bounds.maximum - record.bounds.minimum;
    final increment = record.step.any
        ? _ExactRangeNumber.fromDouble(range.toDouble() / 100)
        : record.step.value!;
    final raw = record.value + increment * (direction.sign * multiplier);
    final changed = _store(record, _sanitizeUserValue(record, raw));
    if (changed) _emitUserChange(key);
    return changed;
  }

  /// Move to Home or End. End uses the greatest step-aligned value <= max.
  bool setRangeBoundary(String key, {required bool maximum}) {
    final record = _records[key];
    if (!_canChange(record)) return false;
    _pendingPointerChanges.remove(key);
    final value = maximum ? _lastStepValue(record!) : _firstStepValue(record!);
    final changed = _store(record, value);
    if (changed) _emitUserChange(key);
    return changed;
  }

  /// Set the value from a pointer gesture as a fraction from 0 to 1.
  bool setRangeFraction(String key, double fraction) {
    final record = _records[key];
    if (!_canChange(record) || !fraction.isFinite) return false;
    final safeFraction = fraction.clamp(0.0, 1.0);
    final width = record!.bounds.maximum - record.bounds.minimum;
    final raw = _ExactRangeNumber.fromDouble(
      record.bounds.minimum.toDouble() + width.toDouble() * safeFraction,
    );
    return _storePointer(record, _sanitizeUserValue(record, raw), key);
  }

  /// Set an accessibility or programmatic user value, clamping and snapping it
  /// the same way as the browser's range value sanitization.
  bool setRangeValue(String key, num value) {
    final record = _records[key];
    if (!_canChange(record) || !value.isFinite) return false;
    _pendingPointerChanges.remove(key);
    return _store(
      record!,
      _sanitizeUserValue(
        record,
        _ExactRangeNumber.fromDouble(value.toDouble()),
      ),
    );
  }

  /// Starts one pointer transaction; stale canceled transactions cannot commit.
  void beginUserRangeChange(String key) => _pendingPointerChanges.remove(key);

  /// Emits `change` once if the active pointer transaction changed the value.
  bool commitUserRangeChange(String key) {
    if (!_pendingPointerChanges.remove(key)) return false;
    onUserEvent?.call(key, 'change');
    return true;
  }

  void cancelUserRangeChange(String key) => _pendingPointerChanges.remove(key);

  void _emitUserChange(String key) {
    final callback = onUserEvent;
    callback?.call(key, 'input');
    callback?.call(key, 'change');
  }

  bool _canChange(_RangeRecord? record) =>
      record != null &&
      !record.descriptor.disabled &&
      record.descriptor.visible;

  bool _store(_RangeRecord record, _ExactRangeNumber value) {
    if (record.value == value) return false;
    record.value = value;
    notifyListeners();
    return true;
  }

  bool _storePointer(_RangeRecord record, _ExactRangeNumber value, String key) {
    if (record.value == value) return false;
    record.value = value;
    _pendingPointerChanges.add(key);
    notifyListeners();
    onUserEvent?.call(key, 'input');
    return true;
  }

  _ExactRangeNumber _sanitizeUserValue(
    _RangeRecord record,
    _ExactRangeNumber raw,
  ) {
    final bounded = raw.clamp(record.bounds.minimum, record.bounds.maximum);
    if (record.step.any || record.bounds.minimum == record.bounds.maximum) {
      return bounded;
    }
    return _nearestStep(
      bounded,
      record.step.base,
      record.step.value!,
      record.bounds.minimum,
      record.bounds.maximum,
    );
  }

  _ExactRangeNumber _lastStepValue(_RangeRecord record) {
    if (record.bounds.minimum == record.bounds.maximum || record.step.any) {
      return record.bounds.maximum;
    }
    final scale = _scaleOf([
      record.step.base,
      record.bounds.minimum,
      record.bounds.maximum,
      record.step.value!,
    ]);
    final maximum = record.bounds.maximum.unitsAt(scale);
    final stepBase = record.step.base.unitsAt(scale);
    final step = record.step.value!.unitsAt(scale);
    final index = _floorDivideBig(maximum - stepBase, step);
    final candidate = stepBase + index * step;
    return _ExactRangeNumber.fromUnits(
      candidate < record.bounds.minimum.unitsAt(scale)
          ? record.bounds.minimum.unitsAt(scale)
          : candidate,
      scale,
    );
  }

  _ExactRangeNumber _firstStepValue(_RangeRecord record) {
    if (record.bounds.minimum == record.bounds.maximum || record.step.any) {
      return record.bounds.minimum;
    }
    final scale = _scaleOf([
      record.step.base,
      record.bounds.minimum,
      record.bounds.maximum,
      record.step.value!,
    ]);
    final minimum = record.bounds.minimum.unitsAt(scale);
    final maximum = record.bounds.maximum.unitsAt(scale);
    final base = record.step.base.unitsAt(scale);
    final step = record.step.value!.unitsAt(scale);
    final index = _ceilDivideBig(minimum - base, step);
    final candidate = base + index * step;
    return _ExactRangeNumber.fromUnits(
      candidate > maximum ? minimum : candidate,
      scale,
    );
  }

  _RangeRecord _recordFor(String key) {
    final record = _records[key];
    if (record == null) throw StateError(tr("Unknown HTML range: {0}", [key]));
    return record;
  }

  @override
  void dispose() {
    for (final record in _records.values) {
      record.focusNode.dispose();
    }
    _records.clear();
    _pendingPointerChanges.clear();
    super.dispose();
  }

  static bool _isRange(dom.Element element) =>
      element.localName == 'input' &&
      (element.attributes['type'] ?? '').toLowerCase() == 'range';

  static _RangeBounds _boundsFor(dom.Element element) {
    final minimum =
        _rangeNumber(element.attributes['min']) ?? _ExactRangeNumber.zero;
    var maximum =
        _rangeNumber(element.attributes['max']) ??
        _ExactRangeNumber.fromInt(100);
    if (maximum < minimum) maximum = minimum;
    return _RangeBounds(minimum, maximum);
  }

  static _RangeStep _stepFor(String? source, _ExactRangeNumber base) {
    if (source?.toLowerCase() == 'any') return _RangeStep.anyStep(base);
    final parsed = _rangeNumber(source);
    return _RangeStep(
      parsed != null && parsed > _ExactRangeNumber.zero
          ? parsed
          : _ExactRangeNumber.one,
      base,
    );
  }

  static _ExactRangeNumber _initialValue(
    dom.Element element,
    _RangeBounds bounds,
    _RangeStep step,
  ) {
    final source = element.attributes['value'];
    final parsed = source == null ? null : _rangeNumber(source);
    final raw = parsed ?? _midpoint(bounds.minimum, bounds.maximum);
    final bounded = raw.clamp(bounds.minimum, bounds.maximum);
    if (step.any || bounds.minimum == bounds.maximum) return bounded;
    return _nearestStep(
      bounded,
      step.base,
      step.value!,
      bounds.minimum,
      bounds.maximum,
    );
  }

  static _ExactRangeNumber _midpoint(
    _ExactRangeNumber minimum,
    _ExactRangeNumber maximum,
  ) {
    final scale = _scaleOf([minimum, maximum]);
    final sum = minimum.unitsAt(scale) + maximum.unitsAt(scale);
    return _ExactRangeNumber.fromUnits(sum * BigInt.from(5), scale + 1);
  }

  static _ExactRangeNumber _nearestStep(
    _ExactRangeNumber value,
    _ExactRangeNumber base,
    _ExactRangeNumber step,
    _ExactRangeNumber minimum,
    _ExactRangeNumber maximum,
  ) {
    final scale = _scaleOf([value, base, step, minimum, maximum]);
    final valueUnits = value.unitsAt(scale);
    final baseUnits = base.unitsAt(scale);
    final minimumUnits = minimum.unitsAt(scale);
    final stepUnits = step.unitsAt(scale);
    final maximumUnits = maximum.unitsAt(scale);
    final delta = valueUnits - baseUnits;
    var index = _floorDivideBig(delta, stepUnits);
    final remainder = delta - index * stepUnits;
    if (remainder * BigInt.from(2) >= stepUnits) {
      index += BigInt.one;
    }
    final minIndex = _ceilDivideBig(minimumUnits - baseUnits, stepUnits);
    final maxIndex = _floorDivideBig(maximumUnits - baseUnits, stepUnits);
    if (minIndex > maxIndex) {
      return _ExactRangeNumber.fromUnits(
        valueUnits - minimumUnits <= maximumUnits - valueUnits
            ? minimumUnits
            : maximumUnits,
        scale,
      );
    }
    if (index < minIndex) index = minIndex;
    if (index > maxIndex) index = maxIndex;
    return _ExactRangeNumber.fromUnits(baseUnits + index * stepUnits, scale);
  }

  static _ExactRangeNumber? _rangeNumber(String? source) {
    if (source == null || !_isValidRangeNumber(source)) return null;
    return _ExactRangeNumber.parse(source);
  }

  static int _scaleOf(Iterable<_ExactRangeNumber> values) =>
      values.fold<int>(0, (scale, value) => math.max(scale, value.scale));

  static String _referencedText(
    String? ids,
    Map<String, dom.Element> firstById,
  ) {
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

  static dom.Element? _labelTarget(
    dom.Element label,
    Map<String, dom.Element> firstById,
    Map<dom.Element, _PendingRange> ranges,
  ) {
    if (label.attributes.containsKey('for')) {
      final id = label.attributes['for'];
      final target = id == null ? null : firstById[id];
      return target != null && ranges.containsKey(target) ? target : null;
    }
    for (final element in _labelDescendants(label)) {
      if (!_isLabelable(element)) continue;
      return ranges.containsKey(element) ? element : null;
    }
    return null;
  }

  static bool _isLabelable(dom.Element element) {
    if (element.localName == 'input') {
      return (element.attributes['type'] ?? '').toLowerCase() != 'hidden';
    }
    return const {
      'button',
      'meter',
      'output',
      'progress',
      'select',
      'textarea',
    }.contains(element.localName);
  }

  static Iterable<dom.Element> _labelDescendants(dom.Element label) sync* {
    for (final child in label.children) {
      if (child.localName == 'label') continue;
      yield child;
      yield* _labelDescendants(child);
    }
  }

  static bool _disabledByFieldset(dom.Element element) {
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

  static bool _visibleForNavigation(dom.Element element) {
    for (
      dom.Element? current = element;
      current != null;
      current = current.parent
    ) {
      if (current.attributes.containsKey('hidden') ||
          _styleHides(current.attributes['style'] ?? '') ||
          current.localName == 'template') {
        return false;
      }
    }
    return true;
  }

  static bool _styleHides(String style) {
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

  static bool _isWithin(dom.Node node, dom.Node ancestor) {
    for (
      dom.Node? current = node;
      current != null;
      current = current.parentNode
    ) {
      if (identical(current, ancestor)) return true;
    }
    return false;
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
}

class NativeHtmlRangeWidget extends StatelessWidget {
  const NativeHtmlRangeWidget({
    super.key,
    required this.state,
    required this.control,
    required this.focusAccent,
  });

  final NativeHtmlRangeState state;
  final NativeHtmlRangeDescriptor control;
  final Color focusAccent;

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    if (!control.visible) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      widthFactor: 1,
      heightFactor: 1,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: SizedBox(
          width: 129,
          height: 16,
          child: ListenableBuilder(
            listenable: Listenable.merge([
              state,
              state.focusNodeFor(control.key),
            ]),
            builder: (context, child) {
              final value = state.valueFor(control.key);
              final record = state._recordFor(control.key);
              return Semantics(
                key: ValueKey('native-html-range-${control.key}'),
                container: true,
                slider: true,
                enabled: !control.disabled,
                isRequired: control.required,
                label: control.label.isEmpty ? null : control.label,
                hint: control.hint.isEmpty ? null : control.hint,
                value: value,
                minValue: control.effectiveMin,
                maxValue: control.effectiveMax,
                increasedValue: state._prospectiveValue(control.key, 1),
                decreasedValue: state._prospectiveValue(control.key, -1),
                onIncrease: control.disabled
                    ? null
                    : () => state.stepRange(control.key, direction: 1),
                onDecrease: control.disabled
                    ? null
                    : () => state.stepRange(control.key, direction: -1),
                child: Focus(
                  focusNode: record.focusNode,
                  onKeyEvent: (context, event) => _handleKey(event),
                  child: Listener(
                    key: state.gestureKeyFor(control.key),
                    onPointerDown: control.disabled
                        ? null
                        : (_) => state.beginUserRangeChange(control.key),
                    onPointerUp: control.disabled
                        ? null
                        : (_) => state.commitUserRangeChange(control.key),
                    onPointerCancel: control.disabled
                        ? null
                        : (_) => state.cancelUserRangeChange(control.key),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: control.disabled
                          ? null
                          : (details) => _setAt(details.localPosition),
                      onHorizontalDragStart: control.disabled
                          ? null
                          : (details) => _setAt(details.localPosition),
                      onHorizontalDragUpdate: control.disabled
                          ? null
                          : (details) => _setAt(details.localPosition),
                      child: CustomPaint(
                        size: const Size(129, 16),
                        painter: _RangePainter(
                          fraction: _fraction(record),
                          disabled: control.disabled,
                          focused: record.focusNode.hasFocus,
                          dark: Theme.of(context).brightness == Brightness.dark,
                          focusAccent: focusAccent,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  KeyEventResult _handleKey(KeyEvent event) {
    if ((event is! KeyDownEvent && event is! KeyRepeatEvent) ||
        control.disabled) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    switch (key) {
      case LogicalKeyboardKey.arrowUp:
      case LogicalKeyboardKey.arrowRight:
        state.stepRange(control.key, direction: 1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
      case LogicalKeyboardKey.arrowLeft:
        state.stepRange(control.key, direction: -1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.pageUp:
        state.stepRange(control.key, direction: 1, multiplier: 10);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.pageDown:
        state.stepRange(control.key, direction: -1, multiplier: 10);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.home:
        state.setRangeBoundary(control.key, maximum: false);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.end:
        state.setRangeBoundary(control.key, maximum: true);
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  void _setAt(Offset position) {
    // Chromium keeps half a thumb of track on either side of the value range.
    state.focusControl(control.key);
    state.setRangeFraction(control.key, (position.dx - 7) / 115);
  }

  double _fraction(_RangeRecord record) {
    final width = record.bounds.maximum - record.bounds.minimum;
    if (width == _ExactRangeNumber.zero) return 0;
    return ((record.value - record.bounds.minimum).toDouble() /
            width.toDouble())
        .clamp(0.0, 1.0);
  }
}

class _RangePainter extends CustomPainter {
  const _RangePainter({
    required this.fraction,
    required this.disabled,
    required this.focused,
    required this.dark,
    required this.focusAccent,
  });

  final double fraction;
  final bool disabled;
  final bool focused;
  final bool dark;
  final Color focusAccent;

  @override
  void paint(Canvas canvas, Size size) {
    if (focused) {
      final outline = Paint()
        ..color = focusAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(-3, -3, size.width + 6, size.height + 6),
          const Radius.circular(0),
        ),
        outline,
      );
    }

    final trackRect = Rect.fromLTWH(1, 4, size.width - 2, 8);
    final track = RRect.fromRectAndRadius(trackRect, const Radius.circular(4));
    final borderColor = disabled
        ? (dark ? const Color(0xff626262) : const Color(0xffd2d2d2))
        : (dark ? const Color(0xff858585) : const Color(0xffb2b2b2));
    final emptyColor = disabled
        ? (dark ? const Color(0xff363636) : const Color(0xfffafafa))
        : (dark ? const Color(0xff3b3b3b) : const Color(0xffefefef));
    final activeColor = disabled
        ? (dark ? const Color(0xff757575) : const Color(0xffcbcbcb))
        : (dark ? const Color(0xff99c8ff) : const Color(0xff0075ff));

    canvas.drawRRect(track, Paint()..color = borderColor);
    final inner = trackRect.deflate(1);
    canvas.drawRRect(
      RRect.fromRectAndRadius(inner, const Radius.circular(3)),
      Paint()..color = emptyColor,
    );
    final thumbCenterX = 7 + fraction * 115;
    final activeRect = Rect.fromLTRB(
      inner.left,
      inner.top,
      thumbCenterX,
      inner.bottom,
    );
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(inner, const Radius.circular(3)));
    canvas.drawRect(activeRect, Paint()..color = activeColor);
    canvas.restore();
    canvas.drawCircle(Offset(thumbCenterX, 8), 7, Paint()..color = activeColor);
  }

  @override
  bool shouldRepaint(covariant _RangePainter oldDelegate) =>
      fraction != oldDelegate.fraction ||
      disabled != oldDelegate.disabled ||
      focused != oldDelegate.focused ||
      dark != oldDelegate.dark ||
      focusAccent != oldDelegate.focusAccent;
}

class _RangeBounds {
  const _RangeBounds(this.minimum, this.maximum);

  final _ExactRangeNumber minimum;
  final _ExactRangeNumber maximum;
}

class _RangeStep {
  const _RangeStep(this.value, this.base) : any = false;
  const _RangeStep.anyStep(this.base) : value = null, any = true;

  final _ExactRangeNumber? value;
  final _ExactRangeNumber base;
  final bool any;
}

class _PendingRange {
  const _PendingRange({
    required this.key,
    required this.element,
    required this.min,
    required this.max,
    required this.rawStep,
    required this.bounds,
    required this.stepSpec,
    required this.initialValue,
    required this.disabled,
    required this.readOnly,
    required this.visible,
    required this.required,
    required this.name,
  });

  final String key;
  final dom.Element element;
  final String? min;
  final String? max;
  final String? rawStep;
  final _RangeBounds bounds;
  final _RangeStep stepSpec;
  final String initialValue;
  final bool disabled;
  final bool readOnly;
  final bool visible;
  final bool required;
  final String? name;
}

class _RangeRecord {
  _RangeRecord({
    required this.descriptor,
    required this.bounds,
    required this.step,
    required this.value,
    required this.focusNode,
    required this.gestureKey,
  });

  final NativeHtmlRangeDescriptor descriptor;
  final _RangeBounds bounds;
  final _RangeStep step;
  FocusNode focusNode;
  GlobalKey gestureKey;
  _ExactRangeNumber value;
}

bool _isValidRangeNumber(String value) =>
    RegExp(r'^-?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?$').hasMatch(value) &&
    (double.tryParse(value)?.isFinite ?? false);

BigInt _floorDivideBig(BigInt dividend, BigInt divisor) {
  final quotient = dividend ~/ divisor;
  final remainder = dividend.remainder(divisor);
  return dividend.isNegative && remainder != BigInt.zero
      ? quotient - BigInt.one
      : quotient;
}

BigInt _ceilDivideBig(BigInt dividend, BigInt divisor) =>
    -_floorDivideBig(-dividend, divisor);

extension _RangeProspectiveValue on NativeHtmlRangeState {
  String _prospectiveValue(String key, int direction) {
    final record = _recordFor(key);
    if (record.step.any) {
      return (record.value.toDouble() +
              (record.bounds.maximum.toDouble() -
                      record.bounds.minimum.toDouble()) /
                  100 *
                  direction)
          .toString();
    }
    return (record.value + record.step.value! * direction).toString();
  }
}

/// Exact base-10 range arithmetic supports decimal and exponent attributes.
class _ExactRangeNumber implements Comparable<_ExactRangeNumber> {
  const _ExactRangeNumber(this.coefficient, this.scale);

  static final zero = _ExactRangeNumber(BigInt.zero, 0);
  static final one = _ExactRangeNumber(BigInt.one, 0);

  final BigInt coefficient;
  final int scale;

  static _ExactRangeNumber? parse(String value) {
    if (!_isValidRangeNumber(value)) return null;
    final match = RegExp(
      r'^(-?)(\d*)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$',
    ).firstMatch(value);
    if (match == null) return null;
    final whole = match.group(2)!;
    final fractional = match.group(3) ?? '';
    final exponent = int.tryParse(match.group(4) ?? '0');
    if (exponent == null || exponent.abs() > 308) return null;
    final digits = '${whole.isEmpty ? '0' : whole}$fractional';
    final magnitude = BigInt.tryParse(digits);
    if (magnitude == null) return null;
    var parsedCoefficient = match.group(1) == '-' ? -magnitude : magnitude;
    var parsedScale = fractional.length - exponent;
    if (parsedScale < 0) {
      parsedCoefficient *= BigInt.from(10).pow(-parsedScale);
      parsedScale = 0;
    }
    if (parsedScale > 308) return null;
    return _normalized(parsedCoefficient, parsedScale);
  }

  factory _ExactRangeNumber.fromInt(int value) =>
      _ExactRangeNumber(BigInt.from(value), 0);

  factory _ExactRangeNumber.fromUnits(BigInt units, int scale) =>
      _normalized(units, scale);

  factory _ExactRangeNumber.fromDouble(double value) {
    final source = value.toStringAsPrecision(14);
    return parse(source) ?? zero;
  }

  static _ExactRangeNumber _normalized(BigInt coefficient, int scale) {
    var normalizedCoefficient = coefficient;
    var normalizedScale = scale;
    while (normalizedScale > 0 &&
        normalizedCoefficient.remainder(BigInt.from(10)) == BigInt.zero) {
      normalizedCoefficient ~/= BigInt.from(10);
      normalizedScale--;
    }
    return _ExactRangeNumber(normalizedCoefficient, normalizedScale);
  }

  BigInt unitsAt(int targetScale) =>
      coefficient * BigInt.from(10).pow(targetScale - scale);

  _ExactRangeNumber clamp(
    _ExactRangeNumber minimum,
    _ExactRangeNumber maximum,
  ) {
    if (this < minimum) return minimum;
    if (this > maximum) return maximum;
    return this;
  }

  double toDouble() => double.parse(toString());

  bool operator <(_ExactRangeNumber other) => compareTo(other) < 0;

  bool operator >(_ExactRangeNumber other) => compareTo(other) > 0;

  @override
  int compareTo(_ExactRangeNumber other) {
    final scale = math.max(this.scale, other.scale);
    return unitsAt(scale).compareTo(other.unitsAt(scale));
  }

  @override
  bool operator ==(Object other) =>
      other is _ExactRangeNumber && compareTo(other) == 0;

  @override
  int get hashCode => toString().hashCode;

  _ExactRangeNumber operator +(_ExactRangeNumber other) {
    final scale = math.max(this.scale, other.scale);
    return _normalized(unitsAt(scale) + other.unitsAt(scale), scale);
  }

  _ExactRangeNumber operator -(_ExactRangeNumber other) {
    final scale = math.max(this.scale, other.scale);
    return _normalized(unitsAt(scale) - other.unitsAt(scale), scale);
  }

  _ExactRangeNumber operator *(int factor) =>
      _normalized(coefficient * BigInt.from(factor), scale);

  @override
  String toString() {
    if (coefficient == BigInt.zero) return '0';
    final negative = coefficient.isNegative;
    final digits = (negative ? -coefficient : coefficient).toString();
    if (scale == 0) return '${negative ? '-' : ''}$digits';
    final padded = digits.padLeft(scale + 1, '0');
    final point = padded.length - scale;
    var fractional = padded.substring(point);
    while (fractional.endsWith('0')) {
      fractional = fractional.substring(0, fractional.length - 1);
    }
    return '${negative ? '-' : ''}${padded.substring(0, point)}.$fractional';
  }
}
