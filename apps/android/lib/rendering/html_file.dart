import 'render_l10n.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import 'html_control_border_painter.dart';
import 'html_control_box_style.dart';
import 'html_control_intrinsic.dart';
import 'html_inline_intrinsic_overflow.dart';

/// Bytes selected through the host file picker for one HTML file input.
///
/// There is deliberately no path or URI field. A file control can only submit
/// bytes supplied by its picker callback, and its displayed value is the file
/// name rather than a browser fake path.
@immutable
class NativeHtmlFile {
  NativeHtmlFile({
    required String name,
    required this.mimeType,
    required List<int> bytes,
    int? lastModified,
  }) : name = _safeDisplayName(name),
       lastModified = lastModified ?? DateTime.now().millisecondsSinceEpoch,
       _bytes = Uint8List.fromList(bytes);

  /// A file constructed from a script-provided literal filename.
  ///
  /// Unlike picker names, this name is not a filesystem path to normalize.
  NativeHtmlFile.script({
    required this.name,
    required this.mimeType,
    required List<int> bytes,
    required this.lastModified,
  }) : _bytes = Uint8List.fromList(bytes);

  final String name;
  final String mimeType;
  final int lastModified;
  final Uint8List _bytes;

  /// Returns a copy so callers cannot mutate the bytes held by form state.
  Uint8List get bytes => Uint8List.fromList(_bytes);

  int get length => _bytes.length;

  static String _safeDisplayName(String name) {
    final normalized = name.replaceAll('\\', '/');
    return normalized.substring(normalized.lastIndexOf('/') + 1);
  }
}

@immutable
class NativeHtmlFilePickerRequest {
  const NativeHtmlFilePickerRequest({
    required this.accept,
    required this.multiple,
  });

  /// Parsed `accept` tokens. This is a chooser hint; selected results are not
  /// rejected when the platform picker cannot implement a token.
  final List<String> accept;
  final bool multiple;
}

typedef NativeHtmlFilePicker =
    Future<List<NativeHtmlFile>?> Function(NativeHtmlFilePickerRequest request);

/// Native bytes retained by one live document, including detached script inputs.
/// No filesystem paths are retained. Retired documents discard the registry.
class NativeHtmlScriptFileSelections {
  final _values = <String, (String, List<NativeHtmlFile>)>{};
  static const maxBytes = 32 * 1024 * 1024;

  List<NativeHtmlFile>? get(String id, String version) {
    final value = _values[id];
    return value?.$1 == version ? value!.$2 : null;
  }

  List<NativeHtmlFile> store(
    String id,
    String version,
    List<NativeHtmlFile> files,
  ) {
    final previous = get(id, version);
    if (previous != null && _sameFiles(previous, files)) return previous;
    final total =
        _values.entries
            .where((e) => e.key != id)
            .expand((e) => e.value.$2)
            .fold<int>(0, (n, f) => n + f.length) +
        files.fold<int>(0, (n, f) => n + f.length);
    if (total > maxBytes) throw StateError(tr("此文件保留的選檔內容超過 32 MiB 限制。"));
    final saved = List<NativeHtmlFile>.unmodifiable(files);
    _values[id] = (version, saved);
    return saved;
  }

  static bool _sameFiles(List<NativeHtmlFile> a, List<NativeHtmlFile> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].name != b[i].name ||
          a[i].mimeType != b[i].mimeType ||
          a[i].length != b[i].length) {
        return false;
      }
      for (var j = 0; j < a[i].length; j++) {
        if (a[i]._bytes[j] != b[i]._bytes[j]) return false;
      }
    }
    return true;
  }

  void reconcile(NativeHtmlFileInputState state) {
    var changed = false;
    for (final record in state._records.values) {
      final id = record.descriptor.scriptId;
      if (id == null) continue;
      final saved = _values[id];
      if (saved == null) continue;
      if (saved.$1 != record.descriptor.fileResetVersion) {
        _values.remove(id);
        continue;
      }
      if (listEquals(record.files, saved.$2)) continue;
      record.files
        ..clear()
        ..addAll(saved.$2);
      changed = true;
    }
    if (changed) state._scriptSelectionChanged();
  }

  void clear() => _values.clear();
}

@immutable
class NativeHtmlFileInputDescriptor {
  const NativeHtmlFileInputDescriptor({
    required this.key,
    required this.name,
    required this.accept,
    required this.multiple,
    required this.required,
    required this.disabled,
    required this.visible,
    required this.label,
    required this.hint,
    this.scriptId,
    this.fileResetVersion = '0',
  });

  /// Opaque identifier embedded into the annotated document fragment.
  final String key;
  final String? name;
  final List<String> accept;
  final bool multiple;
  final bool required;
  final bool disabled;
  final bool visible;
  final String label;
  final String hint;
  final String? scriptId;

  /// Snapshot marker incremented by document scripts when they clear `.value`.
  final String fileResetVersion;
}

/// Per-document state for native HTML `<input type="file">` controls.
///
/// This object does not access a filesystem. The only source of file bytes is
/// the async [picker] callback supplied by the host document adapter.
class NativeHtmlFileInputState extends ChangeNotifier {
  NativeHtmlFileInputState._(this._source, this._nonce, this.picker);

  factory NativeHtmlFileInputState.fromHtml(
    String sanitizedHtml, {
    required NativeHtmlFilePicker picker,
  }) {
    final nonce = List.generate(
      12,
      (_) =>
          math.Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final state = NativeHtmlFileInputState._(sanitizedHtml, nonce, picker);
    state._scanAndAnnotate();
    return state;
  }

  static const _controlAttribute = 'data-pirc-native-file-input-id';
  static const _labelAttribute = 'data-pirc-native-file-input-for';
  static const _markerPrefix = 'data-pirc-native-file-input-';

  void _scriptSelectionChanged() {
    if (!_disposed) notifyListeners();
  }

  final String _source;
  final String _nonce;
  NativeHtmlFilePicker picker;
  final Map<String, _FileInputRecord> _records = {};
  final Map<String, dom.Element> _elementsByKey = {};
  late final String _annotatedHtml;
  bool _disposed = false;

  void Function(String key, String type)? onUserEvent;
  Future<void> Function(String key)? onActivateControl;

  /// Annotated markup for the independently parsed HTML renderer.
  String annotateHtml(String sanitizedHtml) {
    if (sanitizedHtml != _source) {
      throw ArgumentError.value(
        sanitizedHtml,
        'sanitizedHtml',
        tr("Must be the exact fragment used to create this file-input state."),
      );
    }
    return _annotatedHtml;
  }

  NativeHtmlFileInputDescriptor? resolveControl(dom.Element element) {
    if (element.localName != 'input' ||
        (element.attributes['type'] ?? '').toLowerCase() != 'file') {
      return null;
    }
    final key = element.attributes[_controlAttribute];
    final record = key == null ? null : _records[key];
    return record?.descriptor;
  }

  NativeHtmlFileInputDescriptor? resolveLabel(dom.Element label) {
    if (label.localName != 'label') return null;
    final key = label.attributes[_labelAttribute];
    return key == null ? null : _records[key]?.descriptor;
  }

  List<NativeHtmlFile> filesFor(String key) =>
      List<NativeHtmlFile>.unmodifiable(_recordFor(key).files);

  /// Whether this file input participates in constraint validation.
  ///
  /// CSS/HTML visibility does not make a control barred from validation;
  /// disabled controls (including controls disabled by a fieldset) are barred.
  bool willValidate(String key) => !_recordFor(key).descriptor.disabled;

  bool isRequiredSatisfied(String key) {
    final record = _recordFor(key);
    return !record.descriptor.required || record.files.isNotEmpty;
  }

  /// The validity flag remains observable on barred controls; form submission
  /// uses [willValidate] to decide whether it can block submission.
  bool valueMissing(String key) {
    final record = _recordFor(key);
    return record.descriptor.required && record.files.isEmpty;
  }

  bool isPicking(String key) => _recordFor(key).picking;
  Object? pickerErrorFor(String key) => _recordFor(key).pickerError;
  FocusNode focusNodeFor(String key) => _recordFor(key).focusNode;

  GlobalKey widgetKeyFor(String key) => _recordFor(key).widgetKey;

  void focusControl(String key) {
    final record = _records[key];
    if (record == null ||
        record.descriptor.disabled ||
        !record.descriptor.visible) {
      return;
    }
    record.focusNode.requestFocus();
  }

  /// HTML label activation opens the associated enabled file picker.
  void activateLabel(dom.Element label) {
    final field = resolveLabel(label);
    if (field == null || field.disabled || !field.visible) return;
    unawaited(pick(field.key));
  }

  /// Opens the host picker for a control. A canceled picker leaves any prior
  /// selection intact. When [multiple] is absent, only the first returned file
  /// is retained even if a host picker returns more than one.
  Future<void> pick(String key, {bool skipScript = false}) async {
    final record = _records[key];
    if (_disposed ||
        record == null ||
        record.descriptor.disabled ||
        !record.descriptor.visible ||
        record.picking) {
      return;
    }

    final activate = onActivateControl;
    if (!skipScript && activate != null) {
      await activate(key);
      return;
    }
    record.operation++;
    record
      ..picking = true
      ..pickerError = null;
    final operation = record.operation;
    var selectionChanged = false;
    record.focusNode.requestFocus();
    notifyListeners();

    try {
      final picked = await picker(
        NativeHtmlFilePickerRequest(
          accept: record.descriptor.accept,
          multiple: record.descriptor.multiple,
        ),
      );
      final owner = _currentOwner(record, operation);
      if (owner == null) return;
      if (picked != null) {
        final selected = record.descriptor.multiple
            ? picked
            : picked.take(1).toList(growable: false);
        selectionChanged = !_sameFiles(record.files, selected);
        if (selectionChanged) {
          record.files
            ..clear()
            ..addAll(selected);
        }
      }
    } catch (error) {
      final owner = _currentOwner(record, operation);
      if (owner == null) return;
      record.pickerError = error;
    } finally {
      final owner = _currentOwner(record, operation);
      if (owner != null) {
        record.picking = false;
        owner.notifyListeners();
        if (selectionChanged) {
          owner._emitUserChange(record.descriptor.key);
        }
      }
    }
  }

  /// Transfers live file selections, focus, widget identity, and any in-flight
  /// picker operation for controls uniquely marked by document scripts.
  /// A changed [NativeHtmlFileInputDescriptor.fileResetVersion] clears the
  /// selection and invalidates an in-flight picker result.
  void adoptInteractionState(NativeHtmlFileInputState previous) {
    if (identical(this, previous)) return;
    final oldById = _uniqueRecordsByScriptId(previous._records);
    final newById = _uniqueRecordsByScriptId(_records);
    for (final entry in newById.entries) {
      final old = oldById[entry.key];
      if (old == null) continue;

      final oldKey = old.key;
      final oldRecord = old.value;
      final freshRecord = entry.value.value;
      final oldDescriptor = oldRecord.descriptor;
      final newDescriptor = freshRecord.descriptor;
      final wasScriptCleared =
          oldDescriptor.fileResetVersion != newDescriptor.fileResetVersion;

      freshRecord.focusNode.dispose();
      oldRecord
        ..descriptor = newDescriptor
        ..owner = this
        ..focusNode.debugLabel = newDescriptor.label.isEmpty
            ? tr("HTML file input")
            : newDescriptor.label
        ..focusNode.canRequestFocus =
            !newDescriptor.disabled && newDescriptor.visible
        ..focusNode.skipTraversal =
            newDescriptor.disabled || !newDescriptor.visible;

      if (wasScriptCleared) {
        oldRecord.operation++;
        oldRecord.picking = false;
        oldRecord.pickerError = null;
        oldRecord.files.clear();
      }

      _records[newDescriptor.key] = oldRecord;
      previous._records.remove(oldKey);
      previous._elementsByKey.remove(oldKey);
    }
  }

  Map<String, MapEntry<String, _FileInputRecord>> _uniqueRecordsByScriptId(
    Map<String, _FileInputRecord> records,
  ) {
    final grouped = <String, List<MapEntry<String, _FileInputRecord>>>{};
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

  NativeHtmlFileInputState? _currentOwner(
    _FileInputRecord record,
    int operation,
  ) {
    final owner = record.owner;
    if (owner == null ||
        owner._disposed ||
        record.operation != operation ||
        !identical(owner._records[record.descriptor.key], record)) {
      return null;
    }
    return owner;
  }

  bool _sameFiles(List<NativeHtmlFile> first, List<NativeHtmlFile> second) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      final a = first[index];
      final b = second[index];
      if (a.name != b.name ||
          a.mimeType != b.mimeType ||
          a._bytes.length != b._bytes.length) {
        return false;
      }
      for (var byte = 0; byte < a._bytes.length; byte++) {
        if (a._bytes[byte] != b._bytes[byte]) return false;
      }
    }
    return true;
  }

  void _emitUserChange(String key) {
    final callback = onUserEvent;
    callback?.call(key, 'input');
    callback?.call(key, 'change');
  }

  /// File controls have no authored default selectedness; reset always clears
  /// them, including disabled controls. Pass the controls belonging to the
  /// form being reset (or the entire document when resetting all forms).
  void resetElements(Iterable<dom.Element> elements) {
    var changed = false;
    for (final element in elements) {
      final key = element.attributes[_controlAttribute];
      final record = key == null ? null : _records[key];
      if (record == null) continue;
      record.operation++;
      if (record.picking || record.pickerError != null) changed = true;
      record.picking = false;
      record.pickerError = null;
      if (record.files.isNotEmpty) {
        record.files.clear();
        changed = true;
      }
    }
    if (changed) notifyListeners();
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

    final fields = <dom.Element, _FileInputRecord>{};
    for (final element in elements) {
      if (element.localName != 'input' ||
          (element.attributes['type'] ?? '').toLowerCase() != 'file') {
        continue;
      }
      final key = '$_nonce-${_records.length}';
      final accept = _parseAccept(element.attributes['accept']);
      final disabled =
          element.attributes.containsKey('disabled') ||
          _disabledByFieldset(element);
      final multiple = element.attributes.containsKey('multiple');
      final scriptId = element.attributes['data-pirc-script-id'];
      final rawResetVersion =
          element.attributes['data-pirc-file-reset-version'];
      final resetVersion =
          rawResetVersion != null && RegExp(r'^\d+$').hasMatch(rawResetVersion)
          ? rawResetVersion
          : '0';
      final descriptor = NativeHtmlFileInputDescriptor(
        key: key,
        name: element.attributes['name'],
        accept: accept,
        multiple: multiple,
        required: element.attributes.containsKey('required'),
        disabled: disabled,
        visible: _visibleForNavigation(element),
        label: '',
        hint: '',
        scriptId: scriptId,
        fileResetVersion: resetVersion,
      );
      element.attributes[_controlAttribute] = key;
      final record = _FileInputRecord(
        descriptor: descriptor,
        owner: this,
        focusNode: FocusNode(debugLabel: 'HTML file input $key'),
        widgetKey: GlobalKey(),
      );
      _records[key] = record;
      _elementsByKey[key] = element;
      fields[element] = record;
    }

    final labels = <String, List<String>>{};
    for (final label in elements.where(
      (element) => element.localName == 'label',
    )) {
      final target = _labelTarget(label, firstById, fields);
      if (target == null) continue;
      final record = fields[target]!;
      label.attributes[_labelAttribute] = record.descriptor.key;
      final value = _accessibleText(label, firstById, skipLabels: true);
      if (value.isNotEmpty) {
        (labels[record.descriptor.key] ??= []).add(value);
      }
    }

    for (final record in _records.values) {
      final original = record.descriptor;
      final element = _elementsByKey[original.key]!;
      final labelledBy = _referencedText(
        element.attributes['aria-labelledby'],
        firstById,
      );
      final describedBy = _referencedText(
        element.attributes['aria-describedby'],
        firstById,
      );
      final ariaLabel = element.attributes['aria-label']?.trim();
      final associated = labels[original.key] ?? const <String>[];
      final label = labelledBy.isNotEmpty
          ? labelledBy
          : ariaLabel?.isNotEmpty == true
          ? ariaLabel!
          : associated.isNotEmpty
          ? associated.join(' ')
          : _normalize(element.attributes['title'] ?? '');
      final hint = describedBy.isNotEmpty
          ? describedBy
          : _normalize(element.attributes['aria-description'] ?? '');
      record.descriptor = NativeHtmlFileInputDescriptor(
        key: original.key,
        name: original.name,
        accept: original.accept,
        multiple: original.multiple,
        required: original.required,
        disabled: original.disabled,
        visible: original.visible,
        label: label,
        hint: hint,
        scriptId: original.scriptId,
        fileResetVersion: original.fileResetVersion,
      );
      record.focusNode.debugLabel = label.isEmpty
          ? tr("HTML file input")
          : label;
      record.focusNode.canRequestFocus = !original.disabled && original.visible;
      record.focusNode.skipTraversal = original.disabled || !original.visible;
    }

    _annotatedHtml = fragment.outerHtml;
  }

  String _referencedText(String? ids, Map<String, dom.Element> firstById) {
    if (ids == null) return '';
    return _normalize(
      ids
          .split(RegExp(r'[\t\n\f\r ]+'))
          .where((id) => id.isNotEmpty)
          .map((id) {
            final element = firstById[id];
            return element == null ? '' : _accessibleText(element, firstById);
          })
          .where((text) => text.isNotEmpty)
          .join(' '),
    );
  }

  dom.Element? _labelTarget(
    dom.Element label,
    Map<String, dom.Element> firstById,
    Map<dom.Element, _FileInputRecord> fields,
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

  String _accessibleText(
    dom.Element root,
    Map<String, dom.Element> firstById, {
    bool skipLabels = false,
  }) {
    final output = StringBuffer();
    void append(dom.Node node) {
      if (node is dom.Text) {
        output.write(node.text);
      } else if (node is dom.Element) {
        if (skipLabels && !identical(node, root) && node.localName == 'label') {
          return;
        }
        if (node.localName == 'img') {
          output.write(node.attributes['alt'] ?? '');
          return;
        }
        for (final child in node.nodes) {
          append(child);
        }
      }
    }

    append(root);
    return _normalize(output.toString());
  }

  bool _isLabelable(dom.Element element) =>
      element.localName == 'input' &&
      (element.attributes['type'] ?? '').toLowerCase() != 'hidden';

  Iterable<dom.Element> _labelDescendants(dom.Element label) sync* {
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
        final firstLegend = parent.children
            .where((candidate) => candidate.localName == 'legend')
            .firstOrNull;
        if (firstLegend == null || !_isWithin(element, firstLegend)) {
          return true;
        }
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

  _FileInputRecord _recordFor(String key) {
    final record = _records[key];
    if (record == null) {
      throw StateError(tr("Unknown HTML file input: {0}", [key]));
    }
    return record;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final record in _records.values) {
      record.operation++;
      record.owner = null;
      record.focusNode.dispose();
    }
    _records.clear();
    _elementsByKey.clear();
    super.dispose();
  }

  static List<String> _parseAccept(String? raw) {
    if (raw == null) return const [];
    return List.unmodifiable(
      raw
          .split(',')
          .map((item) => item.trim().toLowerCase())
          .where((item) => item.isNotEmpty),
    );
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

class _FileInputRecord {
  _FileInputRecord({
    required this.descriptor,
    required this.owner,
    required this.focusNode,
    required this.widgetKey,
  });

  NativeHtmlFileInputDescriptor descriptor;
  NativeHtmlFileInputState? owner;
  final FocusNode focusNode;
  final GlobalKey widgetKey;
  final List<NativeHtmlFile> files = [];
  bool picking = false;
  int operation = 0;
  Object? pickerError;
}

@immutable
class NativeHtmlFileInputStrings {
  const NativeHtmlFileInputStrings({
    required this.chooseFile,
    required this.chooseFiles,
    required this.noFileChosen,
    required this.noFilesChosen,
    required this.fileCount,
    this.locale,
  });

  final String chooseFile;
  final String chooseFiles;
  final String noFileChosen;
  final String noFilesChosen;
  final String Function(int count) fileCount;
  final Locale? locale;

  factory NativeHtmlFileInputStrings.forLocale(Locale locale) {
    if (locale.languageCode == 'zh') {
      if (locale.countryCode == 'TW' || locale.countryCode == 'HK') {
        return NativeHtmlFileInputStrings(
          chooseFile: '選擇檔案',
          chooseFiles: '選擇檔案',
          noFileChosen: '未選擇任何檔案',
          noFilesChosen: '未選擇任何檔案',
          fileCount: (count) => '$count 個檔案',
          locale: locale,
        );
      }
      return NativeHtmlFileInputStrings(
        chooseFile: '选择文件',
        chooseFiles: '选择文件',
        noFileChosen: '未选择任何文件',
        noFilesChosen: '未选择任何文件',
        fileCount: (count) => '$count 个文件',
        locale: locale,
      );
    }
    return NativeHtmlFileInputStrings(
      chooseFile: 'Choose File',
      chooseFiles: 'Choose Files',
      noFileChosen: 'No file chosen',
      noFilesChosen: 'No files chosen',
      fileCount: (count) => '$count files',
      locale: locale,
    );
  }
}

/// Flutter rendering for an HTML file input. The host remains responsible for
/// opening a file picker; this widget never reads a URL or filesystem path.
class NativeHtmlFileInputWidget extends StatelessWidget {
  const NativeHtmlFileInputWidget({
    super.key,
    required this.state,
    required this.control,
    required this.textStyle,
    this.boxStyle,
    this.strings,
  });

  final NativeHtmlFileInputState state;
  final NativeHtmlFileInputDescriptor control;
  final TextStyle textStyle;
  final NativeHtmlControlBoxStyle? boxStyle;
  final NativeHtmlFileInputStrings? strings;

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    if (!control.visible) return const SizedBox.shrink();
    final enabled = !control.disabled;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final focus = state.focusNodeFor(control.key);
    final baseFontSize = textStyle.fontSize ?? 13.333333333333334;
    final fontSize = MediaQuery.textScalerOf(context).scale(baseFontSize);
    final inheritedTextStyle = DefaultTextStyle.of(
      context,
    ).style.merge(textStyle);
    final labels =
        strings ??
        NativeHtmlFileInputStrings.forLocale(Localizations.localeOf(context));
    final locale = labels.locale ?? Localizations.localeOf(context);
    final label = control.multiple ? labels.chooseFiles : labels.chooseFile;
    final buttonStyle = TextStyle(
      inherit: false,
      // Chromium's file-selector button UA style uses Arial in raw and
      // Markdown documents; the filename/status text still inherits the body
      // font below.
      fontFamily: 'Arial',
      fontFamilyFallback: inheritedTextStyle.fontFamilyFallback,
      fontSize: fontSize,
      color: enabled
          ? (dark ? const Color(0xffffffff) : const Color(0xff000000))
          : (dark ? const Color(0xff8a8a8a) : const Color(0xff757575)),
      fontWeight: FontWeight.w400,
    );
    final statusStyle = inheritedTextStyle.copyWith(
      fontSize: fontSize,
      height: 1,
      letterSpacing: textStyle.letterSpacing ?? 0,
      wordSpacing: textStyle.wordSpacing ?? 0,
      color: enabled
          ? (textStyle.color ?? const Color(0xff000000))
          : (dark ? const Color(0xff8a8a8a) : const Color(0xff757575)),
      fontWeight: FontWeight.w400,
    );
    final contentMetrics = _intrinsicContentMetrics(
      context,
      statusStyle: statusStyle,
      buttonStyle: buttonStyle,
      buttonLabel: label,
      locale: locale,
    );
    final intrinsic = _intrinsicBoxMetrics(
      context,
      content: contentMetrics,
      style: boxStyle,
      enabled: enabled,
      dark: dark,
    );

    final child = ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final files = state.filesFor(control.key);
        final status = files.isEmpty
            ? (control.multiple ? labels.noFilesChosen : labels.noFileChosen)
            : control.multiple && files.length > 1
            ? labels.fileCount(files.length)
            : files.first.name;
        final button = DecoratedBox(
          decoration: BoxDecoration(
            color: dark ? const Color(0xff444444) : const Color(0xffefefef),
            border: Border.all(
              color: dark ? const Color(0xff858585) : const Color(0xff767676),
              width: 2,
            ),
            borderRadius: BorderRadius.zero,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            child: Text(
              label,
              textScaler: TextScaler.noScaling,
              locale: locale,
              style: buttonStyle,
            ),
          ),
        );
        final content = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            button,
            const SizedBox(width: 4),
            Flexible(
              fit: FlexFit.loose,
              child: Text(
                status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textScaler: TextScaler.noScaling,
                locale: locale,
                style: statusStyle,
              ),
            ),
          ],
        );

        return Semantics(
          key: ValueKey('native-html-file-input-${control.key}'),
          container: true,
          label: control.label.isEmpty ? null : control.label,
          hint: control.hint.isEmpty ? null : control.hint,
          value: status,
          button: true,
          focusable: enabled,
          enabled: enabled,
          onTap: enabled ? () => unawaited(state.pick(control.key)) : null,
          child: Focus(
            focusNode: focus,
            canRequestFocus: enabled,
            skipTraversal: !enabled,
            onKeyEvent: (context, event) {
              if (!enabled || event is! KeyDownEvent) {
                return KeyEventResult.ignored;
              }
              if (event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.space) {
                unawaited(state.pick(control.key));
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: ListenableBuilder(
              listenable: focus,
              builder: (context, child) => CustomPaint(
                foregroundPainter: _FileFocusOutline(
                  focused: focus.hasFocus,
                  color: Theme.of(context).colorScheme.primary,
                ),
                child: child,
              ),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: enabled
                    ? () {
                        focus.requestFocus();
                        unawaited(state.pick(control.key));
                      }
                    : null,
                child: DefaultTextStyle.merge(
                  style: textStyle,
                  child: _applyBoxStyle(
                    context,
                    content,
                    boxStyle,
                    statusStyle,
                    buttonStyle,
                    contentIntrinsic: contentMetrics.size,
                    enabled: enabled,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    final controlBoxStyle = boxStyle;
    final parentRelativeDimensions = [
      controlBoxStyle?.width,
      controlBoxStyle?.minWidth,
      controlBoxStyle?.maxWidth,
    ].any((dimension) => dimension?.unit == '%');
    final allowsIntrinsicOverflow =
        controlBoxStyle == null ||
        (!parentRelativeDimensions &&
            !controlBoxStyle.paddingLengths.hasPercentages);
    if (allowsIntrinsicOverflow) {
      return NativeHtmlInlineIntrinsicOverflow(
        key: ValueKey('native-html-file-intrinsic-${control.key}'),
        intrinsicSize: intrinsic.size,
        baselineFromTop: intrinsic.baselineFromTop,
        child: child,
      );
    }
    return NativeHtmlControlIntrinsic(
      key: ValueKey('native-html-file-intrinsic-${control.key}'),
      intrinsicSize: intrinsic.size,
      baselineFromTop: intrinsic.baselineFromTop,
      child: child,
    );
  }

  _NativeHtmlFileContentMetrics _intrinsicContentMetrics(
    BuildContext context, {
    required TextStyle statusStyle,
    required TextStyle buttonStyle,
    required String buttonLabel,
    required Locale locale,
  }) {
    // Chromium sizes the filename area to 34 zero-glyph advances. Measuring
    // the effective control font keeps this responsive to authored font size,
    // font family, and the app's prepared text scale.
    final statusPainter = TextPainter(
      text: TextSpan(text: '0', style: statusStyle),
      textDirection: Directionality.of(context),
      textScaler: TextScaler.noScaling,
      locale: locale,
      maxLines: 1,
    )..layout();
    final filenameArea = (statusPainter.width * 34).ceilToDouble();
    // The chooser button has 1px vertical padding and a 2px edge on each side.
    final buttonPainter = TextPainter(
      text: TextSpan(text: buttonLabel, style: buttonStyle),
      textDirection: Directionality.of(context),
      textScaler: TextScaler.noScaling,
      locale: locale,
      maxLines: 1,
    )..layout();
    final buttonHeight = buttonPainter.height + 6;
    final buttonTextBaseline =
        buttonPainter.computeDistanceToActualBaseline(TextBaseline.alphabetic) +
        3;
    final rowHeight = math.max(buttonHeight, statusPainter.height);
    final metrics = _NativeHtmlFileContentMetrics(
      size: Size(filenameArea, rowHeight.ceilToDouble()),
      rowHeight: rowHeight,
      buttonHeight: buttonHeight,
      buttonTextBaseline: buttonTextBaseline,
    );
    statusPainter.dispose();
    buttonPainter.dispose();
    return metrics;
  }

  ({Size size, double baselineFromTop}) _intrinsicBoxMetrics(
    BuildContext context, {
    required _NativeHtmlFileContentMetrics content,
    required NativeHtmlControlBoxStyle? style,
    required bool enabled,
    required bool dark,
  }) {
    if (style == null) {
      final centerOffset = (content.size.height - content.rowHeight) / 2;
      return (
        size: content.size,
        baselineFromTop:
            centerOffset +
            (content.rowHeight - content.buttonHeight) / 2 +
            content.buttonTextBaseline,
      );
    }
    final disabledBorder =
        (dark ? const Color(0xff858585) : const Color(0xff767676)).withValues(
          alpha: .3,
        );
    final border = style.borderForEnabledState(
      enabled: enabled,
      disabledBorderColor: disabledBorder,
    );
    final padding = style.padding;
    final naturalBorderBoxSize = Size(
      content.size.width + padding.horizontal + border.dimensions.horizontal,
      content.size.height + padding.vertical + border.dimensions.vertical,
    );
    final layout = style.resolveLayout(
      intrinsicBorderBoxSize: naturalBorderBoxSize,
      constraints: const BoxConstraints(),
    );
    final direction = Directionality.of(context);
    final resolvedPadding = padding.resolve(direction);
    final resolvedBorder = border.dimensions.resolve(direction);
    final actualChildBorderBoxHeight =
        content.rowHeight + resolvedPadding.vertical + resolvedBorder.vertical;
    final centeredChildOffset =
        (layout.size.height - actualChildBorderBoxHeight) / 2;
    return (
      size: layout.size,
      baselineFromTop:
          centeredChildOffset +
          resolvedPadding.top +
          resolvedBorder.top +
          (content.rowHeight - content.buttonHeight) / 2 +
          content.buttonTextBaseline,
    );
  }

  Widget _applyBoxStyle(
    BuildContext context,
    Widget content,
    NativeHtmlControlBoxStyle? style,
    TextStyle statusStyle,
    TextStyle buttonStyle, {
    required Size contentIntrinsic,
    required bool enabled,
  }) {
    if (style == null) {
      return SizedBox(
        width: contentIntrinsic.width,
        height: contentIntrinsic.height,
        child: Align(
          alignment: Alignment.centerLeft,
          widthFactor: 1,
          heightFactor: 1,
          child: content,
        ),
      );
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    final disabledBorder =
        (dark ? const Color(0xff858585) : const Color(0xff767676)).withValues(
          alpha: .3,
        );
    return LayoutBuilder(
      builder: (context, constraints) {
        final padding = style.resolvePadding(constraints);
        final border = style.borderForEnabledState(
          enabled: enabled,
          disabledBorderColor: disabledBorder,
        );
        final layout = style.resolveLayout(
          intrinsicBorderBoxSize: Size(
            contentIntrinsic.width +
                padding.horizontal +
                border.dimensions.horizontal,
            contentIntrinsic.height +
                padding.vertical +
                border.dimensions.vertical,
          ),
          constraints: constraints,
        );
        final child = Padding(
          padding:
              layout.padding +
              border.dimensions.resolve(Directionality.of(context)),
          child: content,
        );
        return CustomPaint(
          foregroundPainter: NativeHtmlControlBorderPainter(
            border: border,
            styleNames: layout.borderStyleNames,
            borderRadius: layout.borderRadius,
          ),
          child: Container(
            width: layout.size.width,
            height: layout.size.height,
            decoration: BoxDecoration(
              color: layout.backgroundColor,
              borderRadius: layout.borderRadius,
            ),
            alignment: Alignment.centerLeft,
            child: child,
          ),
        );
      },
    );
  }
}

class _NativeHtmlFileContentMetrics {
  const _NativeHtmlFileContentMetrics({
    required this.size,
    required this.rowHeight,
    required this.buttonHeight,
    required this.buttonTextBaseline,
  });

  final Size size;
  final double rowHeight;
  final double buttonHeight;
  final double buttonTextBaseline;
}

class _FileFocusOutline extends CustomPainter {
  const _FileFocusOutline({required this.focused, required this.color});

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
  bool shouldRepaint(_FileFocusOutline oldDelegate) =>
      oldDelegate.focused != focused || oldDelegate.color != color;
}
