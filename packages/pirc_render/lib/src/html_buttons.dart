import 'render_l10n.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import 'render_theme.dart';

enum NativeHtmlButtonType { button, reset, submit }

@immutable
class NativeHtmlButtonDescriptor {
  const NativeHtmlButtonDescriptor({
    required this.key,
    required this.type,
    required this.label,
    required this.disabled,
    required this.visible,
    required this.input,
    required this.copy,
    required this.copySource,
    required this.formControls,
    required this.contentName,
    required this.nativeAppearance,
  });
  final String key, label, copySource;
  final NativeHtmlButtonType type;
  final bool disabled, visible, input, copy, contentName, nativeAppearance;
  final List<dom.Element> formControls;
}

/// Declarative reset and the pinned Markdown [data-copy] click handler.
/// The optional document adapter performs submit validation and request routing.
class NativeHtmlButtonState extends ChangeNotifier {
  NativeHtmlButtonState._(
    this._source,
    this._nonce,
    this.onReset,
    this.onSubmit,
    this.onClick,
    this.locale,
    this.enhanceMarkdown,
  );
  factory NativeHtmlButtonState.fromHtml(
    String source, {
    required void Function(List<dom.Element>) onReset,
    void Function(dom.Element)? onSubmit,
    Future<bool> Function(dom.Element)? onClick,
    Locale locale = const Locale('en'),
    bool enhanceMarkdown = true,
  }) {
    final nonce = List.generate(
      12,
      (_) =>
          math.Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final state = NativeHtmlButtonState._(
      source,
      nonce,
      onReset,
      onSubmit,
      onClick,
      locale,
      enhanceMarkdown,
    );
    state._scan();
    return state;
  }
  static const _attribute = 'data-pirc-native-button-id';
  static const _labelAttribute = 'data-pirc-native-button-for';
  final String _source, _nonce;
  final void Function(List<dom.Element>) onReset;
  final void Function(dom.Element)? onSubmit;
  Future<bool> Function(dom.Element)? onClick;
  final Locale locale;
  final bool enhanceMarkdown;
  String defaultCaption(NativeHtmlButtonType type) => switch (type) {
    NativeHtmlButtonType.submit =>
      locale.languageCode == 'zh' ? tr("提交") : tr("Submit"),
    NativeHtmlButtonType.reset =>
      locale.languageCode == 'zh' ? tr("重設") : tr("Reset"),
    NativeHtmlButtonType.button => '',
  };
  final Map<String, dom.Element> _submitters = {};
  final Map<String, NativeHtmlButtonDescriptor> _buttons = {};
  final Map<String, String> _display = {};
  final Map<String, FocusNode> _focusNodes = {};
  final Map<String, GlobalKey> _widgetKeys = {};
  final List<Timer> _timers = [];
  late final String _html;
  bool _disposed = false;
  int _activationGeneration = 0;

  /// Invalidates an async script click that is still awaiting its result.
  void invalidatePendingActivations() {
    _activationGeneration++;
  }

  /// Updates the handler for future activations without changing a click
  /// already awaiting its result.
  void updateOnClick(Future<bool> Function(dom.Element)? callback) {
    if (onClick == callback) return;
    onClick = callback;
  }

  String annotateHtml(String source) {
    if (source != _source) {
      throw ArgumentError(tr("Expected the original button fragment"));
    }
    return _html;
  }

  NativeHtmlButtonDescriptor? resolveControl(dom.Element element) =>
      _buttons[element.attributes[_attribute]];
  String? displayText(String key) => _display[key];
  FocusNode focusNodeFor(String key) => _focusNodes[key]!;
  GlobalKey widgetKeyFor(String key) =>
      _widgetKeys.putIfAbsent(key, GlobalKey.new);

  /// Carry focus for the same uniquely identified script element while keeping
  /// new parsed disabledness, label and activation handlers authoritative.
  void adoptInteractionState(NativeHtmlButtonState previous) {
    if (identical(previous, this)) return;
    Map<String, String> unique(NativeHtmlButtonState state) {
      final matches = <String, List<String>>{};
      for (final entry in state._submitters.entries) {
        final id = entry.value.attributes['data-pirc-script-id'];
        if (id != null && id.isNotEmpty) (matches[id] ??= []).add(entry.key);
      }
      return {
        for (final entry in matches.entries)
          if (entry.value.length == 1) entry.key: entry.value.single,
      };
    }

    final old = unique(previous);
    for (final entry in unique(this).entries) {
      final oldKey = old[entry.key];
      if (oldKey == null) continue;
      final key = entry.value;
      final node = previous._focusNodes.remove(oldKey);
      if (node != null) {
        _focusNodes.remove(key)?.dispose();
        final descriptor = _buttons[key]!;
        _focusNodes[key] = node
          ..debugLabel = descriptor.label
          ..canRequestFocus = !descriptor.disabled && descriptor.visible
          ..skipTraversal = descriptor.disabled || !descriptor.visible;
      }
      final widgetKey = previous._widgetKeys.remove(oldKey);
      if (widgetKey != null) _widgetKeys[key] = widgetKey;
    }
  }

  NativeHtmlButtonDescriptor? resolveLabel(dom.Element element) =>
      element.localName == 'label'
      ? _buttons[element.attributes[_labelAttribute]]
      : null;
  void activateLabel(dom.Element element) {
    final button = resolveLabel(element);
    if (button == null || button.disabled || !button.visible) return;
    focusNodeFor(button.key).requestFocus();
    unawaited(activate(button.key));
  }

  void _scan() {
    final fragment = html.parseFragment(_source);
    final elements = fragment.querySelectorAll('*');
    for (final element in elements) {
      element.attributes.remove(_attribute);
      element.attributes.remove(_labelAttribute);
    }
    final firstById = <String, dom.Element>{};
    for (final element in elements) {
      final id = element.attributes['id'];
      if (id != null && id.isNotEmpty) firstById.putIfAbsent(id, () => element);
    }
    final labels = <dom.Element, List<dom.Element>>{};
    for (final label in elements.where((e) => e.localName == 'label')) {
      final target = label.attributes.containsKey('for')
          ? firstById[label.attributes['for']]
          : label.querySelectorAll('*').where(_labelable).firstOrNull;
      if (target != null && _labelable(target)) {
        (labels[target] ??= []).add(label);
      }
    }
    for (final element in elements) {
      final input = element.localName == 'input';
      final rawType = (element.attributes['type'] ?? '').toLowerCase();
      if (element.localName != 'button' &&
          !(input && const {'button', 'reset', 'submit'}.contains(rawType))) {
        continue;
      }
      final type = switch (rawType) {
        'button' => NativeHtmlButtonType.button,
        'reset' => NativeHtmlButtonType.reset,
        _ => NativeHtmlButtonType.submit,
      };
      final copy =
          enhanceMarkdown && element.attributes.containsKey('data-copy');
      // A standalone button state without a document submit adapter leaves
      // plain submit buttons in the original tree. Copy remains independent.
      if (type == NativeHtmlButtonType.submit &&
          !copy &&
          onSubmit == null &&
          onClick == null) {
        continue;
      }
      final key = '$_nonce-${_buttons.length}';
      _submitters[key] = element;
      final form = _ancestor(element, (e) => e.localName == 'form');
      final block = _ancestor(element, (e) => e.classes.contains('code-block'));
      final label = input
          ? element.attributes['value'] ?? defaultCaption(type)
          : _textAlternative(element);
      element.attributes[_attribute] = key;
      final referencedName = (element.attributes['aria-labelledby'] ?? '')
          .split(RegExp(r'\s+'))
          .where(firstById.containsKey)
          .map((id) => _textAlternative(firstById[id]!))
          .join(' ')
          .trim();
      final ariaName = element.attributes['aria-label'] ?? '';
      final labelName = (labels[element] ?? const <dom.Element>[])
          .map(_textAlternative)
          .join(' ')
          .trim();
      final accessible = referencedName.isNotEmpty
          ? referencedName
          : ariaName.isNotEmpty
          ? ariaName
          : labelName.isNotEmpty
          ? labelName
          : label.isNotEmpty
          ? label
          : element.attributes['title'] ?? '';
      for (final label in labels[element] ?? const <dom.Element>[]) {
        label.attributes[_labelAttribute] = key;
      }
      final disabled =
          element.attributes.containsKey('disabled') ||
          _disabledFieldset(element);
      final visible = !_hidden(element);
      _focusNodes[key] = FocusNode(
        debugLabel: accessible,
        canRequestFocus: !disabled && visible,
        skipTraversal: disabled || !visible,
      );
      _buttons[key] = NativeHtmlButtonDescriptor(
        key: key,
        type: type,
        label: accessible,
        contentName:
            referencedName.isEmpty && ariaName.isEmpty && labelName.isEmpty,
        disabled: disabled,
        visible: visible,
        input: input,
        nativeAppearance:
            (!enhanceMarkdown || !element.classes.contains('code-copy')) &&
            !RegExp(
              r'(?:^|;)\s*(?:border(?:-[\w-]+)?|background(?:-[\w-]+)?|appearance|-webkit-appearance)\s*:',
              caseSensitive: false,
            ).hasMatch(element.attributes['style'] ?? ''),
        copy: copy,
        copySource: block?.querySelector('code')?.text ?? '',
        formControls: List.unmodifiable(
          form?.querySelectorAll('input,textarea,select') ??
              const <dom.Element>[],
        ),
      );
    }
    _html = fragment.outerHtml;
  }

  Future<bool> activate(
    String key, {
    bool implicit = false,
    bool skipScript = false,
  }) async {
    final button = _buttons[key];
    if (_disposed ||
        button == null ||
        button.disabled ||
        (!button.visible && !implicit)) {
      return false;
    }
    final clickElement = _submitters[key]!;
    final callback = onClick;
    if (!skipScript &&
        callback != null &&
        clickElement.attributes.containsKey('data-pirc-script-id')) {
      final generation = _activationGeneration;
      var prevented = false;
      try {
        prevented = await callback(clickElement);
      } catch (_) {
        // A script handler failure is equivalent to a handler that did not
        // prevent the native default action.
      }
      if (_disposed || generation != _activationGeneration) return false;
      if (prevented) return true;
    }
    // The delegated click listener starts the clipboard request before the
    // synchronous reset/submit default action, without awaiting that request.
    final copying = button.copy
        ? Clipboard.setData(ClipboardData(text: button.copySource))
        : null;
    if (button.type == NativeHtmlButtonType.reset) {
      onReset(button.formControls);
    }
    if (button.type == NativeHtmlButtonType.submit) {
      onSubmit?.call(_submitters[key]!);
    }
    if (button.copy) {
      try {
        await copying!;
      } catch (_) {
        return false;
      }
      if (_disposed) return false;
      // The web mutates textContent, so input value labels remain unchanged.
      if (!button.input) {
        _display[key] = tr("Copied");
        notifyListeners();
        _timers.add(
          Timer(const Duration(milliseconds: 1400), () {
            if (_disposed) return;
            _display[key] = tr("Copy");
            notifyListeners();
          }),
        );
      }
    }
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    for (final node in _focusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }
}

dom.Element? _ancestor(dom.Element element, bool Function(dom.Element) match) {
  for (var parent = element.parent; parent != null; parent = parent.parent) {
    if (match(parent)) return parent;
  }
  return null;
}

bool _disabledFieldset(dom.Element element) {
  for (var parent = element.parent; parent != null; parent = parent.parent) {
    if (parent.localName != 'fieldset' ||
        !parent.attributes.containsKey('disabled')) {
      continue;
    }
    final legend = parent.children
        .where((e) => e.localName == 'legend')
        .firstOrNull;
    if (legend != null &&
        (identical(element, legend) ||
            _ancestor(element, (node) => identical(node, legend)) != null)) {
      continue;
    }
    return true;
  }
  return false;
}

bool _hidden(dom.Element element) {
  for (dom.Element? node = element; node != null; node = node.parent) {
    if (node.attributes.containsKey('hidden')) return true;
    final style = (node.attributes['style'] ?? '')
        .replaceAll(RegExp(r'\s+'), '')
        .toLowerCase();
    if (RegExp(
      r'(?:^|;)(?:display:none|visibility:hidden|visibility:collapse)(?:!important)?(?:;|$)',
    ).hasMatch(style)) {
      return true;
    }
  }
  return false;
}

/// Wrap the original rendered child rather than flattening rich button content.
class NativeHtmlButtonWidget extends StatefulWidget {
  const NativeHtmlButtonWidget({
    super.key,
    required this.state,
    required this.button,
    required this.child,
    required this.tree,
  });
  final NativeHtmlButtonState state;
  final NativeHtmlButtonDescriptor button;
  final Widget child;
  final BuildTree tree;
  @override
  State<NativeHtmlButtonWidget> createState() => _NativeHtmlButtonWidgetState();
}

class _NativeHtmlButtonWidgetState extends State<NativeHtmlButtonWidget> {
  FocusNode get focusNode => widget.state.focusNodeFor(widget.button.key);
  bool highlightFocus = false;
  bool spacePressed = false;
  bool get enabled => !widget.button.disabled && widget.button.visible;

  void trigger() {
    unawaited(widget.state.activate(widget.button.key));
  }

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final replacement = widget.state.displayText(widget.button.key);
        return Semantics(
          button: true,
          enabled: enabled,
          label: widget.button.contentName
              ? replacement ?? widget.button.label
              : widget.button.label,
          excludeSemantics: true,
          onTap: enabled ? trigger : null,
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: (_, event) {
              if (!enabled) return KeyEventResult.ignored;
              if (event.logicalKey == LogicalKeyboardKey.enter &&
                  event is KeyDownEvent) {
                trigger();
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.space) {
                if (event is KeyDownEvent) spacePressed = true;
                if (event is KeyUpEvent && spacePressed) {
                  spacePressed = false;
                  trigger();
                }
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: FocusableActionDetector(
              focusNode: focusNode,
              enabled: enabled,
              onShowFocusHighlight: (value) {
                setState(() => highlightFocus = value);
              },
              onFocusChange: (value) {
                if (!value) spacePressed = false;
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: enabled
                    ? () {
                        focusNode.requestFocus();
                        trigger();
                      }
                    : null,
                child: CustomPaint(
                  foregroundPainter: _ButtonFramePainter(
                    color: Theme.of(
                      context,
                    ).extension<RenderColors>()!['accent.default'],
                    focused: highlightFocus,
                    nativeAppearance: widget.button.nativeAppearance,
                    dark: Theme.of(context).brightness == Brightness.dark,
                    disabled: widget.button.disabled,
                    input: widget.button.input,
                  ),
                  child: widget.button.disabled && !widget.button.input
                      ? Opacity(opacity: 0.45, child: widget.child)
                      : widget.child,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ButtonFramePainter extends CustomPainter {
  const _ButtonFramePainter({
    required this.color,
    required this.focused,
    required this.nativeAppearance,
    required this.dark,
    required this.disabled,
    required this.input,
  });
  final Color color;
  final bool focused, nativeAppearance, dark, disabled, input;
  @override
  void paint(Canvas canvas, Size size) {
    if (nativeAppearance) {
      final edge = dark ? const Color(0xff858585) : const Color(0xff767676);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(.5),
          const Radius.circular(1.5),
        ),
        Paint()
          ..color = edge.withValues(alpha: disabled ? (input ? .3 : .45) : 1)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
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
  bool shouldRepaint(_ButtonFramePainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.focused != focused ||
      oldDelegate.nativeAppearance != nativeAppearance ||
      oldDelegate.dark != dark ||
      oldDelegate.disabled != disabled ||
      oldDelegate.input != input;
}

/// This wrapper lives inside the button's styled box so changing the copy label
/// never discards authored padding, borders or background.
class NativeHtmlButtonContent extends StatelessWidget {
  const NativeHtmlButtonContent({
    super.key,
    required this.state,
    required this.button,
    required this.tree,
    required this.child,
  });
  final NativeHtmlButtonState state;
  final NativeHtmlButtonDescriptor button;
  final BuildTree tree;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final replacement = state.displayText(button.key);
        return replacement == null
            ? child
            : IntrinsicWidth(
                child: Text(
                  replacement,
                  textScaler: TextScaler.noScaling,
                  textWidthBasis: TextWidthBasis.longestLine,
                  style: tree.inheritanceResolvers
                      .resolve(context)
                      .prepareTextStyle(),
                ),
              );
      },
    );
  }
}

bool _labelable(dom.Element element) =>
    const {
      'button',
      'meter',
      'output',
      'progress',
      'select',
      'textarea',
    }.contains(element.localName) ||
    (element.localName == 'input' &&
        element.attributes['type']?.toLowerCase() != 'hidden');

String _textAlternative(dom.Element element) {
  String text(dom.Node node) => node is dom.Text
      ? node.text
      : node is dom.Element && node.localName == 'img'
      ? node.attributes['alt'] ?? ''
      : node.nodes.map(text).join();
  return text(element).replaceAll(RegExp(r'\s+'), ' ').trim();
}
