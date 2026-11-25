import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';
import 'package:xterm/xterm.dart';

import '../../../l10n/app_localizations.dart';
import '../../connection/connection.dart';
import '../../connection/data.dart';
import '../session_controller.dart';
import 'panel_common.dart';

/// How long to wait between reads of a terminal still being prepared.
final terminalPollProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 1),
);

/// 10b. Terminals: the list (`GET|POST …/terminals`, `…/close`) and the
/// full-screen terminal on the stream socket. Create, type, resize and
/// close need the control lease; without it the screen is read-only.
class TerminalsPanel extends ConsumerStatefulWidget {
  const TerminalsPanel({super.key, required this.sessionId});
  final String sessionId;

  @override
  ConsumerState<TerminalsPanel> createState() => _TerminalsPanelState();
}

class _TerminalsPanelState extends ConsumerState<TerminalsPanel> {
  bool _creating = false;

  PanelKey get _key =>
      panelKey(widget.sessionId, 'terminals', sections: const [anyPanelChange]);

  Future<void> _create() async {
    final body = leaseBody(ref, widget.sessionId);
    final api = ref.read(apiProvider);
    if (body == null || api == null) return;
    setState(() => _creating = true);
    final requestId = randomId();
    final path = sessionPath(widget.sessionId, 'terminals');
    try {
      var reply = await api.post(path, {
        ...body,
        'executionPath': 'isolated_work',
        'requestId': requestId,
        'cols': 80,
        'rows': 24,
      });
      // 202 while the work environment is prepared: read until it is ready.
      for (var i = 0; i < 60 && (reply as Map?)?['terminal'] == null; i++) {
        final request = reply is Map ? reply['workRequest'] : null;
        final state = request is Map ? request['state'] : null;
        if (state == 'not_started' || state == 'outcome_unknown') break;
        await Future<void>.delayed(ref.read(terminalPollProvider));
        if (!mounted) return;
        reply = await api.get(path, query: {'workRequestId': requestId});
      }
      ref.invalidate(panelReadProvider(_key));
      final terminal = (reply as Map?)?['terminal'];
      if (terminal is Map && mounted) _open(terminal);
    } on PircException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context).actionFailed(error.message),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  void _open(Map terminal) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => TerminalPage(
        sessionId: widget.sessionId,
        terminalId: '${terminal['id']}',
        title: '${terminal['title'] ?? ''}',
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final control = canControl(ref, widget.sessionId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!control) ReadOnlyNote(sessionId: widget.sessionId),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: control && !_creating ? _create : null,
              icon: const Icon(LucideIcons.plus, size: 16),
              label: Text(_creating ? l10n.terminalStarting : l10n.terminalNew),
            ),
          ),
        ),
        Expanded(
          child: PanelBody<Object?>(
            value: ref.watch(panelReadProvider(_key)),
            onRetry: () => ref.invalidate(panelReadProvider(_key)),
            emptyText: l10n.terminalsEmpty,
            isEmpty: (d) =>
                ((d as Map?)?['terminals'] as List?)?.isEmpty ?? true,
            builder: (d) => ListView(
              children: [
                for (final t in ((d! as Map)['terminals'] as List).cast<Map>())
                  ListTile(
                    leading: const Icon(LucideIcons.squareTerminal, size: 18),
                    title: Text('${t['title']}'),
                    subtitle: Text(
                      t['exited'] == true
                          ? l10n.terminalExited('${t['exitCode'] ?? '?'}')
                          : '${t['cwd']}',
                    ),
                    onTap: () => _open(t),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The full-screen terminal: always dark, with the extra key row. Watching
/// needs no lease; typing and resizing carry it in every message.
class TerminalPage extends ConsumerStatefulWidget {
  const TerminalPage({
    super.key,
    required this.sessionId,
    required this.terminalId,
    required this.title,
  });

  final String sessionId;
  final String terminalId;
  final String title;

  @override
  ConsumerState<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends ConsumerState<TerminalPage> {
  final terminal = Terminal(maxLines: 5000);
  EventSocket? _socket;
  StreamSubscription<Object?>? _frames;
  int? _exitCode;
  bool _exited = false;
  String? _error;
  bool _ctrl = false;

  @override
  void initState() {
    super.initState();
    terminal.onOutput = _input;
    terminal.onResize = (cols, rows, _, _) =>
        _send({'type': 'resize', 'cols': cols, 'rows': rows});
    unawaited(_connect());
  }

  Future<void> _connect() async {
    final transport = ref.read(connectionProvider).connection?.transport;
    if (transport == null) return;
    try {
      final socket = await transport.connectEvents(
        Uri(
          path: sessionPath(
            widget.sessionId,
            'terminals/${Uri.encodeComponent(widget.terminalId)}/stream',
          ),
        ),
      );
      if (!mounted) {
        unawaited(socket.close());
        return;
      }
      _socket = socket;
      _frames = socket.messages.listen(_onFrame);
    } on PircException catch (error) {
      if (mounted && ref.read(connectionProvider.notifier).report(error)) {
        return;
      }
      if (mounted) setState(() => _error = error.message);
    }
  }

  void _onFrame(Object? frame) {
    if (frame is! Map) return;
    switch (frame['type']) {
      case 'ready':
        terminal.write('${frame['replay'] ?? ''}');
      case 'output':
        terminal.write('${frame['data'] ?? ''}');
      case 'exit':
        setState(() {
          _exited = true;
          _exitCode = (frame['exitCode'] as num?)?.toInt();
        });
      case 'error':
        setState(() => _error = '${frame['message'] ?? ''}');
    }
  }

  void _send(Map<String, Object?> message) {
    final body = leaseBody(ref, widget.sessionId);
    if (body == null || _exited) return;
    _socket?.send({...message, ...body});
  }

  void _input(String data) {
    if (_ctrl && data.length == 1) {
      final code = data.toLowerCase().codeUnitAt(0);
      if (code >= 97 && code <= 122) data = String.fromCharCode(code - 96);
      setState(() => _ctrl = false);
    }
    _send({'type': 'input', 'data': data});
  }

  Future<void> _close() async {
    final body = leaseBody(ref, widget.sessionId);
    final api = ref.read(apiProvider);
    if (body != null && api != null) {
      try {
        await api.post(
          sessionPath(
            widget.sessionId,
            'terminals/${Uri.encodeComponent(widget.terminalId)}/close',
          ),
          body,
        );
      } on PircException {
        // Closed or gone already.
      }
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    unawaited(_frames?.cancel());
    unawaited(_socket?.close(1000, 'Closed'));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final control =
        ref.watch(sessionControllerProvider(widget.sessionId)).control ==
        ControlState.mine;
    final background = colors['terminal.bg'];
    Widget key(String label, String data) => TextButton(
      style: TextButton.styleFrom(foregroundColor: colors['terminal.text']),
      onPressed: control && !_exited ? () => _input(data) : null,
      child: Text(label),
    );
    return Theme(
      data: PircTheme.of(Brightness.dark),
      child: Scaffold(
        backgroundColor: background,
        appBar: AppBar(
          backgroundColor: background,
          title: Text(widget.title),
          actions: [
            if (!_exited)
              TextButton(
                onPressed: control ? _close : null,
                child: Text(l10n.terminalClose),
              ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              if (!control)
                ListTile(
                  dense: true,
                  title: Text(l10n.terminalReadOnly),
                  trailing: TextButton(
                    onPressed: () => ref
                        .read(
                          sessionControllerProvider(widget.sessionId).notifier,
                        )
                        .takeControl(force: true),
                    child: Text(l10n.takeControl),
                  ),
                ),
              if (_error != null) ListTile(dense: true, title: Text(_error!)),
              Expanded(
                child: TerminalView(
                  terminal,
                  readOnly: !control || _exited,
                  backgroundOpacity: 1,
                  theme: TerminalThemes.defaultTheme,
                ),
              ),
              if (_exited)
                ListTile(
                  title: Text(l10n.terminalExited('${_exitCode ?? '?'}')),
                  trailing: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l10n.close),
                  ),
                )
              else
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      key('Esc', '\x1b'),
                      key('Tab', '\t'),
                      TextButton(
                        onPressed: control
                            ? () => setState(() => _ctrl = !_ctrl)
                            : null,
                        child: Text(_ctrl ? 'Ctrl ●' : 'Ctrl'),
                      ),
                      key('↑', '\x1b[A'),
                      key('↓', '\x1b[B'),
                      key('←', '\x1b[D'),
                      key('→', '\x1b[C'),
                      key('|', '|'),
                      key('~', '~'),
                      key('/', '/'),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
