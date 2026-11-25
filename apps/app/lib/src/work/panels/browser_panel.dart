import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:share_plus/share_plus.dart';

import '../../../l10n/app_localizations.dart';
import '../../connection/connection.dart';
import '../../connection/data.dart';
import 'panel_common.dart';

/// `Saved recording <path>` browser log entries name a recording file.
final _recordingLog = RegExp(
  r'^Saved recording (\.pirc/recordings/\S+\.webm)$',
);

/// The recordings named by browser log [entries], oldest first, each once.
List<String> recordingsIn(Iterable<Object?> entries) => [
  ...{
    for (final entry in entries)
      if (entry is Map)
        ?_recordingLog.firstMatch('${entry['action'] ?? ''}')?.group(1),
  },
];

/// 10d. Browser: the `…/browser/stream` socket (screencast frames and
/// state), taking and returning control, and recording. Every message but
/// `log_image` carries the control lease.
class BrowserPanel extends ConsumerStatefulWidget {
  const BrowserPanel({super.key, required this.sessionId});
  final String sessionId;

  @override
  ConsumerState<BrowserPanel> createState() => _BrowserPanelState();
}

class _BrowserPanelState extends ConsumerState<BrowserPanel> {
  EventSocket? _socket;
  StreamSubscription<Object?>? _frames;
  Map? _state;
  List<String> _recordings = const [];
  Uint8List? _frame;
  Size _frameSize = const Size(1280, 800);
  String? _error;
  bool _closed = false;
  bool _connecting = true;
  final _url = TextEditingController();
  final _text = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(_connect());
  }

  Future<void> _connect() async {
    final transport = ref.read(connectionProvider).connection?.transport;
    if (transport == null) return;
    try {
      final socket = await transport.connectEvents(
        Uri(path: sessionPath(widget.sessionId, 'browser/stream')),
      );
      if (!mounted) {
        unawaited(socket.close());
        return;
      }
      _socket = socket;
      _frames = socket.messages.listen(
        _onFrame,
        onDone: () {
          if (mounted) setState(() => _closed = true);
        },
      );
    } on PircException catch (error) {
      if (mounted && ref.read(connectionProvider.notifier).report(error)) {
        return;
      }
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  void _onFrame(Object? frame) {
    if (frame is! Map) return;
    switch (frame['type']) {
      case 'state':
        setState(() => _state = frame['state'] as Map?);
        final url = '${_state?['url'] ?? ''}';
        if (_url.text != url) _url.text = url;
      case 'frame':
        setState(() {
          _frame = base64Decode('${frame['data']}');
          _frameSize = Size(
            (frame['width'] as num?)?.toDouble() ?? 1280,
            (frame['height'] as num?)?.toDouble() ?? 800,
          );
        });
      case 'log':
        setState(
          () =>
              _recordings = recordingsIn(frame['entries'] as List? ?? const []),
        );
      case 'log_entry':
        final more = recordingsIn([frame['entry']]);
        if (more.isNotEmpty) {
          setState(() => _recordings = {..._recordings, ...more}.toList());
        }
      case 'error':
        setState(() => _error = '${frame['message'] ?? ''}');
    }
  }

  void _send(Map<String, Object?> message) {
    final body = leaseBody(ref, widget.sessionId);
    if (body == null) return;
    _socket?.send({...message, ...body});
  }

  @override
  void dispose() {
    unawaited(_frames?.cancel());
    unawaited(_socket?.close(1000, 'Closed'));
    _url.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final control = canControl(ref, widget.sessionId);
    final state = _state;
    final mine = state?['mode'] == 'user';
    final recording = state?['recording'] is Map;
    if (_connecting) return const Center(child: CircularProgressIndicator());
    if (state == null) {
      return PanelNote(
        text: _error ?? (_closed ? l10n.browserUnavailable : l10n.browserEmpty),
        icon: LucideIcons.globe,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!control) ReadOnlyNote(sessionId: widget.sessionId),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('browser-url'),
                  controller: _url,
                  enabled: control && mine,
                  decoration: const InputDecoration(isDense: true),
                  onSubmitted: (url) => _send({'type': 'navigate', 'url': url}),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                key: const Key('browser-control'),
                onPressed: control
                    ? () => _send({'type': mine ? 'release' : 'takeover'})
                    : null,
                child: Text(mine ? l10n.browserReturn : l10n.browserTake),
              ),
              IconButton(
                tooltip: recording
                    ? l10n.browserStopRecording
                    : l10n.browserRecord,
                onPressed: control
                    ? () => _send({
                        'type': 'record',
                        'action': recording ? 'stop' : 'start',
                      })
                    : null,
                icon: Icon(
                  recording ? LucideIcons.squareStop : LucideIcons.circleDot,
                ),
              ),
            ],
          ),
        ),
        if (state['agentWaiting'] == true || state['action'] != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              '${state['action'] ?? l10n.browserAgentWaiting}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(_error!, style: Theme.of(context).textTheme.bodySmall),
          ),
        if (_recordings.isNotEmpty)
          _Recordings(sessionId: widget.sessionId, paths: _recordings),
        Expanded(
          child: _frame == null
              ? PanelNote(text: l10n.browserNoFrame, icon: LucideIcons.globe)
              : LayoutBuilder(
                  builder: (context, box) {
                    // Map a tap on the scaled frame to page coordinates.
                    final scale = (box.maxWidth / _frameSize.width).clamp(
                      0.0,
                      box.maxHeight / _frameSize.height,
                    );
                    return GestureDetector(
                      onTapUp: control && mine
                          ? (details) {
                              final x = details.localPosition.dx / scale;
                              final y = details.localPosition.dy / scale;
                              for (final action in ['down', 'up']) {
                                _send({
                                  'type': 'mouse',
                                  'action': action,
                                  'x': x,
                                  'y': y,
                                  'button': 'left',
                                  'clickCount': 1,
                                });
                              }
                            }
                          : null,
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: Image.memory(
                          _frame!,
                          width: _frameSize.width * scale,
                          height: _frameSize.height * scale,
                          gaplessPlayback: true,
                        ),
                      ),
                    );
                  },
                ),
        ),
        if (control && mine)
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              key: const Key('browser-text'),
              controller: _text,
              decoration: InputDecoration(
                isDense: true,
                hintText: l10n.browserType,
              ),
              onSubmitted: (text) {
                _send({'type': 'text', 'text': text});
                _send({'type': 'key', 'key': 'Enter'});
                _text.clear();
              },
            ),
          ),
      ],
    );
  }
}

/// The saved recordings (`GET …/browser/recording?path=`). A recording is
/// WebM, which not every platform can play in the app, so a loaded one is
/// handed to another app (or saved) through the share sheet. Reading needs
/// no control lease.
class _Recordings extends ConsumerStatefulWidget {
  const _Recordings({required this.sessionId, required this.paths});

  final String sessionId;
  final List<String> paths;

  @override
  ConsumerState<_Recordings> createState() => _RecordingsState();
}

class _RecordingsState extends ConsumerState<_Recordings> {
  final _loaded = <String, Uint8List>{};
  final _loading = <String>{};
  final _failed = <String>{};

  Future<void> _load(String path) async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    setState(() {
      _loading.add(path);
      _failed.remove(path);
    });
    try {
      final reply = checked(
        await api.send(
          ApiRequest.get(
            sessionPath(widget.sessionId, 'browser/recording'),
            query: {'path': path},
          ),
          timeout: const Duration(minutes: 3),
        ),
      );
      if (mounted) {
        setState(() => _loaded[path] = Uint8List.fromList(reply.body));
      }
    } on PircException {
      if (mounted) setState(() => _failed.add(path));
    } finally {
      if (mounted) setState(() => _loading.remove(path));
    }
  }

  void _open(String path, Uint8List bytes) => SharePlus.instance.share(
    ShareParams(
      files: [
        XFile.fromData(
          bytes,
          mimeType: 'video/webm',
          name: path.split('/').last,
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Text(l10n.browserRecordings, style: text.labelMedium),
        ),
        for (final path in widget.paths.reversed)
          ListTile(
            key: ValueKey('recording:$path'),
            dense: true,
            leading: const Icon(LucideIcons.video, size: 18),
            title: Text(path.split('/').last),
            subtitle: _failed.contains(path)
                ? Text(l10n.browserRecordingFailed)
                : _loaded[path] == null
                ? null
                : Text(
                    l10n.browserRecordingSize(
                      (_loaded[path]!.length / (1024 * 1024)).toStringAsFixed(
                        1,
                      ),
                    ),
                  ),
            trailing: _loading.contains(path)
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : _loaded[path] == null
                ? TextButton(
                    onPressed: () => _load(path),
                    child: Text(l10n.browserRecordingLoad),
                  )
                : IconButton(
                    tooltip: l10n.browserRecordingOpen,
                    icon: const Icon(LucideIcons.share2, size: 18),
                    onPressed: () => _open(path, _loaded[path]!),
                  ),
          ),
      ],
    );
  }
}
