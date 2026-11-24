import 'render_l10n.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'html_control_box_style.dart';
import 'html_control_border_painter.dart';
import 'html_keyboard_events.dart';
import 'html_input_sizing.dart';
import 'html_control_intrinsic.dart';

enum NativeHtmlTextFieldKind {
  text,
  search,
  email,
  url,
  tel,
  password,
  number,
  textarea,
}

@immutable
class NativeHtmlTextFieldDescriptor {
  const NativeHtmlTextFieldDescriptor({
    required this.key,
    required this.kind,
    required this.initialValue,
    required this.disabled,
    required this.readOnly,
    required this.visible,
    required this.required,
    required this.name,
    required this.label,
    required this.hint,
    required this.placeholder,
    required this.maxLength,
    required this.minLength,
    required this.rows,
    required this.cols,
    required this.size,
    required this.min,
    required this.max,
    required this.step,
  });

  final String key;
  final NativeHtmlTextFieldKind kind;
  final String initialValue;
  final bool disabled;
  final bool readOnly;
  final bool visible;

  /// Metadata only; form validation is not implemented by this slice.
  final bool required;
  final String? name;
  final String label;
  final String hint;
  final String? placeholder;
  final int? maxLength;

  /// Metadata only; form validation is not implemented by this slice.
  final int? minLength;

  final int rows;
  final int cols;
  final int size;
  final String? min;
  final String? max;
  final String? step;
}

/// Per-document editable state for native HTML text inputs and textareas.
///
/// Reuse this object when rebuilding the same sanitized document to retain
/// edits. Create and dispose a new state when the source document is replaced.
class NativeHtmlTextFieldState extends ChangeNotifier {
  NativeHtmlTextFieldState._(this._source, this._nonce);

  factory NativeHtmlTextFieldState.fromHtml(String sanitizedHtml) {
    final nonce = List.generate(
      12,
      (_) =>
          math.Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final state = NativeHtmlTextFieldState._(sanitizedHtml, nonce);
    state._scanAndAnnotate();
    return state;
  }

  static const _controlAttribute = 'data-pirc-native-text-field-id';
  static const _labelAttribute = 'data-pirc-native-text-field-for';
  static const _markerPrefix = 'data-pirc-native-text-field-';
  static const _unsupportedInputTypes = <String>{
    'button',
    'checkbox',
    'color',
    'date',
    'datetime-local',
    'file',
    'hidden',
    'image',
    'month',
    'radio',
    'range',
    'reset',
    'submit',
    'time',
    'week',
  };

  final String _source;
  final String _nonce;
  late final String _annotatedHtml;
  final Map<String, _TextFieldRecord> _records = {};
  final Map<String, String> _scriptIdByKey = {};
  final Set<String> _userEdited = {};
  final Set<String> _pendingChanges = {};
  void Function(String key, String type)? onUserEvent;
  void Function(String key, String type, Map<String, dynamic> eventData)?
  onDetailedUserEvent;
  Future<bool> Function(
    String key,
    String type,
    Map<String, dynamic> eventData,
  )?
  onUserKeyEvent;
  ValueChanged<String>? onSubmit;
  String? _lastFocusedKey;
  bool _disposed = false;
  bool wasUserEdited(String key) => _userEdited.contains(key);
  void submit(String key) => onSubmit?.call(key);

  /// Records the user edit used by form bookkeeping without dispatching a
  /// script event. History restoration uses this path as well.
  void recordUserEdit(String key, {bool invalidatePendingKeyEvent = true}) {
    if (invalidatePendingKeyEvent) _records[key]?.keyEventGeneration++;
    _userEdited.add(key);
    _valueChanged();
  }

  /// Records a real edit from the text editor and dispatches its input event.
  void recordUserInput(String key) {
    if (_disposed) return;
    final record = _records[key];
    if (record == null) return;
    record.keyEventGeneration++;
    _userEdited.add(key);
    _pendingChanges.add(key);
    _valueChanged();
    final edit = record.pendingUserEdit;
    if (edit != null && edit.newValue.text == record.controller.text) {
      record.pendingUserEdit = null;
      final endsComposition =
          _isComposing(edit.oldValue) && !_isComposing(record.controller.value);
      if (endsComposition) {
        _emitFinalCompositionUpdate(key, record, edit);
      } else {
        _emitCompositionEvents(key, record, edit);
      }
      _emitUserEvent(
        key,
        'input',
        _inputEventData(edit.oldValue, record.controller.value),
      );
      if (endsComposition) _emitCompositionEvents(key, record, edit);
      record.lastUserValue = record.controller.value;
      return;
    }
    _emitUserEvent(
      key,
      'input',
      _inputEventData(record.lastUserValue, record.controller.value),
    );
    record.lastUserValue = record.controller.value;
  }

  void recordUserClick(String key) {
    final record = _records[key];
    if (_disposed || record == null) return;
    // FocusManager queues focus notifications when TextField requests focus
    // on tap-down. Queue click afterward so scripts observe focus before click.
    scheduleMicrotask(() {
      final owner = record.owner;
      final ownerKey = record.ownerKey;
      if (owner == null ||
          owner._disposed ||
          ownerKey == null ||
          !identical(owner._records[ownerKey], record)) {
        return;
      }
      owner.onDetailedUserEvent?.call(
        ownerKey,
        'click',
        const <String, dynamic>{},
      );
    });
  }

  void _emitUserEvent(String key, String type, Map<String, dynamic> eventData) {
    onUserEvent?.call(key, type);
    onDetailedUserEvent?.call(key, type, eventData);
  }

  void _stageUserEdit(
    String key,
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final record = _records[key];
    if (_disposed || record == null || oldValue == newValue) return;
    final edit = _UserTextEdit(oldValue, newValue);
    record.pendingUserEdit = edit;

    // Some IMEs commit a composing range without changing the text. In that
    // case onChanged does not run, but the controller value is committed
    // synchronously after formatEditUpdate returns. Flush in the next
    // microtask so script listeners observe the committed controller value.
    scheduleMicrotask(() {
      if (_disposed ||
          !identical(_records[key], record) ||
          !identical(record.pendingUserEdit, edit)) {
        return;
      }
      if (record.controller.value != edit.newValue) {
        record.pendingUserEdit = null;
        return;
      }
      record.pendingUserEdit = null;
      _emitCompositionEvents(key, record, edit);
      record.lastUserValue = edit.newValue;
    });
  }

  void _emitFinalCompositionUpdate(
    String key,
    _TextFieldRecord record,
    _UserTextEdit edit,
  ) {
    if (!record.userCompositionActive && !_isComposing(edit.oldValue)) return;
    final data = _inputEventData(edit.oldValue, edit.newValue)['data'];
    if (data is! String || data.isEmpty || data == record.userCompositionData) {
      return;
    }
    onDetailedUserEvent?.call(key, 'compositionupdate', {'data': data});
    record.userCompositionData = data;
  }

  void _emitCompositionEvents(
    String key,
    _TextFieldRecord record,
    _UserTextEdit edit,
  ) {
    final previousComposing = _isComposing(edit.oldValue);
    final nextComposing = _isComposing(edit.newValue);
    final previousData = _composingData(edit.oldValue);
    final nextData = _composingData(edit.newValue);

    if (nextComposing) {
      if (!record.userCompositionActive) {
        onDetailedUserEvent?.call(key, 'compositionstart', const {'data': ''});
        record.userCompositionActive = true;
        record.userCompositionData = '';
      }
      if (nextData != record.userCompositionData || !previousComposing) {
        onDetailedUserEvent?.call(key, 'compositionupdate', {'data': nextData});
      }
      record.userCompositionData = nextData;
      return;
    }

    if (record.userCompositionActive || previousComposing) {
      onDetailedUserEvent?.call(key, 'compositionend', {
        'data': record.userCompositionData.isEmpty
            ? previousData
            : record.userCompositionData,
      });
      record.userCompositionActive = false;
      record.userCompositionData = '';
    }
  }

  bool _isComposing(TextEditingValue value) =>
      value.composing.isValid && !value.composing.isCollapsed;

  String _composingData(TextEditingValue value) {
    if (!_isComposing(value) || value.composing.end > value.text.length) {
      return '';
    }
    return value.text.substring(value.composing.start, value.composing.end);
  }

  Map<String, dynamic> _inputEventData(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final oldText = oldValue.text;
    final newText = newValue.text;
    var prefix = 0;
    while (prefix < oldText.length &&
        prefix < newText.length &&
        oldText.codeUnitAt(prefix) == newText.codeUnitAt(prefix)) {
      prefix++;
    }
    // Do not split an emoji/supplementary character at a shared UTF-16 unit.
    bool splitsPair(String text, int index) =>
        index > 0 &&
        index < text.length &&
        text.codeUnitAt(index - 1) >= 0xd800 &&
        text.codeUnitAt(index - 1) <= 0xdbff &&
        text.codeUnitAt(index) >= 0xdc00 &&
        text.codeUnitAt(index) <= 0xdfff;
    if (splitsPair(newText, prefix) || splitsPair(oldText, prefix)) prefix--;
    var oldEnd = oldText.length;
    var newEnd = newText.length;
    while (oldEnd > prefix &&
        newEnd > prefix &&
        oldText.codeUnitAt(oldEnd - 1) == newText.codeUnitAt(newEnd - 1)) {
      oldEnd--;
      newEnd--;
    }
    if (splitsPair(newText, newEnd) || splitsPair(oldText, oldEnd)) {
      oldEnd++;
      newEnd++;
    }
    final inserted = newText.substring(prefix, newEnd);
    final removed = oldText.substring(prefix, oldEnd);
    final composing = _isComposing(newValue);
    final wasComposing = _isComposing(oldValue);
    final inputType = composing
        ? 'insertCompositionText'
        : wasComposing
        ? 'insertFromComposition'
        : removed.isEmpty
        ? 'insertText'
        : inserted.isEmpty
        ? (oldValue.selection.isCollapsed &&
                  newValue.selection.extentOffset <
                      oldValue.selection.extentOffset
              ? 'deleteContentBackward'
              : 'deleteContentForward')
        : 'insertReplacementText';
    return <String, dynamic>{
      'data': inserted.isEmpty ? null : inserted,
      'inputType': inputType,
      'isComposing': composing,
    };
  }

  /// Adopts live editor objects from the previous document when a unique
  /// script-marked control of the same kind survives a DOM snapshot update.
  /// [preserveValues] is for presentation changes of an unchanged static DOM;
  /// script publications keep fresh DOM values and authored reset defaults.
  void adoptEditingState(
    NativeHtmlTextFieldState previous, {
    bool preserveValues = false,
  }) {
    if (identical(this, previous) || _disposed || previous._disposed) return;
    final previousById = previous._uniqueScriptFields();
    final nextById = _uniqueScriptFields();
    for (final entry in nextById.entries) {
      final oldKeys = previousById[entry.key];
      final newKeys = entry.value;
      if (oldKeys == null || oldKeys.length != 1 || newKeys.length != 1) {
        continue;
      }
      final oldKey = oldKeys.single;
      final newKey = newKeys.single;
      final oldRecord = previous._records[oldKey];
      final newRecord = _records[newKey];
      if (oldRecord == null ||
          newRecord == null ||
          oldRecord.descriptor.kind != newRecord.descriptor.kind) {
        continue;
      }

      previous._detachBlurListener(oldRecord);
      _detachBlurListener(newRecord);
      newRecord.controller.dispose();
      newRecord.focusNode.dispose();

      oldRecord
        ..descriptor = newRecord.descriptor
        ..domId = newRecord.domId
        ..owner = this
        ..ownerKey = newKey;
      oldRecord.focusNode
        ..canRequestFocus =
            !newRecord.descriptor.disabled && newRecord.descriptor.visible
        ..skipTraversal =
            newRecord.descriptor.disabled || !newRecord.descriptor.visible;
      if (!preserveValues &&
          oldRecord.controller.text != newRecord.descriptor.initialValue) {
        final value = newRecord.descriptor.initialValue;
        oldRecord.controller.value = TextEditingValue(
          text: value,
          selection: TextSelection.collapsed(offset: value.length),
          composing: TextRange.empty,
        );
        oldRecord
          ..lastUserValue = oldRecord.controller.value
          ..lastControllerValue = oldRecord.controller.value
          ..userCompositionActive = false
          ..userCompositionData = '';
      }
      _records[newKey] = oldRecord;
      _attachBlurListener(newKey, oldRecord);

      previous._records.remove(oldKey);
      previous._scriptIdByKey.remove(oldKey);
      if (previous._lastFocusedKey == oldKey) previous._lastFocusedKey = null;
      if (previous._userEdited.remove(oldKey)) _userEdited.add(newKey);
      if (previous._pendingChanges.remove(oldKey)) {
        _pendingChanges.add(newKey);
      }
    }
  }

  Map<String, List<String>> _uniqueScriptFields() {
    final matches = <String, List<String>>{};
    for (final entry in _scriptIdByKey.entries) {
      if (!_records.containsKey(entry.key)) continue;
      (matches[entry.value] ??= <String>[]).add(entry.key);
    }
    return matches;
  }

  void _attachBlurListener(String key, _TextFieldRecord record) {
    record.lastReportedFocus = record.focusNode.hasFocus;
    if (record.lastReportedFocus) _lastFocusedKey = key;
    void listener() {
      if (_disposed || !identical(_records[key], record)) return;
      final hasFocus = record.focusNode.hasFocus;
      if (record.lastReportedFocus == hasFocus) return;
      record.lastReportedFocus = hasFocus;
      if (hasFocus) {
        final relatedTarget = _domIdForKey(_lastFocusedKey, except: key);
        onDetailedUserEvent?.call(key, 'focus', {
          'relatedTarget': relatedTarget,
        });
        onDetailedUserEvent?.call(key, 'focusin', {
          'relatedTarget': relatedTarget,
        });
        _lastFocusedKey = key;
        return;
      }

      final relatedTarget = _currentlyFocusedDomId(except: key);
      if (_pendingChanges.remove(key)) {
        _emitUserEvent(key, 'change', const <String, dynamic>{});
      }
      onDetailedUserEvent?.call(key, 'blur', {'relatedTarget': relatedTarget});
      onDetailedUserEvent?.call(key, 'focusout', {
        'relatedTarget': relatedTarget,
      });
      record.keyEventGeneration++;
      if (_lastFocusedKey == key) {
        _lastFocusedKey = _currentlyFocusedKey(except: key);
      }
    }

    record.blurListener = listener;
    record.focusNode.addListener(listener);
    void controllerListener() {
      final value = record.controller.value;
      final previous = record.lastControllerValue;
      record.lastControllerValue = value;
      if (_disposed || !identical(_records[key], record)) return;
      // A formatter marks native text-input updates before EditableText writes
      // the controller. Their callbacks run after the controller commit.
      if (record.pendingUserEdit != null) return;

      if (previous.text != value.text) {
        // Controller writes from script snapshots, reset, and history are
        // observable state changes, not user input or IME composition.
        record.userCompositionActive = false;
        record.userCompositionData = '';
        record.lastUserValue = value;
        return;
      }
      if (!record.focusNode.hasFocus ||
          !record.userCompositionActive ||
          previous.composing == value.composing) {
        return;
      }
      // Flutter skips formatters for composing-range-only platform updates.
      // Once a real IME update has started composition, use this narrow
      // unchanged-text/unchanged-selection path to observe range updates.
      // A direct programmatic range write during an active composition is
      // indistinguishable from that platform update in Flutter's public API.
      if (previous.selection != value.selection) {
        if (!_isComposing(value)) {
          record.userCompositionActive = false;
          record.userCompositionData = '';
        }
        return;
      }
      _emitCompositionEvents(key, record, _UserTextEdit(previous, value));
    }

    record.controllerListener = controllerListener;
    record.controller.addListener(controllerListener);
  }

  String? _domIdForKey(String? key, {String? except}) {
    if (key == null || key == except) return null;
    return _records[key]?.domId;
  }

  String? _currentlyFocusedDomId({String? except}) {
    for (final entry in _records.entries) {
      if (entry.key != except && entry.value.focusNode.hasFocus) {
        return entry.value.domId;
      }
    }
    return null;
  }

  String? _currentlyFocusedKey({String? except}) {
    for (final entry in _records.entries) {
      if (entry.key != except && entry.value.focusNode.hasFocus) {
        return entry.key;
      }
    }
    return null;
  }

  void _detachBlurListener(_TextFieldRecord record) {
    final listener = record.blurListener;
    if (listener != null) {
      record.focusNode.removeListener(listener);
      record.blurListener = null;
    }
    final controllerListener = record.controllerListener;
    if (controllerListener != null) {
      record.controller.removeListener(controllerListener);
      record.controllerListener = null;
    }
  }

  /// Markup for HtmlWidget's independently parsed DOM.
  String annotateHtml(String sanitizedHtml) {
    if (sanitizedHtml != _source) {
      throw ArgumentError.value(
        sanitizedHtml,
        'sanitizedHtml',
        tr("Must be the exact fragment used to create this text-field state."),
      );
    }
    return _annotatedHtml;
  }

  void _scanAndAnnotate() {
    final fragment = html.parseFragment(_source);
    final elements = _elements(fragment).toList();

    // User-authored marker lookalikes are never trusted.
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

    final pending = <_PendingTextField>[];
    var ordinal = 0;
    for (final element in elements) {
      final kind = _kindFor(element);
      if (kind == null) continue;
      final key = '$_nonce-$ordinal';
      ordinal++;
      final scriptId = element.attributes['data-pirc-script-id'];
      if (scriptId != null && scriptId.isNotEmpty) {
        _scriptIdByKey[key] = scriptId;
      }
      final field = _PendingTextField(
        key: key,
        element: element,
        kind: kind,
        initialValue: _initialValue(element, kind),
        disabled:
            element.attributes.containsKey('disabled') ||
            _disabledByFieldset(element),
        readOnly: element.attributes.containsKey('readonly'),
        visible: _visibleForNavigation(element),
        required: element.attributes.containsKey('required'),
        name: element.attributes['name'],
        placeholder: element.attributes['placeholder'],
        maxLength: _nonNegativeInteger(element.attributes['maxlength']),
        minLength: _nonNegativeInteger(element.attributes['minlength']),
        rows: _positiveInteger(element.attributes['rows'], fallback: 2),
        cols: _positiveInteger(element.attributes['cols'], fallback: 20),
        size: _positiveInteger(element.attributes['size'], fallback: 20),
        min: element.attributes['min'],
        max: element.attributes['max'],
        step: element.attributes['step'],
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
      final associatedLabels = labels[field.key] ?? const <String>[];
      final label = labelledBy.isNotEmpty
          ? labelledBy
          : ariaLabel?.isNotEmpty == true
          ? ariaLabel!
          : associatedLabels.isNotEmpty
          ? associatedLabels.join(' ')
          : _normalize(field.element.attributes['title'] ?? '');
      final hint = describedBy.isNotEmpty
          ? describedBy
          : _normalize(field.element.attributes['aria-description'] ?? '');
      final descriptor = NativeHtmlTextFieldDescriptor(
        key: field.key,
        kind: field.kind,
        initialValue: field.initialValue,
        disabled: field.disabled,
        readOnly: field.readOnly,
        visible: field.visible,
        required: field.required,
        name: field.name,
        label: label,
        hint: hint,
        placeholder: field.placeholder,
        maxLength: field.maxLength,
        minLength: field.minLength,
        rows: field.rows,
        cols: field.cols,
        size: field.size,
        min: field.min,
        max: field.max,
        step: field.step,
      );
      final record = _TextFieldRecord(
        descriptor: descriptor,
        controller: TextEditingController(text: field.initialValue),
        focusNode: FocusNode(
          debugLabel: label.isEmpty ? 'HTML ${field.kind.name}' : label,
          canRequestFocus: !field.disabled && field.visible,
          skipTraversal: field.disabled || !field.visible,
        ),
        editorKey: GlobalKey(),
        domId: field.element.attributes['data-pirc-script-id'],
      );
      _records[field.key] = record;
      record
        ..owner = this
        ..ownerKey = field.key;
      _attachBlurListener(field.key, record);
    }
    _annotatedHtml = fragment.outerHtml;
  }

  NativeHtmlTextFieldDescriptor? resolveControl(dom.Element element) {
    final key = element.attributes[_controlAttribute];
    final record = key == null ? null : _records[key];
    if (record == null || _kindFor(element) != record.descriptor.kind) {
      return null;
    }
    return record.descriptor;
  }

  NativeHtmlTextFieldDescriptor? resolveLabel(dom.Element label) {
    if (label.localName != 'label') return null;
    final key = label.attributes[_labelAttribute];
    return key == null ? null : _records[key]?.descriptor;
  }

  /// HTML label activation focuses the associated field and does nothing else.
  void activateLabel(dom.Element label) {
    final field = resolveLabel(label);
    if (field == null || field.disabled || !field.visible) return;
    focusControl(field.key);
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

  /// Reports hardware key events. Only a non-IME Enter press uses the
  /// callback result to cancel native form submission; other keys remain
  /// observational so Flutter and the active IME keep their edit behavior.
  void recordUserKeyEvent(
    String key,
    KeyEvent event, {
    required bool isComposing,
    required bool submitOnEnter,
  }) {
    if (_disposed || !_records.containsKey(key)) return;
    final type = event is KeyUpEvent ? 'keyup' : 'keydown';
    final eventData = nativeHtmlKeyboardEventData(
      event,
      isComposing: isComposing,
    );
    final callback = onUserKeyEvent;
    final isEnterDown =
        event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter);

    if (isEnterDown && submitOnEnter) {
      final record = _records[key]!;
      final sequence = ++record.keyEventGeneration;
      if (callback == null) {
        submit(key);
      } else {
        unawaited(
          _submitAfterKeyEvent(record, sequence, key, callback, eventData),
        );
      }
      return;
    }

    if (event is KeyDownEvent) _records[key]!.keyEventGeneration++;
    if (callback == null) return;
    unawaited(_reportKeyEvent(callback, key, type, eventData));
  }

  Future<void> _submitAfterKeyEvent(
    _TextFieldRecord record,
    int sequence,
    String key,
    Future<bool> Function(
      String key,
      String type,
      Map<String, dynamic> eventData,
    )
    callback,
    Map<String, dynamic> eventData,
  ) async {
    bool prevented;
    try {
      prevented = await callback(key, 'keydown', eventData);
    } catch (_) {
      prevented = true;
    }
    final owner = record.owner;
    final ownerKey = record.ownerKey;
    if (prevented ||
        record.keyEventGeneration != sequence ||
        owner == null ||
        owner._disposed ||
        ownerKey == null ||
        !identical(owner._records[ownerKey], record) ||
        !record.focusNode.hasFocus) {
      return;
    }
    owner.submit(ownerKey);
  }

  Future<void> _reportKeyEvent(
    Future<bool> Function(
      String key,
      String type,
      Map<String, dynamic> eventData,
    )
    callback,
    String key,
    String type,
    Map<String, dynamic> eventData,
  ) async {
    try {
      await callback(key, type, eventData);
    } catch (_) {
      // Observational keys do not affect native text editing.
    }
  }

  /// Returns the state-owned controller, or throws for an unknown key.
  TextEditingController controllerFor(String key) => _recordFor(key).controller;

  /// Returns the state-owned focus node, or throws for an unknown key.
  FocusNode focusNodeFor(String key) => _recordFor(key).focusNode;

  GlobalKey editorKeyFor(String key) => _recordFor(key).editorKey;

  String valueFor(String key) => controllerFor(key).text;

  /// HTML form reset restores defaults even for disabled/read-only fields.
  void resetDefaults(Iterable<String> keys) {
    for (final key in keys) {
      _userEdited.remove(key);
      _pendingChanges.remove(key);
      final record = _records[key];
      if (record == null) continue;
      record.keyEventGeneration++;
      record
        ..pendingUserEdit = null
        ..userCompositionActive = false
        ..userCompositionData = '';
      if (record.controller.text == record.descriptor.initialValue) continue;
      final value = record.descriptor.initialValue;
      record.controller.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
    }
    notifyListeners();
  }

  /// Applies an HTML number spin action. Direct edits remain free to hold
  /// out-of-range values; stepping alone clamps to the declared bounds.
  bool stepNumber(String key, {required int direction}) {
    final record = _records[key];
    if (record == null ||
        record.descriptor.kind != NativeHtmlTextFieldKind.number ||
        record.descriptor.disabled ||
        record.descriptor.readOnly ||
        !record.descriptor.visible ||
        direction == 0) {
      return false;
    }

    final field = record.descriptor;
    final sourceStep = field.step?.toLowerCase();
    final parsedStep = _decimalAttribute(field.step);
    // Chromium's keyboard spin action uses a unit step for step="any".
    final increment =
        sourceStep == 'any' || parsedStep == null || !parsedStep.isPositive
        ? _ExactDecimal.one
        : parsedStep;
    final minimum = _decimalAttribute(field.min);
    final maximum = _decimalAttribute(field.max);
    final base = sourceStep == 'any'
        ? minimum ?? _ExactDecimal.zero
        : minimum ??
              _decimalAttribute(field.initialValue) ??
              _ExactDecimal.zero;
    final current =
        _decimalAttribute(record.controller.text) ?? _ExactDecimal.zero;

    var scale = base.scale;
    if (current.scale > scale) scale = current.scale;
    if (increment.scale > scale) scale = increment.scale;
    if (minimum != null && minimum.scale > scale) scale = minimum.scale;
    if (maximum != null && maximum.scale > scale) scale = maximum.scale;

    final baseUnits = base.unitsAt(scale);
    final currentUnits = current.unitsAt(scale);
    final incrementUnits = increment.unitsAt(scale);
    final delta = currentUnits - baseUnits;
    var result = currentUnits;
    if (sourceStep == 'any') {
      result += incrementUnits * BigInt.from(direction.sign);
    } else {
      final quotient = _floorDivide(delta, incrementUnits);
      final aligned = delta.remainder(incrementUnits) == BigInt.zero;
      final index = direction > 0
          ? quotient + BigInt.one
          : aligned
          ? quotient - BigInt.one
          : quotient;
      result = baseUnits + incrementUnits * index;
    }

    final minimumUnits = minimum?.unitsAt(scale);
    final maximumUnits = maximum?.unitsAt(scale);
    if (minimumUnits != null && result < minimumUnits) {
      result = minimumUnits;
    }
    if (maximumUnits != null && result > maximumUnits) {
      if (sourceStep == 'any') {
        result = maximumUnits;
      } else {
        final highestStep = _floorDivide(
          maximumUnits - baseUnits,
          incrementUnits,
        );
        final highestValue = baseUnits + incrementUnits * highestStep;
        result = minimumUnits != null && highestValue < minimumUnits
            ? minimumUnits
            : highestValue;
      }
    }

    final value = _ExactDecimal(result, scale).toString();
    if (record.controller.text == value) return false;
    record.controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
      composing: TextRange.empty,
    );
    _userEdited.add(key);
    _pendingChanges.remove(key);
    record.keyEventGeneration++;
    _valueChanged();
    final currentValue = record.controller.value;
    _emitUserEvent(
      key,
      'input',
      _inputEventData(record.lastUserValue, currentValue),
    );
    record.lastUserValue = currentValue;
    _emitUserEvent(key, 'change', const <String, dynamic>{});
    return true;
  }

  _TextFieldRecord _recordFor(String key) {
    final record = _records[key];
    if (record == null) {
      throw StateError(tr("Unknown HTML text field: {0}", [key]));
    }
    return record;
  }

  void _valueChanged() => notifyListeners();

  @override
  void dispose() {
    _disposed = true;
    for (final record in _records.values) {
      record.keyEventGeneration++;
      record
        ..owner = null
        ..ownerKey = null;
      _detachBlurListener(record);
      record.controller.dispose();
      record.focusNode.dispose();
    }
    _records.clear();
    _scriptIdByKey.clear();
    _pendingChanges.clear();
    onUserEvent = null;
    onDetailedUserEvent = null;
    onUserKeyEvent = null;
    super.dispose();
  }

  NativeHtmlTextFieldKind? _kindFor(dom.Element element) {
    if (element.localName == 'textarea') {
      return NativeHtmlTextFieldKind.textarea;
    }
    if (element.localName != 'input') return null;
    final type = (element.attributes['type'] ?? '').toLowerCase();
    if (_unsupportedInputTypes.contains(type)) return null;
    return switch (type) {
      '' || 'text' => NativeHtmlTextFieldKind.text,
      'search' => NativeHtmlTextFieldKind.search,
      'email' => NativeHtmlTextFieldKind.email,
      'url' => NativeHtmlTextFieldKind.url,
      'tel' => NativeHtmlTextFieldKind.tel,
      'password' => NativeHtmlTextFieldKind.password,
      'number' => NativeHtmlTextFieldKind.number,
      // Invalid input types use the HTML text fallback.
      _ => NativeHtmlTextFieldKind.text,
    };
  }

  String _initialValue(dom.Element element, NativeHtmlTextFieldKind kind) {
    if (kind == NativeHtmlTextFieldKind.textarea) {
      return element.text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    }
    final value = (element.attributes['value'] ?? '').replaceAll(
      RegExp(r'[\r\n]'),
      '',
    );
    if (kind == NativeHtmlTextFieldKind.number && !_isValidHtmlNumber(value)) {
      return '';
    }
    if (kind == NativeHtmlTextFieldKind.email ||
        kind == NativeHtmlTextFieldKind.url) {
      return value.replaceAll(RegExp(r'^[\t\n\f\r ]+|[\t\n\f\r ]+$'), '');
    }
    return value;
  }

  int? _nonNegativeInteger(String? value) {
    if (value == null) return null;
    final trimmed = value.replaceAll(
      RegExp(r'^[\t\n\f\r ]+|[\t\n\f\r ]+$'),
      '',
    );
    if (!RegExp(r'^\+?\d+$').hasMatch(trimmed)) return null;
    final digits = trimmed.startsWith('+') ? trimmed.substring(1) : trimmed;
    return int.tryParse(digits);
  }

  int _positiveInteger(String? value, {required int fallback}) {
    final parsed = _nonNegativeInteger(value);
    return parsed == null || parsed == 0 ? fallback : parsed;
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

  dom.Element? _labelTarget(
    dom.Element label,
    Map<String, dom.Element> firstById,
    Map<dom.Element, _PendingTextField> fields,
  ) {
    if (label.attributes.containsKey('for')) {
      final id = label.attributes['for'];
      final target = id == null ? null : firstById[id];
      return target != null && fields.containsKey(target) ? target : null;
    }
    for (final element in _labelDescendants(label)) {
      if (!_isLabelable(element)) continue;
      return fields.containsKey(element) ? element : null;
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

  static Iterable<dom.Element> _elements(dom.Node parent) sync* {
    for (final child in parent.nodes) {
      if (child is dom.Element) {
        yield child;
        yield* _elements(child);
      }
    }
  }

  static String _normalize(String text) =>
      text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

bool _isValidHtmlNumber(String value) =>
    RegExp(r'^-?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?$').hasMatch(value) &&
    (double.tryParse(value)?.isFinite ?? false);

_ExactDecimal? _decimalAttribute(String? value) {
  if (value == null || !_isValidHtmlNumber(value)) return null;
  return _ExactDecimal.parse(value);
}

BigInt _floorDivide(BigInt dividend, BigInt divisor) {
  final quotient = dividend ~/ divisor;
  final remainder = dividend.remainder(divisor);
  return dividend.isNegative && remainder != BigInt.zero
      ? quotient - BigInt.one
      : quotient;
}

/// Exact base-10 arithmetic for HTML step values such as 0.1 and 1e-3.
class _ExactDecimal {
  const _ExactDecimal(this.coefficient, this.scale);

  static final zero = _ExactDecimal(BigInt.zero, 0);
  static final one = _ExactDecimal(BigInt.one, 0);

  final BigInt coefficient;
  final int scale;

  bool get isPositive => coefficient > BigInt.zero;

  static _ExactDecimal? parse(String value) {
    if (!_isValidHtmlNumber(value)) return null;
    final match = RegExp(
      r'^(-?)(\d*)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$',
    ).firstMatch(value);
    if (match == null) return null;
    final whole = match.group(2)!;
    final fractional = match.group(3) ?? '';
    final exponent = int.tryParse(match.group(4) ?? '0');
    if (exponent == null || exponent.abs() > 308) return null;
    final digits = '${whole.isEmpty ? '0' : whole}$fractional';
    final parsedCoefficient = BigInt.tryParse(digits);
    if (parsedCoefficient == null) return null;
    var coefficient = parsedCoefficient;
    if (match.group(1) == '-') coefficient = -coefficient;
    var scale = fractional.length - exponent;
    if (scale < 0) {
      coefficient *= BigInt.from(10).pow(-scale);
      scale = 0;
    }
    if (scale > 308) return null;
    while (scale > 0 && coefficient.remainder(BigInt.from(10)) == BigInt.zero) {
      coefficient ~/= BigInt.from(10);
      scale--;
    }
    return _ExactDecimal(coefficient, scale);
  }

  BigInt unitsAt(int targetScale) =>
      coefficient * BigInt.from(10).pow(targetScale - scale);

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
    final whole = padded.substring(0, point);
    if (fractional.isEmpty) return '${negative ? '-' : ''}$whole';
    return '${negative ? '-' : ''}$whole.$fractional';
  }
}

class _PendingTextField {
  const _PendingTextField({
    required this.key,
    required this.element,
    required this.kind,
    required this.initialValue,
    required this.disabled,
    required this.readOnly,
    required this.visible,
    required this.required,
    required this.name,
    required this.placeholder,
    required this.maxLength,
    required this.minLength,
    required this.rows,
    required this.cols,
    required this.size,
    required this.min,
    required this.max,
    required this.step,
  });

  final String key;
  final dom.Element element;
  final NativeHtmlTextFieldKind kind;
  final String initialValue;
  final bool disabled;
  final bool readOnly;
  final bool visible;
  final bool required;
  final String? name;
  final String? placeholder;
  final int? maxLength;
  final int? minLength;
  final int rows;
  final int cols;
  final int size;
  final String? min;
  final String? max;
  final String? step;
}

class _TextFieldRecord {
  _TextFieldRecord({
    required this.descriptor,
    required this.controller,
    required this.focusNode,
    required this.editorKey,
    required this.domId,
  }) : lastUserValue = controller.value,
       lastControllerValue = controller.value;

  NativeHtmlTextFieldDescriptor descriptor;
  final TextEditingController controller;
  final FocusNode focusNode;
  final GlobalKey editorKey;
  String? domId;
  VoidCallback? blurListener;
  VoidCallback? controllerListener;
  NativeHtmlTextFieldState? owner;
  String? ownerKey;
  int keyEventGeneration = 0;
  bool lastReportedFocus = false;
  bool userCompositionActive = false;
  String userCompositionData = '';
  TextEditingValue lastUserValue;
  TextEditingValue lastControllerValue;
  _UserTextEdit? pendingUserEdit;
}

class _UserTextEdit {
  const _UserTextEdit(this.oldValue, this.newValue);

  final TextEditingValue oldValue;
  final TextEditingValue newValue;
}

class NativeHtmlTextFieldWidget extends StatelessWidget {
  const NativeHtmlTextFieldWidget({
    super.key,
    required this.state,
    required this.field,
    required this.textStyle,
    this.boxStyle,
  });

  final NativeHtmlTextFieldState state;
  final NativeHtmlTextFieldDescriptor field;
  final TextStyle textStyle;
  final NativeHtmlControlBoxStyle? boxStyle;

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    if (!field.visible) return const SizedBox.shrink();

    final dark = Theme.of(context).brightness == Brightness.dark;
    final password = field.kind == NativeHtmlTextFieldKind.password;
    final multiline = field.kind == NativeHtmlTextFieldKind.textarea;
    final enabled = !field.disabled;
    final borderWidth = multiline ? 1.0 : 2.0;
    final borderColor = dark
        ? const Color(0xff858585)
        : const Color(0xff767676);
    final disabledBorderColor = borderColor.withValues(alpha: 0.3);
    final fillColor = field.disabled
        ? (dark ? const Color(0x4d3b3b3b) : const Color(0x4defefef))
        : (dark ? const Color(0xff3b3b3b) : const Color(0xffffffff));
    final focus = state.focusNodeFor(field.key);
    final fontSize = textStyle.fontSize ?? 16;
    final scale = MediaQuery.textScalerOf(context);

    final glyph = TextPainter(
      text: TextSpan(
        text: 'x',
        style: textStyle.copyWith(height: kTextHeightNone),
      ),
      textDirection: Directionality.of(context),
      textScaler: scale,
    )..layout();
    final metrics = glyph.computeLineMetrics().first;
    final lineHeight = textStyle.height == kTextHeightNone
        ? metrics.height
        : scale.scale(fontSize) * (textStyle.height ?? 1.65);
    final averageWidth = HtmlInputSizing.effectiveAverageCharacterWidth(
      glyph.width,
    );
    final maximumWidth = math.max(
      averageWidth,
      glyph.computeLineMetrics().first.ascent.roundToDouble(),
    );
    glyph.dispose();
    // Blink's macOS metric path uses the x advance and font ascent. Flutter
    // exposes neither OS/2 average nor font-wide glyph bounds for the different
    // Android/Skia metric path; that platform's sizing remains unaccepted.
    final preferredSize = field.kind == NativeHtmlTextFieldKind.number
        ? HtmlInputSizing.numberInputPreferredCharacterCount(
            min: field.min,
            max: field.max,
            step: field.step,
          )
        : field.size;
    final contentWidth = multiline
        ? HtmlInputSizing.textareaIntrinsicInlineSize(
            preferredColumnCount: field.cols,
            averageCharacterWidth: averageWidth,
            scrollbarThickness: 4,
          )
        : HtmlInputSizing.textFieldIntrinsicInlineSize(
            preferredCharacterCount: preferredSize,
            averageCharacterWidth: averageWidth,
            maximumCharacterWidth: maximumWidth,
          );
    final contentHeight = lineHeight * (multiline ? field.rows : 1);
    final width = contentWidth + 4 + 2 * borderWidth;
    final height = contentHeight + (multiline ? 4 : 2) + 2 * borderWidth;
    final hintColor = dark ? const Color(0xffa0a0a0) : const Color(0xff757575);
    final editor = TextField(
      controller: state.controllerFor(field.key),
      focusNode: focus,
      style: textStyle,
      cursorColor: textStyle.color ?? Theme.of(context).colorScheme.primary,
      enabled: enabled,
      readOnly: field.readOnly,
      obscureText: password,
      autocorrect: false,
      enableSuggestions: !password,
      keyboardType: _keyboardType(field.kind),
      textInputAction: field.kind == NativeHtmlTextFieldKind.search
          ? TextInputAction.search
          : multiline
          ? TextInputAction.newline
          : TextInputAction.done,
      minLines: multiline ? field.rows : 1,
      maxLines: multiline ? field.rows : 1,
      inputFormatters: <TextInputFormatter>[
        _HtmlLineBreakFormatter(multiline: multiline),
        if (field.kind == NativeHtmlTextFieldKind.number)
          const _HtmlNumberInputFormatter(),
        if (field.maxLength != null &&
            field.kind != NativeHtmlTextFieldKind.number)
          _HtmlMaximumLengthFormatter(field.maxLength!),
        _NativeHtmlTextFieldEventFormatter(state, field.key),
      ],
      key: state.editorKeyFor(field.key),
      onChanged: (_) => state.recordUserInput(field.key),
      onTap: () => state.recordUserClick(field.key),
      // A prevented native form submission retains focus. The form adapter
      // reveals/refocuses an invalid field explicitly.
      onEditingComplete: state.onSubmit == null ? null : () {},
      onSubmitted: (_) {
        if (!multiline &&
            !(state.controllerFor(field.key).value.composing.isValid &&
                !state.controllerFor(field.key).value.composing.isCollapsed)) {
          state.submit(field.key);
        }
      },
      decoration: InputDecoration.collapsed(
        hintText: field.placeholder ?? '',
        hintStyle: textStyle.copyWith(color: hintColor),
      ),
    );
    final semantics = Semantics(
      key: ValueKey('native-html-text-field-${field.key}'),
      container: true,
      label: field.label.isEmpty ? null : field.label,
      hint: field.hint.isEmpty ? null : field.hint,
      enabled: enabled,
      readOnly: field.readOnly,
      obscured: password,
      textField: true,
      onIncrease: field.kind == NativeHtmlTextFieldKind.number
          ? () => state.stepNumber(field.key, direction: 1)
          : null,
      onDecrease: field.kind == NativeHtmlTextFieldKind.number
          ? () => state.stepNumber(field.key, direction: -1)
          : null,
      child: Focus(
        canRequestFocus: false,
        onKeyEvent: (context, event) {
          final value = state.controllerFor(field.key).value;
          final isComposing =
              value.composing.isValid && !value.composing.isCollapsed;
          if (event is KeyDownEvent ||
              event is KeyUpEvent ||
              event is KeyRepeatEvent) {
            final enterDown =
                event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.enter ||
                    event.logicalKey == LogicalKeyboardKey.numpadEnter);
            final submitOnEnter = !multiline && enterDown && !isComposing;
            state.recordUserKeyEvent(
              field.key,
              event,
              isComposing: isComposing,
              submitOnEnter: submitOnEnter,
            );
            if (submitOnEnter) return KeyEventResult.handled;
          }
          if (field.kind != NativeHtmlTextFieldKind.number ||
              event is! KeyDownEvent) {
            return KeyEventResult.ignored;
          }
          final direction = switch (event.logicalKey) {
            LogicalKeyboardKey.arrowUp => 1,
            LogicalKeyboardKey.arrowDown => -1,
            _ => 0,
          };
          if (direction == 0) return KeyEventResult.ignored;
          state.stepNumber(field.key, direction: direction);
          return KeyEventResult.handled;
        },
        child: ListenableBuilder(
          listenable: focus,
          builder: (context, child) => CustomPaint(
            foregroundPainter: _TextFieldFocusOutline(
              focused: focus.hasFocus,
              color: Theme.of(context).colorScheme.primary,
            ),
            child: child,
          ),
          child: boxStyle == null
              ? Container(
                  width: width,
                  height: height,
                  decoration: BoxDecoration(
                    color: fillColor,
                    border: Border.all(
                      color: enabled ? borderColor : disabledBorderColor,
                      width: borderWidth,
                    ),
                  ),
                  padding: EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: multiline ? 2 : 1,
                  ),
                  child: editor,
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final style = boxStyle!;
                    final padding = style.resolvePadding(constraints);
                    final styledBorder = style.borderForEnabledState(
                      enabled: enabled,
                      disabledBorderColor: disabledBorderColor,
                    );
                    final intrinsic = Size(
                      contentWidth +
                          padding.horizontal +
                          styledBorder.left.width +
                          styledBorder.right.width,
                      contentHeight +
                          padding.vertical +
                          styledBorder.top.width +
                          styledBorder.bottom.width,
                    );
                    final layout = style.resolveLayout(
                      intrinsicBorderBoxSize: intrinsic,
                      constraints: constraints,
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
                        decoration: BoxDecoration(
                          color: style.hasAuthoredBackground
                              ? layout.backgroundColor
                              : fillColor,
                          borderRadius: layout.borderRadius,
                        ),
                        padding:
                            layout.padding +
                            styledBorder.dimensions.resolve(
                              Directionality.of(context),
                            ),
                        child: editor,
                      ),
                    );
                  },
                ),
        ),
      ),
    );
    final style = boxStyle;
    if (style == null) return semantics;
    final intrinsicPadding = style.resolvePadding(const BoxConstraints());
    final intrinsicBorder = style.borderForEnabledState(
      enabled: enabled,
      disabledBorderColor: disabledBorderColor,
    );
    final naturalSize = Size(
      contentWidth +
          intrinsicPadding.horizontal +
          intrinsicBorder.left.width +
          intrinsicBorder.right.width,
      contentHeight +
          intrinsicPadding.vertical +
          intrinsicBorder.top.width +
          intrinsicBorder.bottom.width,
    );
    final intrinsicLayout = style.resolveLayout(
      intrinsicBorderBoxSize: naturalSize,
      constraints: const BoxConstraints(),
    );
    // Fieldset legends and other shrink-to-fit parents query intrinsic metrics.
    // LayoutBuilder cannot answer them; expose the same natural box used by
    // the actual CSS layout while forwarding real constraints unchanged.
    return NativeHtmlControlIntrinsic(
      intrinsicSize: intrinsicLayout.size,
      baselineFromTop:
          intrinsicPadding.top + intrinsicBorder.top.width + metrics.baseline,
      child: semantics,
    );
  }

  TextInputType _keyboardType(NativeHtmlTextFieldKind kind) => switch (kind) {
    NativeHtmlTextFieldKind.email => TextInputType.emailAddress,
    NativeHtmlTextFieldKind.url => TextInputType.url,
    NativeHtmlTextFieldKind.tel => TextInputType.phone,
    NativeHtmlTextFieldKind.number => const TextInputType.numberWithOptions(
      decimal: true,
      signed: true,
    ),
    NativeHtmlTextFieldKind.textarea => TextInputType.multiline,
    _ => TextInputType.text,
  };
}

class _TextFieldFocusOutline extends CustomPainter {
  const _TextFieldFocusOutline({required this.focused, required this.color});
  final bool focused;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    if (!focused) return;
    canvas.drawRect(
      (Offset.zero & size).inflate(3),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_TextFieldFocusOutline old) =>
      old.focused != focused || old.color != color;
}

class _HtmlNumberInputFormatter extends TextInputFormatter {
  const _HtmlNumberInputFormatter();

  static final _numberPrefix = RegExp(
    r'^(?:-?(?:\d+(?:\.\d*)?|\.\d*)(?:[eE][+-]?\d*)?|-?)$',
  );

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.composing.isValid && !newValue.composing.isCollapsed) {
      return newValue;
    }
    return _numberPrefix.hasMatch(newValue.text) ? newValue : oldValue;
  }
}

class _NativeHtmlTextFieldEventFormatter extends TextInputFormatter {
  const _NativeHtmlTextFieldEventFormatter(this.state, this.key);

  final NativeHtmlTextFieldState state;
  final String key;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    state._stageUserEdit(key, oldValue, newValue);
    return newValue;
  }
}

class _HtmlLineBreakFormatter extends TextInputFormatter {
  const _HtmlLineBreakFormatter({required this.multiline});

  final bool multiline;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final normalized = multiline
        ? newValue.text.replaceAll('\r\n', '\n').replaceAll('\r', '\n')
        : newValue.text.replaceAll(RegExp(r'[\r\n]'), '');
    if (normalized == newValue.text) return newValue;

    int adjustOffset(int offset) {
      if (offset < 0 || offset > newValue.text.length) return offset;
      final prefix = newValue.text.substring(0, offset);
      final normalizedPrefix = multiline
          ? prefix.replaceAll('\r\n', '\n').replaceAll('\r', '\n')
          : prefix.replaceAll(RegExp(r'[\r\n]'), '');
      return normalizedPrefix.length;
    }

    return newValue.copyWith(
      text: normalized,
      selection: TextSelection(
        baseOffset: adjustOffset(newValue.selection.baseOffset),
        extentOffset: adjustOffset(newValue.selection.extentOffset),
        affinity: newValue.selection.affinity,
        isDirectional: newValue.selection.isDirectional,
      ),
      composing: TextRange.empty,
    );
  }
}

/// HTML maxlength counts UTF-16 code units, not Flutter grapheme clusters.
class _HtmlMaximumLengthFormatter extends TextInputFormatter {
  const _HtmlMaximumLengthFormatter(this.maximum);

  final int maximum;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // Let IMEs finish composing even when the temporary composition exceeds
    // maxlength. The committed value is limited on the next update.
    if (newValue.composing.isValid && !newValue.composing.isCollapsed) {
      return newValue;
    }
    if (newValue.text.length <= maximum) return newValue;
    if (oldValue.text.length > maximum &&
        newValue.text.length < oldValue.text.length) {
      return newValue;
    }

    // Preserve the unchanged suffix when a paste or insertion reaches the
    // limit. Truncating the entire proposed string would delete existing text.
    if (oldValue.text.length <= maximum && oldValue.composing.isCollapsed) {
      var prefix = 0;
      while (prefix < oldValue.text.length &&
          prefix < newValue.text.length &&
          oldValue.text.codeUnitAt(prefix) ==
              newValue.text.codeUnitAt(prefix)) {
        prefix++;
      }
      var suffix = 0;
      while (suffix < oldValue.text.length - prefix &&
          suffix < newValue.text.length - prefix &&
          oldValue.text.codeUnitAt(oldValue.text.length - suffix - 1) ==
              newValue.text.codeUnitAt(newValue.text.length - suffix - 1)) {
        suffix++;
      }
      final available = maximum - prefix - suffix;
      var end = prefix + math.max(0, available).toInt();
      if (end > prefix &&
          end < newValue.text.length &&
          _isHighSurrogate(newValue.text.codeUnitAt(end - 1)) &&
          _isLowSurrogate(newValue.text.codeUnitAt(end))) {
        end--;
      }
      final text =
          newValue.text.substring(0, end) +
          newValue.text.substring(newValue.text.length - suffix);
      return TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: end),
      );
    }

    var limit = maximum;
    if (limit > 0 &&
        limit < newValue.text.length &&
        _isHighSurrogate(newValue.text.codeUnitAt(limit - 1)) &&
        _isLowSurrogate(newValue.text.codeUnitAt(limit))) {
      limit--;
    }
    final text = newValue.text.substring(0, limit);
    int adjustOffset(int offset) =>
        offset < 0 ? offset : math.min(offset, limit);
    return newValue.copyWith(
      text: text,
      selection: TextSelection(
        baseOffset: adjustOffset(newValue.selection.baseOffset),
        extentOffset: adjustOffset(newValue.selection.extentOffset),
        affinity: newValue.selection.affinity,
        isDirectional: newValue.selection.isDirectional,
      ),
      composing: newValue.composing.isValid && newValue.composing.end <= limit
          ? newValue.composing
          : TextRange.empty,
    );
  }

  bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xd800 && codeUnit <= 0xdbff;

  bool _isLowSurrogate(int codeUnit) =>
      codeUnit >= 0xdc00 && codeUnit <= 0xdfff;
}
