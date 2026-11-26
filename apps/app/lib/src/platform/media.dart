import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Recording playback and HTML `<audio>`/`<video>` on Android, through the
/// `org.mozufu.pirc/media` channel (plans/roadmap.md M8 step 7). Dart hands
/// over bytes it already holds (a recording read from the Gateway, a
/// document's media); the Kotlin side never fetches a URL. A video is shown
/// with `Texture(textureId: status.id)`.
abstract interface class MediaPlayers {
  /// Opens [bytes] (at most 32 MiB) of type [mimeType], for example
  /// `video/webm`. [kind] is `audio` or `video`.
  Future<MediaStatus> open(
    Uint8List bytes, {
    required String mimeType,
    required String kind,
    bool muted = false,
    bool loop = false,
  });

  /// Opens a browser recording (WebM, at most 1 GiB). The bytes reach
  /// Android in parts of at most [MediaPlayers.partBytes], so a 30-minute
  /// recording is not one huge channel message.
  ///
  /// [cancelled] is asked before each part and before opening; once it
  /// answers true the upload is dropped and this fails with `CLOSED`.
  Future<MediaStatus> openRecording(
    Uint8List bytes, {
    String mimeType = 'video/webm',
    bool Function()? cancelled,
  });
  Future<MediaStatus> status(int id);
  Future<MediaStatus> play(int id);
  Future<MediaStatus> pause(int id);

  /// Answers once the decoder has reached the newest requested position.
  Future<MediaStatus> seek(int id, Duration position);

  /// 0 is muted, 1 is full volume.
  Future<MediaStatus> setVolume(int id, double volume);
  Future<MediaStatus> setRate(int id, double rate);
  Future<MediaStatus> setLoop(int id, bool loop);

  /// Saves the held bytes into Downloads as [name]; returns the saved name.
  Future<String> save(int id, String name);
  Future<void> close(int id);

  /// Closes every player and drops every unfinished upload (unpairing).
  Future<void> closeAll();

  /// The limit of [open]: HTML media.
  static const maxBytes = 32 * 1024 * 1024;

  /// The limit of [openRecording].
  static const maxRecordingBytes = 1024 * 1024 * 1024;

  /// The size of one part of an [openRecording] upload.
  static const partBytes = 8 * 1024 * 1024;

  /// Whether Android can play [mimeType] (`audio/…`, `video/…` or
  /// `application/ogg`, with no wildcard), as the channel checks it.
  static bool playable(String mimeType) {
    final essence = mimeType.split(';').first.trim().toLowerCase();
    return RegExp(
          r"^[!#$%&'+.^_`|~0-9a-z-]+/[!#$%&'+.^_`|~0-9a-z-]+$",
        ).hasMatch(essence) &&
        (essence.startsWith('audio/') ||
            essence.startsWith('video/') ||
            essence == 'application/ogg');
  }
}

/// The media players of this platform: Android only. Elsewhere a recording
/// is handed to another app through the share sheet.
final mediaPlayersProvider = Provider<MediaPlayers?>(
  (ref) => !kIsWeb && defaultTargetPlatform == TargetPlatform.android
      ? const ChannelMediaPlayers()
      : null,
);

/// Error codes of the channel's [PlatformException]s.
abstract final class MediaError {
  static const invalid = 'INVALID';
  static const closed = 'CLOSED';
  static const notReady = 'NOT_READY';

  /// `play` while the app is in the background.
  static const background = 'BACKGROUND';

  /// The decoder failed, timed out or could not save.
  static const media = 'MEDIA';
}

class MediaStatus {
  const MediaStatus({
    required this.id,
    this.width = 0,
    this.height = 0,
    this.duration = Duration.zero,
    this.position = Duration.zero,
    this.playing = false,
    this.rate = 1,
    this.volume = 1,
    this.muted = false,
    this.loop = false,
    this.mimeType = '',
  });

  factory MediaStatus.fromMap(Map<Object?, Object?> map) => MediaStatus(
    id: (map['id']! as num).toInt(),
    width: (map['width'] as num? ?? 0).toInt(),
    height: (map['height'] as num? ?? 0).toInt(),
    duration: Duration(milliseconds: (map['duration'] as num? ?? 0).toInt()),
    position: Duration(milliseconds: (map['position'] as num? ?? 0).toInt()),
    playing: map['playing'] == true,
    rate: (map['rate'] as num? ?? 1).toDouble(),
    volume: (map['volume'] as num? ?? 1).toDouble(),
    muted: map['muted'] == true,
    loop: map['loop'] == true,
    mimeType: map['mimeType'] as String? ?? '',
  );

  /// The player, and the Flutter texture it draws into.
  final int id;
  final int width, height;
  final Duration duration, position;
  final bool playing, muted, loop;
  final double rate, volume;
  final String mimeType;

  MediaStatus copyWith({
    Duration? position,
    bool? playing,
    double? rate,
    double? volume,
    bool? muted,
    bool? loop,
  }) => MediaStatus(
    id: id,
    width: width,
    height: height,
    duration: duration,
    position: position ?? this.position,
    playing: playing ?? this.playing,
    rate: rate ?? this.rate,
    volume: volume ?? this.volume,
    muted: muted ?? this.muted,
    loop: loop ?? this.loop,
    mimeType: mimeType,
  );
}

class ChannelMediaPlayers implements MediaPlayers {
  const ChannelMediaPlayers();

  static const channel = MethodChannel('org.mozufu.pirc/media');

  Future<MediaStatus> _status(String method, Map<String, Object?> args) async =>
      MediaStatus.fromMap(
        (await channel.invokeMapMethod<Object?, Object?>(method, args))!,
      );

  Future<MediaStatus> _control(
    int id,
    String action, [
    Map<String, Object?> args = const {},
  ]) => _status('control', {'id': id, 'action': action, ...args});

  @override
  Future<MediaStatus> open(
    Uint8List bytes, {
    required String mimeType,
    required String kind,
    bool muted = false,
    bool loop = false,
  }) => _status('open', {
    'bytes': bytes,
    'mimeType': mimeType,
    'kind': kind,
    'muted': muted,
    'loop': loop,
  });

  @override
  Future<MediaStatus> openRecording(
    Uint8List bytes, {
    String mimeType = 'video/webm',
    bool Function()? cancelled,
  }) async {
    if (bytes.isEmpty || bytes.length > MediaPlayers.maxRecordingBytes) {
      throw PlatformException(code: MediaError.invalid);
    }
    void checkCancelled() {
      if (cancelled?.call() == true) {
        throw PlatformException(code: MediaError.closed);
      }
    }

    int? upload;
    try {
      for (var at = 0; at < bytes.length; at += MediaPlayers.partBytes) {
        checkCancelled();
        final end = (at + MediaPlayers.partBytes).clamp(0, bytes.length);
        upload = await channel.invokeMethod<int>('upload', {
          'upload': ?upload,
          'bytes': Uint8List.sublistView(bytes, at, end),
        });
      }
      checkCancelled();
    } catch (_) {
      if (upload != null) {
        try {
          await channel.invokeMethod<void>('discard', {'upload': upload});
        } on Exception {
          // The original failure matters more.
        }
      }
      rethrow;
    }
    // The upload belongs to the player from here, even when opening fails.
    return _status('open', {
      'upload': upload,
      'mimeType': mimeType,
      'kind': 'video',
    });
  }

  @override
  Future<MediaStatus> status(int id) => _control(id, 'status');

  @override
  Future<MediaStatus> play(int id) => _control(id, 'play');

  @override
  Future<MediaStatus> pause(int id) => _control(id, 'pause');

  @override
  Future<MediaStatus> seek(int id, Duration position) =>
      _control(id, 'seek', {'position': position.inMilliseconds});

  @override
  Future<MediaStatus> setVolume(int id, double volume) =>
      _control(id, 'volume', {'volume': volume});

  @override
  Future<MediaStatus> setRate(int id, double rate) =>
      _control(id, 'rate', {'rate': rate});

  @override
  Future<MediaStatus> setLoop(int id, bool loop) =>
      _control(id, 'loop', {'loop': loop});

  @override
  Future<String> save(int id, String name) async =>
      (await channel.invokeMethod<String>('save', {'id': id, 'name': name}))!;

  @override
  Future<void> close(int id) => channel.invokeMethod<void>('close', {'id': id});

  @override
  Future<void> closeAll() => channel.invokeMethod<void>('closeAll');
}

/// For tests: players in memory that play instantly, with the channel's
/// checks (sizes, MIME types, `NOT_READY`, `BACKGROUND`).
class FakeMediaPlayers implements MediaPlayers {
  FakeMediaPlayers({this.duration = const Duration(seconds: 10)});

  /// The length of opened media; zero for a WebM file without one.
  Duration duration;

  /// The app is in the background: `play` fails with `BACKGROUND`.
  bool background = false;

  /// Players whose decoder is still preparing: controls fail.
  final notReady = <int>{};

  /// Makes the next open fail with `MEDIA`, as a decoder error does.
  bool failNextOpen = false;

  /// How many status reads were made.
  int statusReads = 0;
  final players = <int, MediaStatus>{};
  final opened = <int, Uint8List>{};
  final saved = <String, Uint8List>{};
  final actions = <String>[];
  int closedAll = 0;
  var _next = 1;

  MediaStatus _get(int id) {
    final status =
        players[id] ?? (throw PlatformException(code: MediaError.closed));
    if (notReady.contains(id)) {
      throw PlatformException(code: MediaError.notReady);
    }
    return status;
  }

  MediaStatus _set(int id, MediaStatus status) => players[id] = status;

  MediaStatus _open(Uint8List bytes, String mimeType, String kind) {
    if (bytes.isEmpty ||
        (kind != 'audio' && kind != 'video') ||
        !MediaPlayers.playable(mimeType)) {
      throw PlatformException(code: MediaError.invalid);
    }
    if (failNextOpen) {
      failNextOpen = false;
      throw PlatformException(code: MediaError.media);
    }
    final id = _next++;
    opened[id] = bytes;
    return _set(
      id,
      MediaStatus(
        id: id,
        width: kind == 'video' ? 640 : 0,
        height: kind == 'video' ? 360 : 0,
        duration: duration,
        mimeType: mimeType.split(';').first.trim().toLowerCase(),
      ),
    );
  }

  @override
  Future<MediaStatus> open(
    Uint8List bytes, {
    required String mimeType,
    required String kind,
    bool muted = false,
    bool loop = false,
  }) async {
    if (bytes.length > MediaPlayers.maxBytes) {
      throw PlatformException(code: MediaError.invalid);
    }
    final status = _open(bytes, mimeType, kind);
    return _set(
      status.id,
      status.copyWith(volume: muted ? 0 : 1, muted: muted, loop: loop),
    );
  }

  @override
  Future<MediaStatus> openRecording(
    Uint8List bytes, {
    String mimeType = 'video/webm',
    bool Function()? cancelled,
  }) async {
    if (bytes.length > MediaPlayers.maxRecordingBytes) {
      throw PlatformException(code: MediaError.invalid);
    }
    if (cancelled?.call() == true) {
      throw PlatformException(code: MediaError.closed);
    }
    return _open(bytes, mimeType, 'video');
  }

  @override
  Future<MediaStatus> status(int id) async {
    statusReads++;
    return _get(id);
  }

  @override
  Future<MediaStatus> play(int id) async {
    final current = _get(id);
    if (background) throw PlatformException(code: MediaError.background);
    actions.add('play');
    return _set(id, current.copyWith(playing: true));
  }

  @override
  Future<MediaStatus> pause(int id) async {
    final current = _get(id);
    actions.add('pause');
    return _set(id, current.copyWith(playing: false));
  }

  @override
  Future<MediaStatus> seek(int id, Duration position) async {
    final current = _get(id);
    actions.add('seek ${position.inMilliseconds}');
    final clamped = position < Duration.zero
        ? Duration.zero
        : position > current.duration
        ? current.duration
        : position;
    return _set(id, current.copyWith(position: clamped));
  }

  @override
  Future<MediaStatus> setVolume(int id, double volume) async {
    final current = _get(id);
    if (!volume.isFinite) throw PlatformException(code: MediaError.invalid);
    final level = volume.clamp(0.0, 1.0);
    return _set(id, current.copyWith(volume: level, muted: level == 0));
  }

  @override
  Future<MediaStatus> setRate(int id, double rate) async {
    final current = _get(id);
    if (!(rate > 0 && rate <= 16)) {
      throw PlatformException(code: MediaError.invalid);
    }
    actions.add('rate $rate');
    // A paused player stays paused, as on Android.
    return _set(id, current.copyWith(rate: rate));
  }

  @override
  Future<MediaStatus> setLoop(int id, bool loop) async =>
      _set(id, _get(id).copyWith(loop: loop));

  @override
  Future<String> save(int id, String name) async {
    if (!players.containsKey(id)) {
      throw PlatformException(code: MediaError.closed);
    }
    saved[name] = opened[id]!;
    return name;
  }

  @override
  Future<void> close(int id) async {
    players.remove(id);
    opened.remove(id);
    notReady.remove(id);
  }

  @override
  Future<void> closeAll() async {
    closedAll++;
    players.clear();
    opened.clear();
    notReady.clear();
  }
}
