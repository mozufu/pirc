import 'render_l10n.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'html_control_box_style.dart';
import 'html_control_intrinsic.dart';
import 'html_control_border_painter.dart';

enum NativeHtmlControlType { checkbox, radio }

@immutable
class NativeHtmlControlDescriptor {
  const NativeHtmlControlDescriptor({
    required this.key,
    required this.type,
    required this.checked,
    required this.disabled,
    required this.visible,
    this.scriptId,
    required this.name,
    required this.label,
    required this.hint,
  });

  /// Opaque key embedded into the sanitized markup by [NativeHtmlControlState].
  final String key;
  final NativeHtmlControlType type;
  final bool checked;
  final bool disabled;
  final bool visible;
  final String? scriptId;
  final String? name;
  final String label;
  final String hint;
}

/// Per-document checked state for raw HTML checkbox and radio controls.
///
/// [fromHtml] parses the sanitized fragment and creates nonce-qualified markers
/// on supported inputs and their associated labels. Use [annotateHtml] as the
/// HTML passed to HtmlWidget, then resolve reparsed elements by their markers.
/// This avoids depending on DOM element identity across the HTML widget's parse.
class NativeHtmlControlState extends ChangeNotifier {
  NativeHtmlControlState._(this._source, this._nonce);

  factory NativeHtmlControlState.fromHtml(String sanitizedHtml) {
    final nonce = List.generate(
      12,
      (_) =>
          math.Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final state = NativeHtmlControlState._(sanitizedHtml, nonce);
    state._scanAndAnnotate();
    return state;
  }

  static const _controlAttribute = 'data-pirc-native-control-id';
  static const _labelAttribute = 'data-pirc-native-control-for';
  static const _markerPrefix = 'data-pirc-native-control-';

  final String _source;
  final String _nonce;
  late final String _annotatedHtml;
  final Map<String, _ControlRecord> _records = {};
  final Map<String, String?> _radioSelection = {};
  final Map<String, bool> _checkboxSelection = {};
  final Map<String, FocusNode> _focusNodes = {};
  final Map<String, List<String>> _radioMembers = {};
  final Map<String, GlobalKey> _widgetKeys = {};

  void Function(String key)? onActivateControl;

  void Function(String key, String type)? onUserEvent;

  /// Returns the sanitized fragment with private markers needed by the
  /// independently parsed HtmlWidget DOM. The visible HTML is unchanged.
  String annotateHtml(String sanitizedHtml) {
    if (sanitizedHtml != _source) {
      throw ArgumentError.value(
        sanitizedHtml,
        'sanitizedHtml',
        tr("Must be the exact fragment used to create this control state."),
      );
    }
    return _annotatedHtml;
  }

  void _scanAndAnnotate() {
    final fragment = html.parseFragment(_source);
    final elements = _elements(fragment).toList();

    // Remove user-supplied lookalike markers before assigning trusted IDs.
    for (final element in elements) {
      for (final name
          in element.attributes.keys
              .where((name) => name is String && name.startsWith(_markerPrefix))
              .toList()) {
        element.attributes.remove(name);
      }
    }

    final firstById = <String, dom.Element>{};
    for (final element in elements) {
      final id = element.attributes['id'];
      if (id != null && id.isNotEmpty) firstById.putIfAbsent(id, () => element);
    }

    final pending = <_PendingControl>[];
    var ordinal = 0;
    for (final element in elements) {
      if (element.localName != 'input') continue;
      final type = switch (element.attributes['type']?.toLowerCase()) {
        'checkbox' => NativeHtmlControlType.checkbox,
        'radio' => NativeHtmlControlType.radio,
        _ => null,
      };
      if (type == null) continue;

      final key = '$_nonce-$ordinal';
      ordinal++;
      final group = type == NativeHtmlControlType.radio
          ? _radioGroup(element, firstById, key)
          : null;
      element.attributes[_controlAttribute] = key;
      pending.add(
        _PendingControl(
          key: key,
          element: element,
          type: type,
          name: element.attributes['name'],
          disabled:
              element.attributes.containsKey('disabled') ||
              _disabledByFieldset(element),
          visible: _visibleForNavigation(element),
          checked: element.attributes.containsKey('checked'),
          group: group,
        ),
      );
    }

    // Resolve both explicit `for` labels and labels containing their control.
    final labels = <String, List<String>>{};
    final pendingByElement = {
      for (final control in pending) control.element: control,
    };
    for (final element in elements.where((e) => e.localName == 'label')) {
      final target = _labelTarget(element, firstById, pendingByElement);
      if (target == null) continue;
      final targetKey = pendingByElement[target]!.key;
      element.attributes[_labelAttribute] = targetKey;
      final text = _normalize(element.text);
      if (text.isNotEmpty) (labels[targetKey] ??= []).add(text);
    }

    final selections = <String, String?>{};
    for (final control in pending) {
      final key = control.group;
      if (key != null) {
        (_radioMembers[key] ??= []).add(control.key);
        selections.putIfAbsent(key, () => null);
        // Like the browser's checkedness algorithm, the last checked radio in
        // source order wins when malformed markup marks multiple as checked.
        if (control.checked) selections[key] = control.key;
      } else if (control.type == NativeHtmlControlType.radio) {
        _radioMembers[control.key] = [control.key];
        selections[control.key] = control.checked ? control.key : null;
      } else {
        _checkboxSelection[control.key] = control.checked;
      }
    }
    _radioSelection.addAll(selections);

    for (final control in pending) {
      final associatedLabels = labels[control.key] ?? const <String>[];
      final ariaLabel = control.element.attributes['aria-label']?.trim();
      final labelledBy = control.element.attributes['aria-labelledby']
          ?.split(RegExp(r'\s+'))
          .where((id) => id.isNotEmpty)
          .map((id) => firstById[id]?.text ?? '')
          .map(_normalize)
          .where((text) => text.isNotEmpty)
          .join(' ');
      final describedBy = control.element.attributes['aria-describedby']
          ?.split(RegExp(r'\s+'))
          .where((id) => id.isNotEmpty)
          .map((id) => firstById[id]?.text ?? '')
          .map(_normalize)
          .where((text) => text.isNotEmpty)
          .join(' ');
      final label = labelledBy?.isNotEmpty == true
          ? labelledBy!
          : ariaLabel?.isNotEmpty == true
          ? ariaLabel!
          : associatedLabels.isNotEmpty
          ? associatedLabels.join(' ')
          : _normalize(control.element.attributes['title'] ?? '');
      final hint = describedBy?.isNotEmpty == true
          ? describedBy!
          : _normalize(control.element.attributes['aria-description'] ?? '');
      final checked = control.type == NativeHtmlControlType.checkbox
          ? _checkboxSelection[control.key] ?? false
          : _radioSelection[control.group ?? control.key] == control.key;
      _records[control.key] = _ControlRecord(
        NativeHtmlControlDescriptor(
          key: control.key,
          type: control.type,
          checked: checked,
          disabled: control.disabled,
          visible: control.visible,
          scriptId: control.element.attributes['data-pirc-script-id'],
          name: control.name,
          label: label,
          hint: hint,
        ),
        radioGroup: control.group,
      );
    }

    _annotatedHtml = fragment.outerHtml;
  }

  NativeHtmlControlDescriptor? resolveControl(dom.Element input) {
    if (input.localName != 'input') return null;
    final key = input.attributes[_controlAttribute];
    final record = key == null ? null : _records[key];
    if (record == null) return null;
    final type = input.attributes['type']?.toLowerCase();
    if (type != record.descriptor.type.name) return null;
    return record.descriptor;
  }

  /// Returns the checkbox/radio associated with a marked label, or null when
  /// the label targets another kind of control or no control.
  NativeHtmlControlDescriptor? resolveLabel(dom.Element label) {
    if (label.localName != 'label') return null;
    final key = label.attributes[_labelAttribute];
    return key == null ? null : _records[key]?.descriptor;
  }

  /// Performs the native label activation behavior and focuses its control.
  void activateLabel(dom.Element label) {
    final control = resolveLabel(label);
    if (control == null || control.disabled) return;
    activateControl(control.key);
    focusControl(control.key);
  }

  bool isChecked(String key) {
    final record = _records[key];
    if (record == null) return false;
    if (record.descriptor.type == NativeHtmlControlType.checkbox) {
      return _checkboxSelection[key] ?? false;
    }
    final group = record.radioGroup ?? key;
    return _radioSelection[group] == key;
  }

  /// Restores checkedness without running the interactive disabled-control
  /// guard. This is used only for a saved document history entry.
  void restoreHistoryCheckedness(Map<String, bool> checkedness) {
    if (checkedness.isEmpty) return;
    final radioGroups = <String, String?>{};
    final mappedRadioKeys = <String, Set<String>>{};
    for (final entry in checkedness.entries) {
      final record = _records[entry.key];
      if (record == null) continue;
      if (record.descriptor.type == NativeHtmlControlType.checkbox) {
        _checkboxSelection[entry.key] = entry.value;
      } else {
        final group = record.radioGroup ?? entry.key;
        radioGroups.putIfAbsent(group, () => null);
        (mappedRadioKeys[group] ??= <String>{}).add(entry.key);
        if (entry.value) radioGroups[group] = entry.key;
      }
    }
    for (final entry in radioGroups.entries) {
      final current = _radioSelection[entry.key];
      if (entry.value == null &&
          current != null &&
          !(mappedRadioKeys[entry.key]?.contains(current) ?? false)) {
        continue;
      }
      _radioSelection[entry.key] = entry.value;
    }
    notifyListeners();
  }

  /// Transfers widget-owned focus and stable keys for uniquely identified
  /// controls. The new state keeps its freshly parsed checkedness and metadata.
  /// [preserveValues] is for presentation changes of an unchanged static DOM;
  /// script publications keep fresh DOM values and authored reset defaults.
  void adoptInteractionState(
    NativeHtmlControlState previous, {
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
      if (preserveValues) {
        final record = entry.value.value;
        final checked = previous.isChecked(oldKey);
        if (record.descriptor.type == NativeHtmlControlType.checkbox) {
          _checkboxSelection[newKey] = checked;
        } else {
          final group = record.radioGroup ?? newKey;
          if (checked) {
            _radioSelection[group] = newKey;
          } else if (_radioSelection[group] == newKey) {
            _radioSelection[group] = null;
          }
        }
      }
      final focusNode = previous._focusNodes.remove(oldKey);
      if (focusNode != null) _focusNodes[newKey] = focusNode;
      final widgetKey = previous._widgetKeys.remove(oldKey);
      if (widgetKey != null) _widgetKeys[newKey] = widgetKey;
      previous._records.remove(oldKey);
    }
  }

  GlobalKey widgetKeyFor(String key) =>
      _widgetKeys.putIfAbsent(key, GlobalKey.new);

  bool isTabStop(String key) {
    final record = _records[key];
    if (record == null ||
        record.descriptor.disabled ||
        !record.descriptor.visible) {
      return false;
    }
    if (record.descriptor.type == NativeHtmlControlType.checkbox) return true;
    final members = _radioMembers[record.radioGroup ?? key] ?? [key];
    final enabled = members
        .where(
          (member) =>
              !_records[member]!.descriptor.disabled &&
              _records[member]!.descriptor.visible &&
              (_focusNodes[member]?.canRequestFocus ?? true),
        )
        .toList();
    if (enabled.isEmpty) return false;
    final selected = _radioSelection[record.radioGroup ?? key];
    final tabKey = selected != null && enabled.contains(selected)
        ? selected
        : enabled.first;
    return tabKey == key;
  }

  /// Restores the authored checkedness of the controls owned by one form.
  void resetDefaults(Iterable<String> keys) {
    final groups = <String, List<_ControlRecord>>{};
    for (final key in keys) {
      final record = _records[key];
      if (record == null) continue;
      if (record.descriptor.type == NativeHtmlControlType.checkbox) {
        _checkboxSelection[key] = record.descriptor.checked;
      } else {
        (groups[record.radioGroup ?? key] ??= []).add(record);
      }
    }
    for (final entry in groups.entries) {
      String? checked;
      for (final record in entry.value) {
        if (record.descriptor.checked) checked = record.descriptor.key;
      }
      _radioSelection[entry.key] = checked;
    }
    notifyListeners();
  }

  void activateControl(String key) {
    final record = _records[key];
    if (record == null || record.descriptor.disabled) return;
    final activate = onActivateControl;
    if (activate != null) {
      activate(key);
      return;
    }
    if (record.descriptor.type == NativeHtmlControlType.checkbox) {
      _checkboxSelection[key] = !(_checkboxSelection[key] ?? false);
      notifyListeners();
      _emitUserChange(key);
      return;
    }
    final group = record.radioGroup ?? key;
    if (_radioSelection[group] == key) return;
    _radioSelection[group] = key;
    notifyListeners();
    _emitUserChange(key);
  }

  /// Moves to and selects the next enabled radio in source order. Returns its
  /// opaque key, allowing the caller to transfer keyboard focus.
  String? moveRadio(String key, int delta) {
    final record = _records[key];
    if (record == null ||
        record.descriptor.disabled ||
        record.descriptor.type != NativeHtmlControlType.radio) {
      return null;
    }
    final group = record.radioGroup ?? key;
    final enabled = (_radioMembers[group] ?? [key])
        .where(
          (member) =>
              !_records[member]!.descriptor.disabled &&
              _records[member]!.descriptor.visible &&
              (_focusNodes[member]?.canRequestFocus ?? true),
        )
        .toList();
    if (enabled.isEmpty) return null;
    final at = enabled.indexOf(key);
    final next = enabled[(at + delta + enabled.length) % enabled.length];
    activateControl(next);
    focusControl(next);
    return next;
  }

  void focusControl(String key) => _focusNodes[key]?.requestFocus();

  FocusNode? focusNodeFor(String key) => _focusNodes[key];

  void attachFocusNode(String key, FocusNode node) {
    _focusNodes[key] = node;
  }

  void detachFocusNode(String key, FocusNode node) {
    if (identical(_focusNodes[key], node)) _focusNodes.remove(key);
  }

  void _emitUserChange(String key) {
    final callback = onUserEvent;
    callback?.call(key, 'input');
    callback?.call(key, 'change');
  }

  Map<String, MapEntry<String, _ControlRecord>> _uniqueRecordsByScriptId(
    Map<String, _ControlRecord> records,
  ) {
    final grouped = <String, List<MapEntry<String, _ControlRecord>>>{};
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

  String? _radioGroup(
    dom.Element input,
    Map<String, dom.Element> firstById,
    String key,
  ) {
    final name = input.attributes['name'];
    if (name == null || name.isEmpty) return null;
    dom.Element? owner;
    if (input.attributes.containsKey('form')) {
      final id = input.attributes['form'];
      if (id != null) {
        for (final element in firstById.values) {
          if (element.localName == 'form' && element.attributes['id'] == id) {
            owner = element;
            break;
          }
        }
      }
    } else {
      for (var parent = input.parent; parent != null; parent = parent.parent) {
        if (parent.localName == 'form') {
          owner = parent;
          break;
        }
      }
    }
    final ownerKey = owner == null ? 'document' : _elementPath(owner);
    return '$_nonce:$ownerKey:$name';
  }

  dom.Element? _labelTarget(
    dom.Element label,
    Map<String, dom.Element> firstById,
    Map<dom.Element, _PendingControl> controls,
  ) {
    if (label.attributes.containsKey('for')) {
      final target = firstById[label.attributes['for']];
      return target != null && controls.containsKey(target) ? target : null;
    }
    for (final element in _labelDescendants(label)) {
      if (element.localName == 'input') {
        if (element.attributes['type']?.toLowerCase() == 'hidden') continue;
        return controls.containsKey(element) ? element : null;
      }
      if (const {
        'button',
        'meter',
        'output',
        'progress',
        'select',
        'textarea',
      }.contains(element.localName)) {
        return null;
      }
    }
    return null;
  }

  static Iterable<dom.Element> _labelDescendants(dom.Element label) sync* {
    for (final child in label.children) {
      if (child.localName == 'label') continue;
      yield child;
      yield* _labelDescendants(child);
    }
  }

  bool _disabledByFieldset(dom.Element input) {
    dom.Node? parent = input.parentNode;
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
        final exempt = firstLegend != null && _isWithin(input, firstLegend);
        if (!exempt) return true;
      }
      parent = parent.parentNode;
    }
    return false;
  }

  bool _visibleForNavigation(dom.Element input) {
    for (
      dom.Element? current = input;
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

  String _elementPath(dom.Element element) {
    final path = <int>[];
    dom.Node current = element;
    while (current.parentNode != null) {
      final parent = current.parentNode!;
      path.add(parent.nodes.indexOf(current));
      current = parent;
    }
    return path.reversed.join('.');
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

class _PendingControl {
  const _PendingControl({
    required this.key,
    required this.element,
    required this.type,
    required this.name,
    required this.disabled,
    required this.visible,
    required this.checked,
    required this.group,
  });

  final String key;
  final dom.Element element;
  final NativeHtmlControlType type;
  final String? name;
  final bool disabled;
  final bool visible;
  final bool checked;
  final String? group;
}

class _ControlRecord {
  const _ControlRecord(this.descriptor, {required this.radioGroup});

  final NativeHtmlControlDescriptor descriptor;
  final String? radioGroup;
}

class NativeHtmlControlWidget extends StatefulWidget {
  const NativeHtmlControlWidget({
    super.key,
    required this.state,
    required this.control,
    required this.accent,
    this.boxStyle,
  });

  final NativeHtmlControlBoxStyle? boxStyle;
  final NativeHtmlControlState state;
  final NativeHtmlControlDescriptor control;
  final Color accent;

  @override
  State<NativeHtmlControlWidget> createState() =>
      _NativeHtmlControlWidgetState();
}

class _NativeHtmlControlWidgetState extends State<NativeHtmlControlWidget> {
  late final FocusNode _focusNode;
  bool _spacePressed = false;

  void _handleFocusChanged() {
    if (!_focusNode.hasPrimaryFocus) _spacePressed = false;
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(debugLabel: widget.control.label);
    _focusNode.addListener(_handleFocusChanged);
    widget.state.attachFocusNode(widget.control.key, _focusNode);
  }

  @override
  void didUpdateWidget(covariant NativeHtmlControlWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state ||
        oldWidget.control.key != widget.control.key) {
      _spacePressed = false;
      oldWidget.state.detachFocusNode(oldWidget.control.key, _focusNode);
      widget.state.attachFocusNode(widget.control.key, _focusNode);
    }
  }

  @override
  void dispose() {
    widget.state.detachFocusNode(widget.control.key, _focusNode);
    _focusNode.removeListener(_handleFocusChanged);
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (widget.control.disabled) return KeyEventResult.ignored;
    final isDown = event is KeyDownEvent;
    final isRepeat = event is KeyRepeatEvent;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      if (isDown) _spacePressed = true;
      if (event is KeyUpEvent) {
        final activate = _spacePressed && node.hasPrimaryFocus;
        _spacePressed = false;
        if (activate) widget.state.activateControl(widget.control.key);
      }
      return KeyEventResult.handled;
    }
    if (!isDown && !isRepeat) return KeyEventResult.ignored;
    if (widget.control.type == NativeHtmlControlType.radio) {
      final delta = switch (key) {
        LogicalKeyboardKey.arrowLeft || LogicalKeyboardKey.arrowUp => -1,
        LogicalKeyboardKey.arrowRight || LogicalKeyboardKey.arrowDown => 1,
        _ => 0,
      };
      if (delta != 0) {
        widget.state.moveRadio(widget.control.key, delta);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, child) {
        final control = widget.control;
        final checked = widget.state.isChecked(control.key);
        final radio = control.type == NativeHtmlControlType.radio;
        final disabled = control.disabled;
        return Semantics(
          key: ValueKey('native-html-control-${control.key}'),
          container: true,
          label: control.label.isEmpty ? null : control.label,
          hint: control.hint.isEmpty ? null : control.hint,
          checked: checked,
          enabled: !disabled,
          inMutuallyExclusiveGroup: radio,
          focusable: !disabled && widget.state.isTabStop(control.key),
          focused: _focusNode.hasFocus,
          onTap: disabled
              ? null
              : () {
                  widget.state.activateControl(control.key);
                  _focusNode.requestFocus();
                },
          child: Focus(
            focusNode: _focusNode,
            canRequestFocus: !disabled && control.visible,
            skipTraversal: radio && !widget.state.isTabStop(control.key),
            onKeyEvent: _handleKey,
            child: GestureDetector(
              excludeFromSemantics: true,
              behavior: HitTestBehavior.opaque,
              onTap: disabled
                  ? null
                  : () {
                      _focusNode.requestFocus();
                      widget.state.activateControl(control.key);
                    },
              child: _flowBox(context, checked, _focusNode.hasFocus),
            ),
          ),
        );
      },
    );
  }

  Widget _flowBox(BuildContext context, bool checked, bool focused) {
    const size = 13.0;
    final control = SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _NativeControlPainter(
          type: widget.control.type,
          checked: checked,
          disabled: widget.control.disabled,
          dark: Theme.of(context).brightness == Brightness.dark,
          focused: focused,
          accent: widget.accent,
        ),
      ),
    );
    final style = widget.boxStyle;
    if (style != null) {
      Size natural(BoxConstraints constraints) {
        final padding = style.resolvePadding(constraints),
            border = style.border.dimensions.resolve(
              Directionality.of(context),
            );
        return Size(
          size + padding.horizontal + border.horizontal,
          size + padding.vertical + border.vertical,
        );
      }

      final intrinsic = style.resolveLayout(
        intrinsicBorderBoxSize: natural(const BoxConstraints()),
        constraints: const BoxConstraints(),
      );
      return NativeHtmlControlIntrinsic(
        intrinsicSize: intrinsic.size,
        baselineFromTop: intrinsic.size.height,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final layout = style.resolveLayout(
              intrinsicBorderBoxSize: natural(constraints),
              constraints: constraints,
            );
            return CustomPaint(
              foregroundPainter: NativeHtmlControlBorderPainter(
                border: layout.border,
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
                padding:
                    layout.padding +
                    layout.border.dimensions.resolve(
                      Directionality.of(context),
                    ),
                child: CustomPaint(
                  painter: _NativeControlPainter(
                    type: widget.control.type,
                    checked: checked,
                    disabled: widget.control.disabled,
                    dark: Theme.of(context).brightness == Brightness.dark,
                    focused: focused,
                    accent: widget.accent,
                  ),
                ),
              ),
            );
          },
        ),
      );
    }
    if (widget.control.type == NativeHtmlControlType.checkbox) {
      final fontSize = DefaultTextStyle.of(context).style.fontSize ?? 15;
      return Transform.translate(
        offset: const Offset(0, 1),
        child: Padding(
          padding: EdgeInsets.only(right: fontSize * .45),
          child: control,
        ),
      );
    }
    // Chromium's default radio margins are 5px left, 3px top/right.
    return Padding(
      padding: const EdgeInsets.fromLTRB(5, 3, 3, 0),
      child: control,
    );
  }
}

class _NativeControlPainter extends CustomPainter {
  const _NativeControlPainter({
    required this.type,
    required this.checked,
    required this.disabled,
    required this.dark,
    required this.focused,
    required this.accent,
  });

  final NativeHtmlControlType type;
  final bool checked;
  final bool disabled;
  final bool dark;
  final bool focused;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final edge = disabled
        ? (dark ? const Color(0xff626262) : const Color(0xffd1d1d1))
        : (dark ? const Color(0xff858585) : const Color(0xff767676));
    final fill = disabled
        ? (dark ? const Color(0xff3b3b3b) : const Color(0xfff8f8f8))
        : (dark ? const Color(0xff3b3b3b) : const Color(0xffffffff));
    final chosen = disabled
        ? (dark ? const Color(0xff757575) : const Color(0xffd1d1d1))
        : type == NativeHtmlControlType.radio
        // The pinned CSS only assigns accent-color to checkboxes. Radio
        // accent:auto uses Chromium's native light/dark control palette.
        ? (dark ? const Color(0xff99c8ff) : const Color(0xff0075ff))
        : accent;
    if (focused) {
      final focusRect = rect.inflate(2);
      canvas.drawRRect(
        RRect.fromRectAndRadius(focusRect, const Radius.circular(4)),
        Paint()
          ..color = accent.withValues(alpha: .72)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    if (type == NativeHtmlControlType.checkbox) {
      final shape = RRect.fromRectAndRadius(
        rect.deflate(.5),
        const Radius.circular(2),
      );
      canvas.drawRRect(shape, Paint()..color = checked ? chosen : fill);
      canvas.drawRRect(
        shape,
        Paint()
          ..color = checked ? chosen : edge
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      if (checked) {
        canvas.drawPath(
          Path()
            ..moveTo(3 * size.width / 13, 6.5 * size.height / 13)
            ..lineTo(5.2 * size.width / 13, 8.7 * size.height / 13)
            ..lineTo(10 * size.width / 13, 3.6 * size.height / 13),
          Paint()
            ..color = dark
                ? const Color(0xff3b3b3b)
                : disabled
                ? const Color(0xffededed)
                : Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.55
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round,
        );
      }
      return;
    }

    final center = rect.center, scale = math.min(size.width, size.height) / 13;
    canvas.drawCircle(
      center,
      6.25 * scale,
      Paint()..color = checked ? chosen : edge,
    );
    canvas.drawCircle(center, 5.2 * scale, Paint()..color = fill);
    if (checked) {
      canvas.drawCircle(center, 3.0 * scale, Paint()..color = chosen);
    }
  }

  @override
  bool shouldRepaint(covariant _NativeControlPainter oldDelegate) =>
      type != oldDelegate.type ||
      checked != oldDelegate.checked ||
      disabled != oldDelegate.disabled ||
      dark != oldDelegate.dark ||
      focused != oldDelegate.focused ||
      accent != oldDelegate.accent;
}
