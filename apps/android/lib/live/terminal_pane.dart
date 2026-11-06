import '../l10n/app_i18n.dart';
import 'dart:ui' show SemanticsRole;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:xterm/xterm.dart';
import 'gateway.dart';
import 'common.dart';
import 'web_controls.dart';
import 'terminal_state.dart';
import 'terminal_requests.dart';
import 'terminal_keys.dart';

class TerminalPane extends StatefulWidget {
  const TerminalPane({super.key, required this.controller, this.touch});
  final LiveController controller;
  final bool? touch;
  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  late final state = TerminalPaneState(widget.controller);
  final focus = <String, FocusNode>{};
  FocusNode tabFocus(String id) =>
      focus.putIfAbsent(id, () => FocusNode(debugLabel: 'terminal-tab'));
  @override
  void dispose() {
    state.dispose();
    for (final node in focus.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final p = palette(context),
            active = TickerMode.valuesOf(context).enabled;
        final touch =
            widget.touch ??
            [
              TargetPlatform.android,
              TargetPlatform.iOS,
            ].contains(defaultTargetPlatform);
        final error = state.error.isNotEmpty ? state.error : state.listError;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: p['web.line'])),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    if (state.terminals.isNotEmpty)
                      Semantics(
                        role: SemanticsRole.tabBar,
                        container: true,
                        label: tr("Terminals"),
                        child: Row(
                          children: [
                            for (final (index, terminal)
                                in state.terminals.indexed) ...[
                              if (index > 0) const SizedBox(width: 4),
                              Builder(
                                builder: (context) {
                                  final terminalId = '${terminal['id']}';
                                  final tabLabel =
                                      '${terminal['title']} ${index + 1}';
                                  final node = tabFocus(terminalId);
                                  void selectTab() {
                                    state.select(terminalId);
                                    WidgetsBinding.instance
                                        .addPostFrameCallback((_) {
                                          if (mounted) node.requestFocus();
                                        });
                                  }

                                  return ListenableBuilder(
                                    listenable: node,
                                    builder: (context, _) => Semantics(
                                      container: true,
                                      role: SemanticsRole.tab,
                                      label: tabLabel,
                                      selected: state.current == terminalId,
                                      focusable: true,
                                      focused: node.hasFocus,
                                      onTap: selectTab,
                                      child: Opacity(
                                        opacity: terminal['exited'] == true
                                            ? .6
                                            : 1,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            color: state.current == terminalId
                                                ? p['web.bg-active']
                                                : null,
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Focus(
                                                onKeyEvent: (_, event) {
                                                  if (event is! KeyDownEvent) {
                                                    return KeyEventResult
                                                        .ignored;
                                                  }
                                                  final key = event.logicalKey;
                                                  if (key ==
                                                      LogicalKeyboardKey
                                                          .delete) {
                                                    state.close(terminal);
                                                    return KeyEventResult
                                                        .handled;
                                                  }
                                                  int? next;
                                                  if (key ==
                                                      LogicalKeyboardKey
                                                          .arrowRight) {
                                                    next =
                                                        (index + 1) %
                                                        state.terminals.length;
                                                  }
                                                  if (key ==
                                                      LogicalKeyboardKey
                                                          .arrowLeft) {
                                                    next =
                                                        (index -
                                                            1 +
                                                            state
                                                                .terminals
                                                                .length) %
                                                        state.terminals.length;
                                                  }
                                                  if (key ==
                                                      LogicalKeyboardKey.home) {
                                                    next = 0;
                                                  }
                                                  if (key ==
                                                      LogicalKeyboardKey.end) {
                                                    next =
                                                        state.terminals.length -
                                                        1;
                                                  }
                                                  if (next == null) {
                                                    return KeyEventResult
                                                        .ignored;
                                                  }
                                                  final id =
                                                      '${state.terminals[next]['id']}';
                                                  state.select(id);
                                                  WidgetsBinding.instance
                                                      .addPostFrameCallback((
                                                        _,
                                                      ) {
                                                        if (mounted) {
                                                          tabFocus(
                                                            id,
                                                          ).requestFocus();
                                                        }
                                                      });
                                                  return KeyEventResult.handled;
                                                },
                                                child: ExcludeSemantics(
                                                  child: Tooltip(
                                                    message: tr(
                                                      "Delete closes this terminal",
                                                    ),
                                                    child: InkWell(
                                                      key: ValueKey(
                                                        'terminal-tab-$terminalId',
                                                      ),
                                                      focusNode: node,
                                                      canRequestFocus:
                                                          state.current ==
                                                          terminalId,
                                                      onTap: selectTab,
                                                      splashFactory: NoSplash
                                                          .splashFactory,
                                                      child: Container(
                                                        constraints:
                                                            BoxConstraints(
                                                              minHeight: touch
                                                                  ? 40
                                                                  : 26,
                                                            ),
                                                        padding:
                                                            const EdgeInsets.only(
                                                              left: 8,
                                                              right: 4,
                                                            ),
                                                        child: Row(
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          children: [
                                                            Icon(
                                                              LucideIcons
                                                                  .squareTerminal,
                                                              size: 13,
                                                              color:
                                                                  p[state.current ==
                                                                          terminalId
                                                                      ? 'text.primary'
                                                                      : 'text.secondary'],
                                                            ),
                                                            const SizedBox(
                                                              width: 5,
                                                            ),
                                                            Text(
                                                              tabLabel,
                                                              style: webText(
                                                                context,
                                                                size: 12,
                                                                color:
                                                                    state.current ==
                                                                        terminalId
                                                                    ? 'text.primary'
                                                                    : 'text.secondary',
                                                              ),
                                                            ),
                                                            if (terminalPathLabel(
                                                                  terminal,
                                                                )
                                                                case final path?) ...[
                                                              const SizedBox(
                                                                width: 4,
                                                              ),
                                                              Text(
                                                                path,
                                                                style: webText(
                                                                  context,
                                                                  size: 10,
                                                                  color:
                                                                      'text.muted',
                                                                ),
                                                              ),
                                                            ],
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              Semantics(
                                                label: tr(
                                                  "Close terminal {0}",
                                                  [index + 1],
                                                ),
                                                button: true,
                                                focusable: false,
                                                onTap: () =>
                                                    state.close(terminal),
                                                excludeSemantics: true,
                                                child: Tooltip(
                                                  message: tr(
                                                    "Close terminal {0}",
                                                    [index + 1],
                                                  ),
                                                  child: InkWell(
                                                    canRequestFocus: false,
                                                    onTap: () =>
                                                        state.close(terminal),
                                                    splashFactory:
                                                        NoSplash.splashFactory,
                                                    child: Container(
                                                      height: touch ? 40 : 26,
                                                      padding: EdgeInsets.only(
                                                        left: touch ? 8 : 2,
                                                        right: touch ? 12 : 6,
                                                      ),
                                                      child: Icon(
                                                        LucideIcons.x,
                                                        size: 12,
                                                        color: p['text.muted'],
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ],
                        ),
                      ),
                    if (state.terminals.isNotEmpty) const SizedBox(width: 4),
                    WebIconButton(
                      LucideIcons.plus,
                      state.hasControl
                          ? tr("New terminal")
                          : tr("Take control to open a terminal"),
                      onPressed: state.busy || !state.hasControl
                          ? null
                          : state.create,
                    ),
                    // Explicit and separate; the New terminal action never
                    // falls back to a host terminal.
                    if (state.requests?.capabilities?.offersHostManagement ==
                        true)
                      WebIconButton(
                        LucideIcons.shieldAlert,
                        tr("Host management terminal…"),
                        onPressed: state.busy || !state.hasControl
                            ? null
                            : state.reviewHost,
                      ),
                  ],
                ),
              ),
            ),
            if (error.isNotEmpty)
              Container(
                margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: p['status.dangerSoft'],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  error,
                  style: webText(
                    context,
                    size: 12.5,
                    color: 'status.danger',
                  ).copyWith(height: 1.45),
                ),
              ),
            for (final entry in state.pendingRequests)
              TerminalRequestNotice(state: state, entry: entry),
            if (state.terminals.isEmpty)
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            LucideIcons.squareTerminal,
                            size: 22,
                            color: p['text.muted'],
                          ),
                          const SizedBox(height: 10),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 300),
                            child: Text(
                              tr(
                                "Run commands in this workspace. The shell runs as the gateway’s account, just like the agent’s own tools.",
                              ),
                              textAlign: TextAlign.center,
                              style: webText(
                                context,
                                size: 13,
                                color: 'text.muted',
                              ).copyWith(height: 1.5),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Opacity(
                            opacity: state.busy || !state.hasControl ? .5 : 1,
                            child: TextButton(
                              onPressed: state.busy || !state.hasControl
                                  ? null
                                  : state.create,
                              style: TextButton.styleFrom(
                                minimumSize: const Size(0, 36),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                backgroundColor: p['accent.default'],
                                foregroundColor: p['accent.on'],
                                disabledForegroundColor: p['accent.on'],
                                shape: const StadiumBorder(),
                                textStyle: webText(
                                  context,
                                  size: 14,
                                  weight: FontWeight.w500,
                                ),
                              ),
                              child: Text(tr("Open terminal")),
                            ),
                          ),
                          if (!state.hasControl) ...[
                            const SizedBox(height: 10),
                            Text(
                              tr("Take control of the session to open one."),
                              textAlign: TextAlign.center,
                              style: webText(
                                context,
                                size: 13,
                                color: 'text.muted',
                              ).copyWith(height: 1.5),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              )
            else
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    for (final (index, terminal) in state.terminals.indexed)
                      Offstage(
                        key: ValueKey('${state.epoch}:${terminal['id']}'),
                        offstage: terminal['id'] != state.current,
                        child: ExcludeFocus(
                          excluding: !active || terminal['id'] != state.current,
                          child: NativeTerminalView(
                            key: ValueKey('${state.epoch}:${terminal['id']}'),
                            controller: widget.controller,
                            info: terminal,
                            tabLabel: '${terminal['title']} ${index + 1}',
                            touch: touch,
                            visible: active && terminal['id'] == state.current,
                            onExit: (code) =>
                                state.exited('${terminal['id']}', code),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Minimal, throwaway rendering of one terminal request and its allowed
/// actions; the new design replaces it.
class TerminalRequestNotice extends StatelessWidget {
  const TerminalRequestNotice({
    super.key,
    required this.state,
    required this.entry,
  });
  final TerminalPaneState state;
  final TerminalRequestEntry entry;
  @override
  Widget build(BuildContext context) {
    final p = palette(context);
    final review = entry.status == TerminalRequestStatus.review
        ? entry.result?.review
        : null;
    final actions = state.requests?.actions(entry) ?? const {};
    final small = webText(
      context,
      size: 12.5,
      color: 'text.secondary',
    ).copyWith(height: 1.45);
    return Container(
      key: ValueKey('terminal-request-${entry.requestId}'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: p['web.line']),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(terminalRequestMessage(entry), style: small),
          if (review != null) ...[
            Text(tr("Shell: {0}", [review.shell]), style: small),
            Text(tr("Directory: {0}", [review.cwd]), style: small),
            Text(
              tr("Size: {0}×{1}", [review.cols ?? '—', review.rows ?? '—']),
              style: small,
            ),
            // Verbatim from the Node: never translated or shortened.
            Text(
              review.warning,
              style: webText(context, size: 12.5, color: 'status.danger'),
            ),
          ],
          Wrap(
            spacing: 4,
            children: [
              for (final action in TerminalRequestAction.values)
                if (actions.contains(action))
                  TextButton(
                    onPressed: () => state.perform(entry, action),
                    child: Text(terminalRequestActionLabel(action, entry.kind)),
                  ),
            ],
          ),
        ],
      ),
    );
  }
}

class NativeTerminalView extends StatefulWidget {
  const NativeTerminalView({
    super.key,
    required this.controller,
    required this.info,
    required this.tabLabel,
    required this.visible,
    required this.onExit,
    this.touch,
  });
  final bool? touch;
  final LiveController controller;
  final Json info;
  final String tabLabel;
  final bool visible;
  final void Function(int?) onExit;
  @override
  State<NativeTerminalView> createState() => _NativeTerminalViewState();
}

class _NativeTerminalViewState extends State<NativeTerminalView>
    with WidgetsBindingObserver {
  late final session = NativeTerminalSession(
    widget.controller,
    widget.info,
    onExit: (code) => widget.onExit(code),
  );
  final focus = FocusNode();
  double _fontSize = 12.5, _pinchStartSize = 12.5;

  void _setFontSize(double value) {
    final next = value.clamp(8.0, 32.0);
    if ((next - _fontSize).abs() < .1) return;
    setState(() {
      _fontSize = next;
      _cachedStyle = null;
    });
  }

  KeyEventResult _zoomKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (!HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (const [
      LogicalKeyboardKey.equal,
      LogicalKeyboardKey.add,
      LogicalKeyboardKey.numpadAdd,
    ].contains(key)) {
      _setFontSize(_fontSize + 1);
    } else if (const [
      LogicalKeyboardKey.minus,
      LogicalKeyboardKey.numpadSubtract,
    ].contains(key)) {
      _setFontSize(_fontSize - 1);
    } else if (key == LogicalKeyboardKey.digit0) {
      _setFontSize(12.5);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Widget? _cachedKeys;
  Object? _keysStamp;

  Widget _terminalKeys(bool compact) {
    final terminal = session.terminal;
    final enabled =
        widget.visible &&
        session.foreground &&
        session.ready &&
        !session.exited &&
        widget.controller.control['held'] == true &&
        widget.controller.control['generation'] != null;
    final stamp = (
      terminal,
      enabled,
      compact,
      terminal.controlArmed,
      terminal.altArmed,
    );
    if (_cachedKeys == null || stamp != _keysStamp) {
      _keysStamp = stamp;
      _cachedKeys = NativeTerminalKeys(
        terminal: terminal,
        enabled: enabled,
        compact: compact,
        focusNode: focus,
      );
    }
    return _cachedKeys!;
  }

  TerminalStyle? _cachedStyle;
  TextScaler? _metricsScaler;
  double? _metricsDpr;
  Map<String, Color>? _themeColors;
  TerminalTheme? _cachedTerminalTheme;

  void _fontsChanged() {
    if (mounted) setState(() => _cachedStyle = null);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PaintingBinding.instance.systemFonts.addListener(_fontsChanged);
    session.setVisible(widget.visible);
    if (widget.visible) requestFocus();
  }

  void requestFocus() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted &&
        widget.visible &&
        FocusManager.instance.primaryFocus?.debugLabel != 'terminal-tab') {
      focus.requestFocus();
    }
  });
  @override
  void didUpdateWidget(covariant NativeTerminalView old) {
    super.didUpdateWidget(old);
    session.setVisible(widget.visible);
    if (widget.visible && !old.visible) requestFocus();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      session.setForeground(state == AppLifecycleState.resumed);
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PaintingBinding.instance.systemFonts.removeListener(_fontsChanged);
    session.dispose();
    focus.dispose();
    super.dispose();
  }

  TerminalStyle _terminalTextStyle(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    if (_cachedStyle != null &&
        scaler == _metricsScaler &&
        dpr == _metricsDpr) {
      return _cachedStyle!;
    }
    // Keep xterm's glyph cache across keyboard metrics and unrelated chat ticks.
    // xterm 4 compares these style/theme objects by identity before invalidating.
    final metrics = TextPainter(
      text: TextSpan(
        text: 'W',
        style: TextStyle(fontFamily: 'monospace', fontSize: _fontSize),
      ),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final lineHeight =
        ((metrics.height * dpr).ceil() * 1.15).floor() /
        dpr /
        scaler.scale(_fontSize);
    metrics.dispose();
    _metricsScaler = scaler;
    _metricsDpr = dpr;
    return _cachedStyle = TerminalStyle(
      fontSize: _fontSize,
      height: lineHeight,
    );
  }

  TerminalTheme _terminalColors(BuildContext context) {
    final p = palette(context);
    if (_cachedTerminalTheme != null && mapEquals(_themeColors, p.values)) {
      return _cachedTerminalTheme!;
    }
    _themeColors = Map.of(p.values);
    return _cachedTerminalTheme = TerminalTheme(
      cursor: p['accent.default'],
      selection: p['accent.soft'],
      foreground: p['code.text'],
      background: p['code.bg'],
      black: const Color(0xff2e3436),
      red: const Color(0xffcc0000),
      green: const Color(0xff4e9a06),
      yellow: const Color(0xffc4a000),
      blue: const Color(0xff3465a4),
      magenta: const Color(0xff75507b),
      cyan: const Color(0xff06989a),
      white: const Color(0xffd3d7cf),
      brightBlack: const Color(0xff555753),
      brightRed: const Color(0xffef2929),
      brightGreen: const Color(0xff8ae234),
      brightYellow: const Color(0xfffce94f),
      brightBlue: const Color(0xff729fcf),
      brightMagenta: const Color(0xffad7fa8),
      brightCyan: const Color(0xff34e2e2),
      brightWhite: const Color(0xffeeeeec),
      searchHitBackground: p['accent.soft'],
      searchHitBackgroundCurrent: p['accent.soft'],
      searchHitForeground: p['code.text'],
    );
  }

  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    return AnimatedBuilder(
      animation: session,
      builder: (context, _) {
        final p = palette(context);
        final style = _terminalTextStyle(context);
        final terminalTheme = _terminalColors(context);
        return Semantics(
          role: SemanticsRole.tabPanel,
          label: widget.tabLabel,
          child: Container(
            color: p['code.bg'],
            padding: const EdgeInsets.fromLTRB(8, 6, 4, 4),
            child: LayoutBuilder(
              builder: (context, bounds) => Column(
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: ListenableBuilder(
                            listenable: focus,
                            builder: (context, _) => Semantics(
                              label: tr("Terminal input"),
                              textField: true,
                              enabled: true,
                              focusable: true,
                              focused: focus.hasFocus,
                              onTap: () {
                                if (widget.visible) focus.requestFocus();
                              },
                              child: GestureDetector(
                                key: const ValueKey('terminal-zoom-surface'),
                                onScaleStart: (_) =>
                                    _pinchStartSize = _fontSize,
                                onScaleUpdate: (details) {
                                  if (details.pointerCount >= 2) {
                                    _setFontSize(
                                      _pinchStartSize * details.scale,
                                    );
                                  }
                                },
                                child: TerminalView(
                                  // Preserve CustomTextEdit's IME connection
                                  // while RenderTerminal swaps in a PTY replay.
                                  session.terminal,
                                  focusNode: focus,
                                  onKeyEvent: _zoomKey,
                                  autoResize: widget.visible,
                                  padding: EdgeInsets.zero,
                                  textStyle: style,
                                  textScaler: MediaQuery.textScalerOf(context),
                                  keyboardAppearance: Theme.of(
                                    context,
                                  ).brightness,
                                  theme: terminalTheme,
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (session.notice.isNotEmpty)
                          Positioned(
                            right: 8,
                            bottom: 6,
                            child: Container(
                              constraints: BoxConstraints(
                                maxWidth: MediaQuery.sizeOf(context).width - 48,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: p['web.bg-layer'],
                                borderRadius: BorderRadius.circular(999),
                                boxShadow: pircShadow(context, card: true),
                              ),
                              child: Text(
                                session.notice,
                                style: webText(
                                  context,
                                  size: 12,
                                  color: 'text.secondary',
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (bounds.maxHeight >= 64 &&
                      (widget.touch ??
                          [
                            TargetPlatform.android,
                            TargetPlatform.iOS,
                          ].contains(defaultTargetPlatform)))
                    _terminalKeys(bounds.maxHeight < 180),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
