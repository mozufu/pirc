import 'dart:async';
import 'dart:ui' show SemanticsRole;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'html_control_box_style.dart';
import 'html_control_border_painter.dart';
import 'html_select.dart';
import 'html_keyboard_events.dart';

/// Native select UI. Browser/platform popup painting and font metrics remain
/// explicitly measured differences in PARITY.md.
class NativeHtmlSelectWidget extends StatefulWidget {
  const NativeHtmlSelectWidget({
    super.key,
    required this.state,
    required this.control,
    required this.textStyle,
    this.boxStyle,
  });
  final NativeHtmlSelectState state;
  final NativeHtmlSelectDescriptor control;
  final TextStyle textStyle;
  final NativeHtmlControlBoxStyle? boxStyle;
  @override
  State<NativeHtmlSelectWidget> createState() => _NativeHtmlSelectWidgetState();
}

class _NativeHtmlSelectWidgetState extends State<NativeHtmlSelectWidget> {
  final _scroll = ScrollController();
  final _optionKeys = <int, GlobalKey>{};
  int? _active;
  int? _anchor;
  String _query = '';
  DateTime? _lastTyped;
  bool _popupOpen = false;
  bool _touchPointer = false;
  ModalRoute<dynamic>? _popupRoute;
  NavigatorState? _popupNavigator;
  Future<void> _keyTail = Future<void>.value();
  FocusNode? _observedFocus;
  int _focusEpoch = 0;

  NativeHtmlSelectDescriptor get control => widget.control;
  NativeHtmlSelectState get state => widget.state;
  FocusNode get focus => state.focusNodeFor(control.key);
  bool get listbox => control.multiple || control.size > 1;
  List<int> get selected => state.selectedIndices(control.key).toList();
  List<int> get enabled => [
    for (final option in control.options)
      if (!option.disabled) option.index,
  ];

  @override
  void initState() {
    super.initState();
    _bindFocus();
  }

  @override
  void didUpdateWidget(covariant NativeHtmlSelectWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    _bindFocus();
    if (_active != null && !enabled.contains(_active)) _active = null;
  }

  void _bindFocus() {
    if (identical(_observedFocus, focus)) return;
    _observedFocus?.removeListener(_focusChanged);
    _focusEpoch++;
    _observedFocus = focus;
    focus.addListener(_focusChanged);
  }

  void _focusChanged() {
    if (_observedFocus?.hasFocus != true && !_popupOpen) _focusEpoch++;
  }

  @override
  void dispose() {
    _observedFocus?.removeListener(_focusChanged);
    _focusEpoch++;
    final route = _popupRoute;
    final navigator = _popupNavigator;
    if (route != null && navigator != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (navigator.mounted && route.isActive) navigator.removeRoute(route);
      });
    }
    _scroll.dispose();
    super.dispose();
  }

  TextStyle get style {
    if (widget.boxStyle != null) {
      return widget.textStyle.copyWith(inherit: false);
    }
    return TextStyle(
      inherit: false,
      fontFamily: widget.textStyle.fontFamily,
      fontFamilyFallback: widget.textStyle.fontFamilyFallback,
      fontSize: widget.textStyle.fontSize ?? 16,
      fontWeight: widget.textStyle.fontWeight,
      fontStyle: widget.textStyle.fontStyle,
      letterSpacing: widget.textStyle.letterSpacing,
      color: widget.textStyle.color,
    );
  }

  void _choose(
    int index, {
    bool toggle = false,
    bool range = false,
    bool navigateOnly = false,
  }) {
    if (control.disabled || !control.visible || !enabled.contains(index)) {
      return;
    }
    focus.requestFocus();
    final anchor = _anchor ?? _active ?? selected.firstOrNull ?? index;
    _active = index;
    if (!navigateOnly) {
      final next = selected.toSet();
      if (control.multiple && range) {
        _anchor ??= anchor;
        next
          ..clear()
          ..addAll(
            enabled.where(
              (i) =>
                  i >= math.min(anchor, index) && i <= math.max(anchor, index),
            ),
          );
      } else if (control.multiple && toggle) {
        next.contains(index) ? next.remove(index) : next.add(index);
        _anchor = index;
      } else {
        next
          ..clear()
          ..add(index);
        _anchor = index;
      }
      state.selectIndices(control.key, next);
    }
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !listbox) return;
      final target = _optionKeys[index]?.currentContext;
      if (target != null) {
        Scrollable.ensureVisible(
          target,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
      }
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (control.disabled || !control.visible) return KeyEventResult.ignored;
    final data = nativeHtmlKeyboardEventData(event);
    final down = event is! KeyUpEvent;
    final key = event.logicalKey;
    final character = event.character;
    final modifier = data['ctrlKey'] == true || data['metaKey'] == true;
    final hasDefault =
        down &&
        enabled.isNotEmpty &&
        (const [
              LogicalKeyboardKey.home,
              LogicalKeyboardKey.end,
              LogicalKeyboardKey.arrowDown,
              LogicalKeyboardKey.arrowUp,
              LogicalKeyboardKey.space,
              LogicalKeyboardKey.enter,
            ].contains(key) ||
            (!modifier &&
                character != null &&
                character.runes.length == 1 &&
                character.trim().isNotEmpty));
    if (state.onUserKeyEvent == null) {
      if (hasDefault) _applyKey(key, character, data);
    } else {
      final identity = state.widgetKeyFor(control.key);
      final epoch = _focusEpoch;
      _keyTail = _keyTail.then((_) async {
        if (!mounted ||
            epoch != _focusEpoch ||
            !focus.hasFocus ||
            !identical(identity, state.widgetKeyFor(control.key))) {
          return;
        }
        final callback = state.onUserKeyEvent;
        if (callback == null) return;
        try {
          final prevented = await callback(
            control.key,
            down ? 'keydown' : 'keyup',
            data,
          );
          if (!down || !hasDefault || prevented) return;
          // Script handlers may replace options or selectedness. Apply the
          // resulting document snapshot before reading this default action.
          await WidgetsBinding.instance.endOfFrame;
          if (!mounted ||
              epoch != _focusEpoch ||
              !focus.hasFocus ||
              !identical(identity, state.widgetKeyFor(control.key)) ||
              control.disabled ||
              !control.visible ||
              enabled.isEmpty) {
            return;
          }
          _applyKey(key, character, data);
        } catch (_) {
          // A failed or replaced script interaction must not apply a stale default.
        }
      });
    }
    return hasDefault ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  void _applyKey(
    LogicalKeyboardKey key,
    String? character,
    Map<String, dynamic> data,
  ) {
    final shift = data['shiftKey'] == true;
    final modifier = data['ctrlKey'] == true || data['metaKey'] == true;
    final current = control.multiple
        ? (_active ?? selected.firstOrNull)
        : selected.firstOrNull;
    int? next;
    if (key == LogicalKeyboardKey.home) next = enabled.first;
    if (key == LogicalKeyboardKey.end) next = enabled.last;
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      final ordinal = current == null ? -1 : enabled.indexOf(current);
      final offset = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
      next = enabled[(ordinal + offset).clamp(0, enabled.length - 1)];
    }
    if (next != null) {
      _choose(
        next,
        range: shift,
        navigateOnly: listbox && control.multiple && modifier && !shift,
      );
      return;
    }
    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.enter) {
      if (!listbox) {
        unawaited(_open());
      } else if (current != null) {
        _choose(current, toggle: control.multiple);
      }
      return;
    }
    if (!modifier &&
        character != null &&
        character.runes.length == 1 &&
        character.trim().isNotEmpty) {
      final now = DateTime.now();
      if (_lastTyped == null ||
          now.difference(_lastTyped!) > const Duration(seconds: 1)) {
        _query = '';
      }
      _lastTyped = now;
      _query += character.toLowerCase();
      final start = current == null ? -1 : enabled.indexOf(current);
      final order = [...enabled.skip(start + 1), ...enabled.take(start + 1)];
      final match = order
          .where(
            (i) => control.options[i].label.toLowerCase().startsWith(_query),
          )
          .firstOrNull;
      if (match != null) _choose(match);
    }
  }

  void _tap() {
    focus.requestFocus();
    FocusManager.instance.applyFocusChangesIfNeeded();
    state.recordUserClick(control.key);
    unawaited(_open());
  }

  void _tapOption(int index) {
    focus.requestFocus();
    FocusManager.instance.applyFocusChangesIfNeeded();
    _choose(
      index,
      toggle:
          control.multiple &&
          (_touchPointer ||
              HardwareKeyboard.instance.isControlPressed ||
              HardwareKeyboard.instance.isMetaPressed),
      range: HardwareKeyboard.instance.isShiftPressed,
    );
    state.recordUserClick(control.key, optionIndex: index);
  }

  ({double width, double line}) _measure(BuildContext context) {
    var width = 0.0, line = 0.0;
    void measure(String text, {bool bold = false, double indent = 0}) {
      final painter = TextPainter(
        text: TextSpan(
          text: text.isEmpty ? ' ' : text,
          style: bold ? style.copyWith(fontWeight: FontWeight.bold) : style,
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      width = math.max(width, painter.width + indent);
      line = math.max(line, painter.height);
      painter.dispose();
    }

    measure('');
    for (final option in control.options) {
      measure(option.label, indent: listbox && option.group != null ? 18 : 0);
    }
    for (final group in control.groups) {
      measure(group.label, bold: true);
    }
    return (width: width + (listbox ? 6 : 20), line: line);
  }

  Future<void> _open() async {
    if (_popupOpen ||
        control.disabled ||
        !control.visible ||
        control.entries.isEmpty) {
      return;
    }
    focus.requestFocus();
    setState(() => _popupOpen = true);
    state.setPopupOpen(control.key, true);
    final box = context.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final rect = Rect.fromPoints(
      box.localToGlobal(Offset.zero, ancestor: overlay),
      box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
    );
    final metrics = _measure(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final items = <PopupMenuEntry<int>>[];
    for (final entry in control.entries) {
      if (entry is NativeHtmlSelectGroup) {
        items.add(
          PopupMenuItem<int>(
            enabled: false,
            height: metrics.line + 1,
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Builder(
              builder: (menuContext) {
                _popupRoute = ModalRoute.of(menuContext);
                return Text(
                  entry.label,
                  style: style.copyWith(fontWeight: FontWeight.bold),
                );
              },
            ),
          ),
        );
        continue;
      }
      final option = entry as NativeHtmlSelectOption;
      items.add(
        PopupMenuItem<int>(
          value: option.index,
          enabled: !option.disabled,
          height: metrics.line + 1,
          padding: EdgeInsets.only(
            left: option.group == null ? 2 : 20,
            right: 2,
          ),
          child: Builder(
            builder: (menuContext) {
              _popupRoute = ModalRoute.of(menuContext);
              return Text(
                option.label,
                maxLines: 1,
                style: style.copyWith(
                  color: option.disabled
                      ? const Color(0xff808080)
                      : style.color,
                ),
              );
            },
          ),
        ),
      );
    }
    _popupNavigator = Navigator.of(context);
    int? value;
    try {
      value = await showMenu<int>(
        context: context,
        position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
        initialValue: selected.firstOrNull,
        items: items,
        constraints: BoxConstraints(
          minWidth: metrics.width,
          maxWidth: math.max(metrics.width, rect.width),
        ),
        menuPadding: EdgeInsets.zero,
        color: dark ? const Color(0xff3b3b3b) : Colors.white,
        elevation: 2,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(2)),
        ),
        requestFocus: true,
      );
    } finally {
      if (mounted) {
        setState(() => _popupOpen = false);
        _popupRoute = null;
        _popupNavigator = null;
        focus.requestFocus();
        final current = state;
        final key = control.key;
        scheduleMicrotask(() => current.setPopupOpen(key, false));
      }
    }
    if (mounted && value != null) _choose(value);
  }

  @override
  Widget build(BuildContext context) {
    if (!control.visible) return const SizedBox.shrink();
    final metrics = _measure(context);
    final boxStyle = widget.boxStyle;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final border = dark ? const Color(0xff858585) : const Color(0xff767676);
    final background = dark ? const Color(0xff3b3b3b) : Colors.white;
    return AnimatedBuilder(
      animation: Listenable.merge([state, focus]),
      builder: (context, _) {
        Widget content;
        if (listbox) {
          final children = <Widget>[];
          for (final entry in control.entries) {
            if (entry is NativeHtmlSelectGroup) {
              children.add(
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: boxStyle == null ? 2 : 0,
                  ),
                  child: Text(
                    entry.label,
                    style: style.copyWith(fontWeight: FontWeight.bold),
                    maxLines: 1,
                  ),
                ),
              );
              continue;
            }
            final option = entry as NativeHtmlSelectOption;
            final chosen = selected.contains(option.index);
            children.add(
              Semantics(
                selected: chosen,
                enabled: !control.disabled && !option.disabled,
                child: GestureDetector(
                  onTapDown: (details) => _touchPointer =
                      details.kind == PointerDeviceKind.touch ||
                      details.kind == PointerDeviceKind.stylus,
                  behavior: HitTestBehavior.opaque,
                  onTap: control.disabled || option.disabled
                      ? null
                      : () => _tapOption(option.index),
                  child: Container(
                    key: _optionKeys.putIfAbsent(option.index, GlobalKey.new),
                    color: chosen
                        ? (focus.hasFocus
                              ? const Color(0xff1967d2)
                              : dark
                              ? const Color(0xff565656)
                              : const Color(0xffcecece))
                        : null,
                    padding: EdgeInsets.only(
                      left:
                          (boxStyle == null ? 2 : 0) +
                          (option.group == null ? 0 : 18),
                      right: boxStyle == null ? 2 : 0,
                      bottom: 1,
                    ),
                    child: Text(
                      option.label,
                      maxLines: 1,
                      softWrap: false,
                      style: style.copyWith(
                        color: option.disabled
                            ? const Color(0xff808080)
                            : chosen && focus.hasFocus
                            ? Colors.white
                            : style.color,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }
          final rows = SingleChildScrollView(
            controller: _scroll,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          );
          content = boxStyle == null
              ? SizedBox(
                  height:
                      (metrics.line + 1) *
                      (control.size > 0 ? control.size : 4),
                  child: rows,
                )
              : rows;
        } else {
          final label = selected.isEmpty
              ? ''
              : control.options[selected.first].label;
          content = GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: control.disabled ? null : _tap,
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(left: boxStyle == null ? 2 : 0),
                    child: Text(
                      label,
                      maxLines: 1,
                      softWrap: false,
                      style: style,
                    ),
                  ),
                ),
                Icon(Icons.arrow_drop_down, size: 16, color: style.color),
              ],
            ),
          );
        }
        final surface = boxStyle == null
            ? Container(
                width: metrics.width,
                decoration: BoxDecoration(
                  color: background,
                  border: Border.all(
                    color: focus.hasFocus
                        ? Theme.of(context).colorScheme.primary
                        : border,
                  ),
                  borderRadius: BorderRadius.circular(listbox ? 2 : 0),
                ),
                child: content,
              )
            : LayoutBuilder(
                builder: (context, constraints) {
                  final resolvedPadding = boxStyle.resolvePadding(constraints);
                  final intrinsicContentWidth = listbox
                      ? math.max(0, metrics.width - 6)
                      : math.max(0, metrics.width - 20 + 16);
                  final intrinsicContentHeight = listbox
                      ? (metrics.line + 1) *
                            (control.size > 0 ? control.size : 4)
                      : metrics.line;
                  final intrinsicSize = Size(
                    intrinsicContentWidth +
                        resolvedPadding.horizontal +
                        boxStyle.border.left.width +
                        boxStyle.border.right.width,
                    intrinsicContentHeight +
                        resolvedPadding.vertical +
                        boxStyle.border.top.width +
                        boxStyle.border.bottom.width,
                  );
                  final layout = boxStyle.resolveLayout(
                    intrinsicBorderBoxSize: intrinsicSize,
                    constraints: constraints,
                  );
                  final hasAuthoredBorder = boxStyle.specifiedProperties.any(
                    (property) =>
                        property == 'border' ||
                        property == 'border-width' ||
                        property == 'border-style' ||
                        property == 'border-color' ||
                        RegExp(
                          r'^border-(top|right|bottom|left)(-|$)',
                        ).hasMatch(property),
                  );
                  final focusedBorderColor = Theme.of(
                    context,
                  ).colorScheme.primary;
                  final resolvedBorder = focus.hasFocus && !hasAuthoredBorder
                      ? Border(
                          top: layout.border.top.copyWith(
                            color: focusedBorderColor,
                          ),
                          right: layout.border.right.copyWith(
                            color: focusedBorderColor,
                          ),
                          bottom: layout.border.bottom.copyWith(
                            color: focusedBorderColor,
                          ),
                          left: layout.border.left.copyWith(
                            color: focusedBorderColor,
                          ),
                        )
                      : layout.border;
                  final hasAuthoredRadius = boxStyle.specifiedProperties.any(
                    (property) =>
                        property == 'border-radius' ||
                        property == 'border-top-left-radius' ||
                        property == 'border-top-right-radius' ||
                        property == 'border-bottom-left-radius' ||
                        property == 'border-bottom-right-radius',
                  );
                  return SizedBox(
                    width: layout.size.width,
                    height: layout.size.height,
                    child: CustomPaint(
                      foregroundPainter: NativeHtmlControlBorderPainter(
                        border: resolvedBorder,
                        styleNames: boxStyle.borderStyleNames,
                        borderRadius: hasAuthoredRadius
                            ? layout.borderRadius
                            : BorderRadius.circular(listbox ? 2 : 0),
                      ),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: layout.backgroundColor ?? background,
                          borderRadius: hasAuthoredRadius
                              ? layout.borderRadius
                              : BorderRadius.circular(listbox ? 2 : 0),
                        ),
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            layout.border.left.width + layout.padding.left,
                            layout.border.top.width + layout.padding.top,
                            layout.border.right.width + layout.padding.right,
                            layout.border.bottom.width + layout.padding.bottom,
                          ),
                          child: SizedBox.expand(child: content),
                        ),
                      ),
                    ),
                  );
                },
              );
        return Semantics(
          key: ValueKey('native-html-select-${control.key}'),
          // This SDK's comboBox role throws in _DebugSemanticsRoleChecks.
          // Expose an actionable expanded button until the SDK supports it.
          role: listbox ? SemanticsRole.list : SemanticsRole.none,
          button: !listbox,
          excludeSemantics: !listbox,
          value: listbox
              ? null
              : selected
                    .map((index) => control.options[index].label)
                    .join(', '),
          expanded: listbox ? null : _popupOpen,
          onTap: !listbox && !control.disabled ? _tap : null,
          label: control.label.isEmpty ? null : control.label,
          hint: control.hint.isEmpty ? null : control.hint,
          enabled: !control.disabled,
          focusable: !control.disabled,
          focused: focus.hasFocus,
          child: Focus(
            focusNode: focus,
            onKeyEvent: _onKey,
            child: Opacity(opacity: control.disabled ? .45 : 1, child: surface),
          ),
        );
      },
    );
  }
}
