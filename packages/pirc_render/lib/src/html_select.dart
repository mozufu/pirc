import 'render_l10n.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

export 'html_select_widget.dart';

sealed class NativeHtmlSelectEntry {
  const NativeHtmlSelectEntry();
}

@immutable
class NativeHtmlSelectGroup extends NativeHtmlSelectEntry {
  const NativeHtmlSelectGroup({
    required this.label,
    required this.beforeOption,
    required this.disabled,
  });
  final String label;
  final int beforeOption;
  final bool disabled;
}

@immutable
class NativeHtmlSelectOption extends NativeHtmlSelectEntry {
  const NativeHtmlSelectOption({
    required this.index,
    required this.value,
    required this.text,
    required this.label,
    required this.disabled,
    required this.group,
  });

  final int index;
  final String value;
  final String text;
  final String label;
  final bool disabled;
  final String? group;
}

@immutable
class NativeHtmlSelectDescriptor {
  const NativeHtmlSelectDescriptor({
    required this.key,
    required this.name,
    required this.label,
    required this.hint,
    required this.disabled,
    required this.visible,
    required this.multiple,
    required this.size,
    required this.displaySize,
    required this.options,
    required this.groups,
    this.scriptId,
  });

  final String key;
  final String? name;
  final String label;
  final String hint;
  final bool disabled;
  final bool visible;
  final bool multiple;

  /// The parsed `size` content attribute. Its HTML default is zero.
  final int size;

  /// The number of rows used by the browser's select display-size algorithm.
  final int displaySize;
  final List<NativeHtmlSelectOption> options;
  final List<NativeHtmlSelectGroup> groups;
  final String? scriptId;

  Iterable<NativeHtmlSelectEntry> get entries sync* {
    var group = 0;
    for (var index = 0; index <= options.length; index++) {
      while (group < groups.length && groups[group].beforeOption == index) {
        yield groups[group++];
      }
      if (index < options.length) yield options[index];
    }
  }
}

/// Per-document selectedness and focus state for native HTML select elements.
///
/// Keep this state while rebuilding the same sanitized document to retain user
/// selections. Create and dispose a new instance when the document changes.
class NativeHtmlSelectState extends ChangeNotifier {
  NativeHtmlSelectState._(this._source, this._nonce);

  factory NativeHtmlSelectState.fromHtml(String sanitizedHtml) {
    final nonce = List.generate(
      12,
      (_) =>
          math.Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final state = NativeHtmlSelectState._(sanitizedHtml, nonce);
    state._scanAndAnnotate();
    return state;
  }

  static const _controlAttribute = 'data-pirc-native-select-id';
  static const _labelAttribute = 'data-pirc-native-select-for';
  static const _markerPrefix = 'data-pirc-native-select-';

  final String _source;
  final String _nonce;
  late final String _annotatedHtml;
  final Map<String, _SelectRecord> _records = {};

  void Function(String key, String type)? onUserEvent;
  void Function(String key, String type, Map<String, dynamic> eventData)?
  onDetailedUserEvent;
  Future<bool> Function(
    String key,
    String type,
    Map<String, dynamic> eventData,
  )?
  onUserKeyEvent;
  String? _lastFocusedKey;
  bool _disposed = false;

  /// Returns markup for HtmlWidget's independently parsed DOM.
  String annotateHtml(String sanitizedHtml) {
    if (sanitizedHtml != _source) {
      throw ArgumentError.value(
        sanitizedHtml,
        'sanitizedHtml',
        tr("Must be the exact fragment used to create this select state."),
      );
    }
    return _annotatedHtml;
  }

  void _scanAndAnnotate() {
    final fragment = html.parseFragment(_source);
    final elements = _elements(fragment).toList();

    // Discard authored marker lookalikes before attaching nonce-qualified IDs.
    for (final element in elements) {
      for (final name
          in element.attributes.keys
              .where((name) => '$name'.startsWith(_markerPrefix))
              .toList()) {
        element.attributes.remove(name);
      }
    }

    final firstById = <String, dom.Element>{};
    for (final element in elements) {
      final id = element.attributes['id'];
      if (id != null && id.isNotEmpty) firstById.putIfAbsent(id, () => element);
    }

    final pending = <_PendingSelect>[];
    var ordinal = 0;
    for (final element in elements.where(
      (element) => element.localName == 'select',
    )) {
      final key = '$_nonce-$ordinal';
      ordinal++;
      final multiple = element.attributes.containsKey('multiple');
      final size = _nonNegativeInteger(element.attributes['size']) ?? 0;
      final displaySize = size > 0 ? size : (multiple ? 4 : 1);
      final options = <_PendingOption>[];
      final groups = <NativeHtmlSelectGroup>[];
      _collectOptions(element, options, groups);

      final explicitlySelected = options
          .where((option) => option.element.attributes.containsKey('selected'))
          .toList();
      final selected = <int>{};
      if (multiple) {
        selected.addAll(explicitlySelected.map((option) => option.index));
      } else if (explicitlySelected.isNotEmpty) {
        // In malformed single-select markup, the last selected option wins.
        selected.add(explicitlySelected.last.index);
      } else if (displaySize == 1) {
        final firstEnabled = options
            .where((option) => !option.disabled)
            .firstOrNull;
        if (firstEnabled != null) selected.add(firstEnabled.index);
      }

      element.attributes[_controlAttribute] = key;
      final pendingSelect = _PendingSelect(
        key: key,
        element: element,
        name: element.attributes['name'],
        disabled:
            element.attributes.containsKey('disabled') ||
            _disabledByFieldset(element),
        visible: _visibleForNavigation(element),
        multiple: multiple,
        size: size,
        displaySize: displaySize,
        options: options,
        groups: groups,
        selected: selected,
      );
      pending.add(pendingSelect);
    }

    final pendingByElement = {
      for (final select in pending) select.element: select,
    };
    final labels = <String, List<String>>{};
    for (final label in elements.where(
      (element) => element.localName == 'label',
    )) {
      final target = _labelTarget(label, firstById, pendingByElement);
      if (target == null) continue;
      final select = pendingByElement[target]!;
      label.attributes[_labelAttribute] = select.key;
      final text = _accessibleText(
        label,
        pendingByElement,
        skipLabel: true,
        excludeSelects: true,
      );
      if (text.isNotEmpty) (labels[select.key] ??= []).add(text);
    }

    for (final select in pending) {
      final labelledBy = _referencedText(
        select.element.attributes['aria-labelledby'],
        firstById,
        pendingByElement,
      );
      final describedBy = _referencedText(
        select.element.attributes['aria-describedby'],
        firstById,
        pendingByElement,
      );
      final ariaLabel = select.element.attributes['aria-label']?.trim();
      final associatedLabels = labels[select.key] ?? const <String>[];
      final label = labelledBy.isNotEmpty
          ? labelledBy
          : ariaLabel?.isNotEmpty == true
          ? ariaLabel!
          : associatedLabels.isNotEmpty
          ? associatedLabels.join(' ')
          : _normalize(select.element.attributes['title'] ?? '');
      final hint = describedBy.isNotEmpty
          ? describedBy
          : _normalize(select.element.attributes['aria-description'] ?? '');
      final options = List<NativeHtmlSelectOption>.unmodifiable(
        select.options.map(
          (option) => NativeHtmlSelectOption(
            index: option.index,
            value: option.value,
            text: option.text,
            label: option.label,
            disabled: option.disabled || select.disabled,
            group: option.group,
          ),
        ),
      );
      final descriptor = NativeHtmlSelectDescriptor(
        key: select.key,
        name: select.name,
        label: label,
        hint: hint,
        disabled: select.disabled,
        visible: select.visible,
        multiple: select.multiple,
        size: select.size,
        displaySize: select.displaySize,
        options: options,
        groups: List.unmodifiable(select.groups),
        scriptId: select.element.attributes['data-pirc-script-id'],
      );
      final record = _SelectRecord(
        descriptor: descriptor,
        selected: select.selected,
        focusNode: FocusNode(
          debugLabel: label.isEmpty ? 'HTML select' : label,
          canRequestFocus: !select.disabled && select.visible,
          skipTraversal: select.disabled || !select.visible,
        ),
        widgetKey: GlobalKey(),
      );
      _records[select.key] = record;
      _attachFocusListener(select.key, record);
    }

    _annotatedHtml = fragment.outerHtml;
  }

  NativeHtmlSelectDescriptor? resolveControl(dom.Element element) {
    if (element.localName != 'select') return null;
    final key = element.attributes[_controlAttribute];
    final record = key == null ? null : _records[key];
    return record?.descriptor;
  }

  NativeHtmlSelectDescriptor? resolveLabel(dom.Element label) {
    if (label.localName != 'label') return null;
    final key = label.attributes[_labelAttribute];
    return key == null ? null : _records[key]?.descriptor;
  }

  /// Activating a label focuses its select without changing selectedness.
  void activateLabel(dom.Element label) {
    final control = resolveLabel(label);
    if (control == null || control.disabled || !control.visible) return;
    focusControl(control.key);
  }

  void focusControl(String key) {
    final record = _recordFor(key);
    if (record.descriptor.disabled || !record.descriptor.visible) return;
    record.focusNode.requestFocus();
  }

  FocusNode focusNodeFor(String key) => _recordFor(key).focusNode;

  bool hasLogicalFocus(String key) => _recordFor(key).logicalFocus;

  /// Keeps a native popup logically focused while Flutter moves focus into its
  /// route. Closing the popup checks focus after the caller's refocus microtask.
  void setPopupOpen(String key, bool open) {
    final record = _records[key];
    if (_disposed || record == null || record.popupOpen == open) return;
    record.popupOpen = open;
    if (open) {
      _syncReportedFocus(key, record);
      return;
    }
    scheduleMicrotask(() {
      final owner = record.owner;
      final ownerKey = record.ownerKey;
      if (owner == null ||
          owner._disposed ||
          ownerKey == null ||
          !identical(owner._records[ownerKey], record)) {
        return;
      }
      owner._syncReportedFocus(ownerKey, record);
    });
  }

  /// Reports a real pointer activation after any focus notifications.
  void recordUserClick(String key, {int? optionIndex}) {
    final record = _records[key];
    if (_disposed || record == null) return;
    scheduleMicrotask(() {
      final owner = record.owner;
      final ownerKey = record.ownerKey;
      if (owner == null ||
          owner._disposed ||
          ownerKey == null ||
          !identical(owner._records[ownerKey], record)) {
        return;
      }
      owner.onDetailedUserEvent?.call(ownerKey, 'click', {
        'optionIndex': ?optionIndex,
      });
    });
  }

  List<int> selectedIndices(String key) {
    final record = _recordFor(key);
    return List<int>.unmodifiable(record.selected.toList()..sort());
  }

  /// Restores matched option selectedness from a document history entry.
  /// Unlike [select], this can restore disabled options and an empty selection.
  /// Options absent from [selectedness] keep their current (source) state.
  void restoreHistorySelectedness(String key, Map<int, bool> selectedness) {
    final record = _records[key];
    if (record == null || selectedness.isEmpty) return;
    final before = Set<int>.of(record.selected);
    if (record.descriptor.multiple) {
      for (final entry in selectedness.entries) {
        if (entry.key < 0 || entry.key >= record.descriptor.options.length) {
          continue;
        }
        if (entry.value) {
          record.selected.add(entry.key);
        } else {
          record.selected.remove(entry.key);
        }
      }
    } else {
      final selected = selectedness.entries
          .where((entry) => entry.value)
          .map((entry) => entry.key)
          .where(
            (index) => index >= 0 && index < record.descriptor.options.length,
          )
          .firstOrNull;
      if (selected != null) {
        record.selected
          ..clear()
          ..add(selected);
      } else {
        for (final index in selectedness.keys) {
          record.selected.remove(index);
        }
      }
    }
    if (!_sameSet(before, record.selected)) notifyListeners();
  }

  /// Transfers focus and widget identity for uniquely identified selects.
  /// The new state retains its freshly parsed selectedness and descriptor.
  /// [preserveValues] is for presentation changes of an unchanged static DOM;
  /// script publications keep fresh DOM values and authored reset defaults.
  void adoptInteractionState(
    NativeHtmlSelectState previous, {
    bool preserveValues = false,
  }) {
    if (identical(this, previous) || _disposed || previous._disposed) return;
    final oldById = _uniqueRecordsByScriptId(previous._records);
    final newById = _uniqueRecordsByScriptId(_records);
    for (final entry in newById.entries) {
      final old = oldById[entry.key];
      if (old == null) continue;
      final oldRecord = old.value;
      final newRecord = entry.value.value;
      if (preserveValues) {
        newRecord.selected
          ..clear()
          ..addAll(
            oldRecord.selected.where(
              (index) =>
                  index >= 0 && index < newRecord.descriptor.options.length,
            ),
          );
      }
      previous._detachFocusListener(oldRecord);
      _detachFocusListener(newRecord);
      newRecord.focusNode.dispose();
      newRecord
        ..focusNode = oldRecord.focusNode
        ..focusNode.canRequestFocus =
            !newRecord.descriptor.disabled && newRecord.descriptor.visible
        ..focusNode.skipTraversal =
            newRecord.descriptor.disabled || !newRecord.descriptor.visible
        ..widgetKey = oldRecord.widgetKey
        ..popupOpen = oldRecord.popupOpen
        ..lastReportedFocus = oldRecord.lastReportedFocus
        ..owner = this
        ..ownerKey = entry.value.key;
      previous._records.remove(old.key);
      if (previous._lastFocusedKey == old.key) {
        previous._lastFocusedKey = null;
        _lastFocusedKey = entry.value.key;
      }
      _attachFocusListener(
        entry.value.key,
        newRecord,
        preserveReportedFocus: true,
      );
      oldRecord.owner = null;
      oldRecord.ownerKey = null;
    }
  }

  GlobalKey widgetKeyFor(String key) => _recordFor(key).widgetKey;

  /// Form reset also restores defaults on disabled selects/options.
  void resetDefaults(Iterable<String> keys) {
    for (final key in keys) {
      final record = _records[key];
      if (record == null) continue;
      record.selected
        ..clear()
        ..addAll(record.initialSelected);
    }
    notifyListeners();
  }

  /// Mirrors the DOM select `value` getter: first selected option or empty.
  String valueFor(String key) {
    final record = _recordFor(key);
    final index = record.selected.isEmpty
        ? null
        : record.selected.reduce(math.min);
    if (index == null) return '';
    return record.descriptor.options[index].value;
  }

  /// Replaces user selectedness in one atomic step, emitting one input/change
  /// pair if the selection changed. Disabled options retain their selectedness
  /// in multiple selects, matching the per-option behavior of the native UI.
  bool selectIndices(String key, Iterable<int> indices) {
    final record = _recordFor(key);
    final descriptor = record.descriptor;
    if (descriptor.disabled) return false;
    final requested = indices.toSet();
    final selectable = <int>{
      for (final option in descriptor.options)
        if (!option.disabled && requested.contains(option.index)) option.index,
    };
    final next = Set<int>.of(record.selected);
    if (descriptor.multiple) {
      for (final option in descriptor.options) {
        if (option.disabled) continue;
        if (selectable.contains(option.index)) {
          next.add(option.index);
        } else {
          next.remove(option.index);
        }
      }
    } else {
      if (selectable.isEmpty) return false;
      next
        ..clear()
        ..add(selectable.last);
    }
    if (_sameSet(record.selected, next)) return false;
    record.selected
      ..clear()
      ..addAll(next);
    notifyListeners();
    _emitUserChange(key);
    return true;
  }

  /// Sets or toggles an option's selectedness without requesting focus.
  ///
  /// In a single select, selecting an option clears its peers. Passing
  /// `selected: false` clears that option; this also permits representing the
  /// browser's `selectedIndex = -1` state for single selects.
  bool select(String key, int index, {bool? selected}) {
    final record = _recordFor(key);
    final descriptor = record.descriptor;
    if (descriptor.disabled ||
        index < 0 ||
        index >= descriptor.options.length) {
      return false;
    }
    final option = descriptor.options[index];
    if (option.disabled) return false;
    final shouldSelect =
        selected ??
        (descriptor.multiple ? !record.selected.contains(index) : true);
    final before = Set<int>.of(record.selected);
    if (descriptor.multiple) {
      if (shouldSelect) {
        record.selected.add(index);
      } else {
        record.selected.remove(index);
      }
    } else if (shouldSelect) {
      record.selected
        ..clear()
        ..add(index);
    } else {
      record.selected.remove(index);
    }
    if (_sameSet(before, record.selected)) return false;
    notifyListeners();
    _emitUserChange(key);
    return true;
  }

  void _emitUserChange(String key) {
    onUserEvent?.call(key, 'input');
    onDetailedUserEvent?.call(key, 'input', const <String, dynamic>{});
    onUserEvent?.call(key, 'change');
    onDetailedUserEvent?.call(key, 'change', const <String, dynamic>{});
  }

  void _attachFocusListener(
    String key,
    _SelectRecord record, {
    bool preserveReportedFocus = false,
  }) {
    record
      ..owner = this
      ..ownerKey = key;
    if (!preserveReportedFocus) {
      record.lastReportedFocus = record.logicalFocus;
      if (record.lastReportedFocus) _lastFocusedKey = key;
    }
    void listener() {
      final owner = record.owner;
      final ownerKey = record.ownerKey;
      if (owner == null ||
          owner._disposed ||
          ownerKey == null ||
          !identical(owner._records[ownerKey], record)) {
        return;
      }
      owner._syncReportedFocus(ownerKey, record);
    }

    record.focusListener = listener;
    record.focusNode.addListener(listener);
  }

  void _syncReportedFocus(String key, _SelectRecord record) {
    final hasFocus = record.logicalFocus;
    if (record.lastReportedFocus == hasFocus) return;
    record.lastReportedFocus = hasFocus;
    if (hasFocus) {
      final relatedTarget = _scriptIdForKey(_lastFocusedKey, except: key);
      onDetailedUserEvent?.call(key, 'focus', {'relatedTarget': relatedTarget});
      onDetailedUserEvent?.call(key, 'focusin', {
        'relatedTarget': relatedTarget,
      });
      _lastFocusedKey = key;
      return;
    }

    final relatedTarget = _currentlyFocusedScriptId(except: key);
    onDetailedUserEvent?.call(key, 'blur', {'relatedTarget': relatedTarget});
    onDetailedUserEvent?.call(key, 'focusout', {
      'relatedTarget': relatedTarget,
    });
    scheduleMicrotask(() {
      if (!_disposed &&
          _lastFocusedKey == key &&
          _currentlyFocusedKey(except: key) == null) {
        _lastFocusedKey = null;
      }
    });
  }

  String? _scriptIdForKey(String? key, {String? except}) {
    if (key == null || key == except) return null;
    return _records[key]?.descriptor.scriptId;
  }

  String? _currentlyFocusedScriptId({String? except}) {
    for (final entry in _records.entries) {
      if (entry.key != except && entry.value.logicalFocus) {
        return entry.value.descriptor.scriptId;
      }
    }
    return null;
  }

  String? _currentlyFocusedKey({String? except}) {
    for (final entry in _records.entries) {
      if (entry.key != except && entry.value.logicalFocus) return entry.key;
    }
    return null;
  }

  void _detachFocusListener(_SelectRecord record) {
    final listener = record.focusListener;
    if (listener != null) {
      record.focusNode.removeListener(listener);
      record.focusListener = null;
    }
  }

  Map<String, MapEntry<String, _SelectRecord>> _uniqueRecordsByScriptId(
    Map<String, _SelectRecord> records,
  ) {
    final grouped = <String, List<MapEntry<String, _SelectRecord>>>{};
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

  _SelectRecord _recordFor(String key) {
    final record = _records[key];
    if (record == null) throw StateError(tr("Unknown HTML select: {0}", [key]));
    return record;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final record in _records.values) {
      _detachFocusListener(record);
      record
        ..owner = null
        ..ownerKey = null;
      record.focusNode.dispose();
    }
    _records.clear();
    onUserEvent = null;
    onDetailedUserEvent = null;
    onUserKeyEvent = null;
    super.dispose();
  }

  static bool _sameSet(Set<int> first, Set<int> second) =>
      first.length == second.length && first.containsAll(second);

  void _collectOptions(
    dom.Element select,
    List<_PendingOption> output,
    List<NativeHtmlSelectGroup> groups,
  ) {
    void visit(
      dom.Element parent, {
      String? group,
      bool groupDisabled = false,
    }) {
      for (final child in parent.children) {
        switch (child.localName) {
          case 'option':
            final text = _optionText(child);
            final index = output.length;
            final hasValue = child.attributes.containsKey('value');
            final hasLabel = child.attributes.containsKey('label');
            output.add(
              _PendingOption(
                element: child,
                index: index,
                text: text,
                value: hasValue ? child.attributes['value'] ?? '' : text,
                label: hasLabel ? child.attributes['label'] ?? '' : text,
                disabled:
                    child.attributes.containsKey('disabled') || groupDisabled,
                group: group,
              ),
            );
          case 'optgroup':
            final groupName = _optgroupLabel(child);
            groups.add(
              NativeHtmlSelectGroup(
                label: groupName,
                beforeOption: output.length,
                disabled:
                    groupDisabled || child.attributes.containsKey('disabled'),
              ),
            );
            visit(
              child,
              group: groupName,
              groupDisabled:
                  groupDisabled || child.attributes.containsKey('disabled'),
            );
          case 'select' || 'datalist' || 'hr':
            // These descendants are not options of the outer select.
            break;
          default:
            visit(child, group: group, groupDisabled: groupDisabled);
        }
      }
    }

    visit(select);
  }

  String _optionText(dom.Element option) {
    final buffer = StringBuffer();
    void append(dom.Node node) {
      if (node is dom.Text) {
        buffer.write(node.text);
      } else if (node is dom.Element && node.localName != 'script') {
        for (final child in node.nodes) {
          append(child);
        }
      }
    }

    for (final child in option.nodes) {
      append(child);
    }
    return _normalizeAsciiWhitespace(buffer.toString());
  }

  String _optgroupLabel(dom.Element optgroup) {
    final legend = optgroup.children
        .where((child) => child.localName == 'legend')
        .firstOrNull;
    if (legend != null) return _accessibleText(legend, const {});
    return optgroup.attributes['label'] ?? '';
  }

  String _referencedText(
    String? ids,
    Map<String, dom.Element> firstById,
    Map<dom.Element, _PendingSelect> pendingByElement,
  ) {
    if (ids == null) return '';
    return _normalize(
      ids
          .split(RegExp(r'[\t\n\f\r ]+'))
          .where((id) => id.isNotEmpty)
          .map((id) {
            final element = firstById[id];
            return element == null
                ? ''
                : _accessibleText(element, pendingByElement);
          })
          .where((text) => text.isNotEmpty)
          .join(' '),
    );
  }

  String _accessibleText(
    dom.Element element,
    Map<dom.Element, _PendingSelect> pendingByElement, {
    bool skipLabel = false,
    bool excludeSelects = false,
  }) {
    final buffer = StringBuffer();
    void append(dom.Node node) {
      if (node is dom.Text) {
        buffer.write(node.text);
        return;
      }
      if (node is! dom.Element) return;
      if (skipLabel && !identical(node, element) && node.localName == 'label') {
        return;
      }
      if (node.localName == 'select') {
        if (excludeSelects) return;
        final select = pendingByElement[node];
        if (select != null && select.selected.isNotEmpty) {
          final firstIndex = select.selected.reduce(math.min);
          buffer.write(select.options[firstIndex].label);
        }
        return;
      }
      for (final child in node.nodes) {
        append(child);
      }
    }

    append(element);
    return _normalize(buffer.toString());
  }

  dom.Element? _labelTarget(
    dom.Element label,
    Map<String, dom.Element> firstById,
    Map<dom.Element, _PendingSelect> selects,
  ) {
    if (label.attributes.containsKey('for')) {
      final id = label.attributes['for'];
      final target = id == null ? null : firstById[id];
      return target != null &&
              _isLabelable(target) &&
              selects.containsKey(target)
          ? target
          : null;
    }
    for (final element in _labelDescendants(label)) {
      if (!_isLabelable(element)) continue;
      return selects.containsKey(element) ? element : null;
    }
    return null;
  }

  bool _isLabelable(dom.Element element) {
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
        final exempt = firstLegend != null && _isWithin(element, firstLegend);
        if (!exempt) return true;
      }
      parent = parent.parentNode;
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
          _styleHides(current.attributes['style'] ?? '') ||
          current.localName == 'template') {
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

  static int? _nonNegativeInteger(String? value) {
    if (value == null) return null;
    final match = RegExp(r'^[\t\n\f\r ]*\+?([0-9]+)').firstMatch(value);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  static String _normalizeAsciiWhitespace(String text) => text
      .replaceAll(RegExp(r'[\t\n\f\r ]+'), ' ')
      .replaceAll(RegExp(r'^ | $'), '');

  static String _normalize(String text) =>
      text.replaceAll(RegExp(r'\s+'), ' ').trim();

  static Iterable<dom.Element> _elements(dom.Node parent) sync* {
    for (final child in parent.nodes) {
      if (child is dom.Element) {
        yield child;
        yield* _elements(child);
      }
    }
  }
}

class _PendingSelect {
  const _PendingSelect({
    required this.key,
    required this.element,
    required this.name,
    required this.disabled,
    required this.visible,
    required this.multiple,
    required this.size,
    required this.displaySize,
    required this.options,
    required this.groups,
    required this.selected,
  });

  final String key;
  final dom.Element element;
  final String? name;
  final bool disabled;
  final bool visible;
  final bool multiple;
  final int size;
  final int displaySize;
  final List<_PendingOption> options;
  final List<NativeHtmlSelectGroup> groups;
  final Set<int> selected;
}

class _PendingOption {
  const _PendingOption({
    required this.element,
    required this.index,
    required this.text,
    required this.value,
    required this.label,
    required this.disabled,
    required this.group,
  });

  final dom.Element element;
  final int index;
  final String text;
  final String value;
  final String label;
  final bool disabled;
  final String? group;
}

class _SelectRecord {
  _SelectRecord({
    required this.descriptor,
    required this.selected,
    required this.focusNode,
    required this.widgetKey,
  }) : initialSelected = Set<int>.of(selected);

  final Set<int> initialSelected;
  final NativeHtmlSelectDescriptor descriptor;
  final Set<int> selected;
  FocusNode focusNode;
  GlobalKey widgetKey;
  VoidCallback? focusListener;
  NativeHtmlSelectState? owner;
  String? ownerKey;
  bool popupOpen = false;
  bool lastReportedFocus = false;

  bool get logicalFocus => popupOpen || focusNode.hasFocus;
}
