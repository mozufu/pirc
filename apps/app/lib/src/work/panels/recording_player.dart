import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../l10n/app_localizations.dart';
import '../../platform/media.dart';

/// The playback speeds offered, as in the old app.
const recordingRates = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

/// `1:05`, or `1:02:05` from an hour on.
String playbackTime(Duration value) {
  final seconds = value.inSeconds % 60, minutes = value.inMinutes % 60;
  final two = seconds.toString().padLeft(2, '0');
  return value.inHours > 0
      ? '${value.inHours}:${minutes.toString().padLeft(2, '0')}:$two'
      : '${value.inMinutes}:$two';
}

/// `1×`, `0.75×`.
String rateLabel(double rate) =>
    '${rate == rate.roundToDouble() ? rate.toInt() : rate}×';

/// A browser recording (WebM) played in the app on Android: the video in a
/// Flutter texture, play and pause, a seek bar when the file states its
/// length, the playback speed and saving to Downloads. [bytes] were read
/// from the Gateway's recording route; the player makes no request.
class RecordingPlayer extends StatefulWidget {
  const RecordingPlayer({
    super.key,
    required this.media,
    required this.path,
    required this.bytes,
    this.onClose,
  });

  final MediaPlayers media;
  final String path;
  final Uint8List bytes;
  final VoidCallback? onClose;

  @override
  State<RecordingPlayer> createState() => _RecordingPlayerState();
}

class _RecordingPlayerState extends State<RecordingPlayer> {
  MediaStatus? _status;
  bool _failed = false, _saving = false, _disposed = false;
  String? _notice;

  /// The position under the finger while the seek bar is dragged.
  double? _dragging;
  Timer? _poll;
  int _revision = 0;

  String get _name => widget.path.split('/').last;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final status = await widget.media.openRecording(
        widget.bytes,
        cancelled: () => _disposed,
      );
      if (_disposed) {
        unawaited(_close(status.id));
        return;
      }
      setState(() => _status = status);
    } on Exception {
      if (!_disposed) setState(() => _failed = true);
    }
  }

  Future<void> _close(int id) async {
    try {
      await widget.media.close(id);
    } on Exception {
      // Already closed.
    }
  }

  /// The player is gone (decoder error, seek timeout, unpairing): stop
  /// reading its status.
  void _fail() {
    _poll?.cancel();
    _poll = null;
    if (!_disposed) setState(() => _failed = true);
  }

  /// User commands in flight; a status read never overwrites their answer.
  int _pending = 0;

  /// Runs a user [action] on the player; a newer command's answer wins.
  Future<void> _command(Future<MediaStatus> Function(int id) action) async {
    final id = _status?.id;
    if (id == null || _failed) return;
    final revision = ++_revision;
    _pending++;
    try {
      final status = await action(id);
      if (_disposed || revision != _revision) return;
      setState(() => _status = status);
    } on PlatformException catch (error) {
      if (_disposed) return;
      // `BACKGROUND`: Android paused it; the next status read shows that.
      if (error.code != MediaError.background) _fail();
    } on Exception {
      _fail();
    } finally {
      _pending--;
      _watch();
    }
  }

  /// One status read while playing. It counts as no command: it does not
  /// replace the answer of a command sent meanwhile.
  Future<void> _read() async {
    final id = _status?.id;
    if (id == null || _failed || _pending > 0 || _dragging != null) return;
    final revision = _revision;
    try {
      final status = await widget.media.status(id);
      if (_disposed || revision != _revision || _pending > 0) return;
      setState(() => _status = status);
    } on PlatformException catch (error) {
      if (error.code == MediaError.closed || error.code == MediaError.media) {
        _fail();
      }
    } on Exception {
      _fail();
    } finally {
      _watch();
    }
  }

  /// Reads the position while playing, as the old app did every 250 ms.
  void _watch() {
    final playing = !_disposed && !_failed && _status?.playing == true;
    if (playing && _poll == null) {
      _poll = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => unawaited(_read()),
      );
    } else if (!playing) {
      _poll?.cancel();
      _poll = null;
    }
  }

  Future<void> _save(AppLocalizations l10n) async {
    final id = _status?.id;
    if (id == null || _saving) return;
    setState(() {
      _saving = true;
      _notice = null;
    });
    try {
      final saved = await widget.media.save(id, _name);
      if (!_disposed) setState(() => _notice = l10n.recordingSaved(saved));
    } on Exception {
      if (!_disposed) setState(() => _notice = l10n.recordingSaveFailed);
    } finally {
      if (!_disposed) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    final id = _status?.id;
    if (id != null) unawaited(_close(id));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final status = _status;
    if (_failed || status == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: _failed
            ? Text(l10n.recordingPlaybackFailed, style: text.bodySmall)
            : const Center(
                child: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
      );
    }
    final ratio = status.width > 0 && status.height > 0
        ? status.width / status.height
        : 16 / 9;
    final duration = status.duration;
    // A WebM file written while recording may not state its length: no
    // seek bar then, only the position.
    final seekable = duration > Duration.zero;
    final position = status.position > duration && seekable
        ? duration
        : status.position;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: AspectRatio(
                aspectRatio: ratio,
                child: ColoredBox(
                  color: Colors.black,
                  child: Texture(textureId: status.id),
                ),
              ),
            ),
          ),
          Row(
            children: [
              IconButton(
                key: const Key('recording-play'),
                tooltip: status.playing
                    ? l10n.recordingPause
                    : l10n.recordingPlay,
                icon: Icon(
                  status.playing ? LucideIcons.pause : LucideIcons.play,
                  size: 18,
                ),
                onPressed: () => _command(
                  status.playing ? widget.media.pause : widget.media.play,
                ),
              ),
              Text(
                seekable
                    ? '${playbackTime(position)} / ${playbackTime(duration)}'
                    : playbackTime(position),
                style: text.labelSmall,
              ),
              Expanded(
                child: seekable
                    ? Slider(
                        key: const Key('recording-seek'),
                        semanticFormatterCallback: (value) =>
                            l10n.recordingPosition(
                              playbackTime(
                                Duration(milliseconds: value.round()),
                              ),
                              playbackTime(duration),
                            ),
                        max: duration.inMilliseconds.toDouble(),
                        value:
                            _dragging ??
                            position.inMilliseconds.toDouble().clamp(
                              0,
                              duration.inMilliseconds.toDouble(),
                            ),
                        onChanged: (value) => setState(() => _dragging = value),
                        onChangeEnd: (value) {
                          setState(() => _dragging = null);
                          unawaited(
                            _command(
                              (id) => widget.media.seek(
                                id,
                                Duration(milliseconds: value.round()),
                              ),
                            ),
                          );
                        },
                      )
                    : const SizedBox.shrink(),
              ),
              PopupMenuButton<double>(
                key: const Key('recording-speed'),
                tooltip: l10n.recordingSpeed,
                initialValue: status.rate,
                onSelected: (rate) =>
                    _command((id) => widget.media.setRate(id, rate)),
                itemBuilder: (context) => [
                  for (final rate in recordingRates)
                    PopupMenuItem(value: rate, child: Text(rateLabel(rate))),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(rateLabel(status.rate), style: text.labelSmall),
                ),
              ),
              IconButton(
                key: const Key('recording-save'),
                tooltip: l10n.recordingSave,
                icon: const Icon(LucideIcons.download, size: 18),
                onPressed: _saving ? null : () => _save(l10n),
              ),
              if (widget.onClose != null)
                IconButton(
                  tooltip: l10n.recordingClose,
                  icon: const Icon(LucideIcons.x, size: 18),
                  onPressed: widget.onClose,
                ),
            ],
          ),
          if (_notice != null) Text(_notice!, style: text.bodySmall),
        ],
      ),
    );
  }
}
