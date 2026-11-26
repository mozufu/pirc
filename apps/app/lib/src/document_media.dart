import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_render/pirc_render.dart';
// ignore: implementation_imports
import 'package:pirc_render/src/html_media_spec.dart';

import '../l10n/app_localizations.dart';
import 'platform/media.dart';
import 'work/panels/recording_player.dart' show playbackTime;

/// Fetches the bytes of a remote media URL without credentials (the scripts
/// channel); answers `(bytes, mimeType)`. [requestId] can cancel it.
typedef MessageMediaFetch =
    Future<(Uint8List, String)> Function(Uri url, String requestId);

/// The [RenderMediaBuilder] for `<audio>` and `<video>` in messages and tool
/// results (Android). Nothing loads until the user taps the element: a
/// remote file is then fetched without credentials and played with
/// [players]. Media inside a fetched document (with a document scope) is
/// left to that document.
RenderMediaBuilder messageMediaBuilder({
  required MediaPlayers players,
  required MessageMediaFetch fetch,
  required Future<void> Function(String requestId) cancel,
}) =>
    (
      RenderDocumentScope? scope,
      NativeHtmlMediaSpec spec,
      Map<String, String> styles, {
      String? baseUrl,
      Object? accountIdentity,
    }) => scope != null
    ? null
    : MessageMedia(spec: spec, players: players, fetch: fetch, cancel: cancel);

/// One `<audio>` or `<video>` of a message: a placeholder until it is
/// tapped, then a player.
class MessageMedia extends StatefulWidget {
  const MessageMedia({
    super.key,
    required this.spec,
    required this.players,
    required this.fetch,
    required this.cancel,
  });

  final NativeHtmlMediaSpec spec;
  final MediaPlayers players;
  final MessageMediaFetch fetch;
  final Future<void> Function(String requestId) cancel;

  @override
  State<MessageMedia> createState() => _MessageMediaState();
}

enum _Phase { waiting, loading, ready, failed, unsupported }

class _MessageMediaState extends State<MessageMedia> {
  static var _requests = 0;
  var _phase = _Phase.waiting;
  MediaStatus? _status;
  String? _request;
  bool _disposed = false;

  /// The first candidate that can be loaded: `data:` (already here) or an
  /// absolute `http(s)` URL. Relative URLs have no base in a message.
  (Uri, String?)? get _candidate {
    for (final candidate in widget.spec.candidates) {
      final uri = Uri.tryParse(candidate.url.trim());
      if (uri == null) continue;
      if (uri.scheme == 'data' ||
          uri.isAbsolute && const {'http', 'https'}.contains(uri.scheme)) {
        return (uri, candidate.typeHint);
      }
    }
    return null;
  }

  Uri? get _source => _candidate?.$1;

  @override
  void initState() {
    super.initState();
    if (_source == null) _phase = _Phase.unsupported;
  }

  Future<void> _load() async {
    final source = _source;
    if (source == null || _phase == _Phase.loading) return;
    setState(() => _phase = _Phase.loading);
    final request = _request = 'message-media-${++_requests}';
    try {
      final (bytes, type) = source.scheme == 'data'
          ? (source.data!.contentAsBytes(), source.data!.mimeType)
          : await widget.fetch(source, request);
      if (_disposed) return;
      // A server may answer a generic type; the `<source type>` then says.
      final hint = _candidate?.$2;
      final mimeType = MediaPlayers.playable(type) ? type : (hint ?? type);
      if (!MediaPlayers.playable(mimeType) ||
          bytes.length > MediaPlayers.maxBytes) {
        setState(() => _phase = _Phase.unsupported);
        return;
      }
      var status = await widget.players.open(
        bytes,
        mimeType: mimeType,
        kind: widget.spec.kind.name,
        muted: widget.spec.muted,
        loop: widget.spec.loop,
      );
      if (_disposed) {
        unawaited(widget.players.close(status.id));
        return;
      }
      status = await widget.players.play(status.id);
      if (_disposed) return;
      setState(() {
        _status = status;
        _phase = _Phase.ready;
      });
    } on Object catch (error) {
      if (_disposed) return;
      setState(
        () => _phase = error is FormatException
            ? _Phase.unsupported
            : _Phase.failed,
      );
    } finally {
      _request = null;
    }
  }

  Future<void> _toggle() async {
    final status = _status;
    if (status == null) return;
    try {
      final next = status.playing
          ? await widget.players.pause(status.id)
          : await widget.players.play(status.id);
      if (!_disposed) setState(() => _status = next);
    } on PlatformException {
      if (!_disposed) setState(() => _phase = _Phase.failed);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final request = _request;
    if (request != null) unawaited(widget.cancel(request));
    final status = _status;
    if (status != null) unawaited(widget.players.close(status.id));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final status = _status;
    if (_phase == _Phase.ready && status != null) {
      final controls = Row(
        children: [
          IconButton(
            key: const Key('message-media-play'),
            tooltip: status.playing ? l10n.recordingPause : l10n.recordingPlay,
            icon: Icon(
              status.playing ? LucideIcons.pause : LucideIcons.play,
              size: 18,
            ),
            onPressed: _toggle,
          ),
          Text(
            playbackTime(status.duration),
            style: theme.textTheme.labelSmall,
          ),
        ],
      );
      if (widget.spec.kind == NativeHtmlMediaKind.audio) return controls;
      final ratio = status.width > 0 && status.height > 0
          ? status.width / status.height
          : 16 / 9;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: ratio,
            child: ColoredBox(
              color: Colors.black,
              child: Texture(textureId: status.id),
            ),
          ),
          controls,
        ],
      );
    }
    final source = _source;
    final label = switch (_phase) {
      _Phase.failed => l10n.messageMediaFailed,
      _Phase.unsupported => l10n.messageMediaUnsupported,
      _ => l10n.messageMediaTap,
    };
    final host = source != null && source.scheme != 'data' ? source.host : null;
    return Semantics(
      button: _phase == _Phase.waiting || _phase == _Phase.failed,
      child: InkWell(
        key: const Key('message-media-load'),
        onTap: _phase == _Phase.waiting || _phase == _Phase.failed
            ? _load
            : null,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: theme.dividerColor),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              if (_phase == _Phase.loading)
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  widget.spec.kind == NativeHtmlMediaKind.video
                      ? LucideIcons.video
                      : LucideIcons.music,
                  size: 18,
                ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: theme.textTheme.bodyMedium),
                    if (host != null && host.isNotEmpty)
                      Text(
                        l10n.messageMediaFrom(host),
                        style: theme.textTheme.labelSmall,
                      ),
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
