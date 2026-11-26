import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The system pickers, share, clipboard images and dropped images on
/// Android, through the `org.mozufu.pirc/files` channel (plans/roadmap.md M8
/// step 5). Kotlin reads picked content through `ContentResolver` streams
/// with [FilesPlatform.maxFileBytes] per file, cleans every name and takes
/// no persistable grant. Web and macOS keep `file_selector` and
/// `share_plus`.
abstract interface class FilesPlatform {
  /// Opens the system picker. Empty when the user cancelled. [mimeTypes]
  /// (for example `image/png`) only guide the picker. Each file has at most
  /// [maxBytes] (at most [maxPickBytes]); one pick reads at most
  /// [maxFiles] files and [maxTotalBytes] in all, and refuses the rest with
  /// [RefusedFile.tooMany]. Throws [FilesFailure] (`BUSY`, `UNAVAILABLE`).
  Future<FilePick> pick({
    bool multiple = true,
    List<String> mimeTypes = const [],
    int maxBytes = maxFileBytes,
  });

  /// Opens the save picker for [bytes] (at most [maxSaveBytes]), suggesting
  /// [name]; returns the saved name, or null when the user cancelled.
  ///
  /// Step 6's document downloads (`<a download>` and the document save) must
  /// use this on Android; recordings keep "Save to Downloads" (media
  /// channel).
  Future<String?> save(
    Uint8List bytes, {
    required String name,
    required String mimeType,
  });

  /// The share sheet for [text]. Text longer than [maxShareText] is shared
  /// as a `.txt` file.
  Future<void> shareText(String text, {String? subject});

  /// The share sheet for a file (at most [maxShareBytes]). Kotlin keeps it
  /// for an hour in its share cache, so the receiving app can read it.
  Future<void> shareFile(
    Uint8List bytes, {
    required String name,
    required String mimeType,
  });

  /// Whether the clipboard holds an image (without reading it).
  Future<bool> clipboardHasImages();

  /// The images on the clipboard.
  Future<FilePick> clipboardImages();

  /// Images dropped onto the area [rect] (logical pixels in the view) are
  /// read and given to [drops] with [token]. One area at a time.
  Future<void> setDropTarget(int token, Rect rect, double devicePixelRatio);
  Future<void> clearDropTarget(int token);
  Stream<FileDrop> get drops;

  /// The most any Gateway accepts for an upload (`MAX_UPLOAD_BYTES` in
  /// `crates/pirc-config`); a Gateway set lower still refuses with 413.
  static const maxFileBytes = 11 * 1024 * 1024;

  /// The largest [pick] `maxBytes`: a picture that is cropped before upload.
  static const maxPickBytes = 32 * 1024 * 1024;

  /// The node's `maxAttachments`.
  static const maxFiles = 16;
  static const maxTotalBytes = 64 * 1024 * 1024;
  static const maxSaveBytes = 32 * 1024 * 1024;
  static const maxShareBytes = 1024 * 1024 * 1024;
  static const maxShareText = 100000;

  /// The size of one part of a [shareFile] upload.
  static const partBytes = 8 * 1024 * 1024;
}

/// Error codes of [FilesFailure].
abstract final class FilesError {
  static const invalid = 'INVALID';

  /// A picker is already open.
  static const busy = 'BUSY';

  /// No app on the phone answers.
  static const unavailable = 'UNAVAILABLE';
  static const files = 'FILES';
}

class FilesFailure implements Exception {
  const FilesFailure(this.code);
  final String code;

  @override
  String toString() => 'FilesFailure($code)';
}

/// A file read from another app, with a clean name.
@immutable
class PickedFile {
  const PickedFile({
    required this.name,
    required this.mimeType,
    required this.bytes,
  });

  final String name;
  final String mimeType;
  final Uint8List bytes;
}

/// A file that was not read: [tooLarge] (over the size limit of one file),
/// [tooMany] (past [FilesPlatform.maxFiles] files or
/// [FilesPlatform.maxTotalBytes] in all) or [unreadable].
@immutable
class RefusedFile {
  const RefusedFile(this.name, this.reason);

  static const tooLarge = 'TOO_LARGE';
  static const tooMany = 'TOO_MANY';
  static const unreadable = 'READ';

  final String name;
  final String reason;
}

@immutable
class FilePick {
  const FilePick({this.files = const [], this.refused = const []});

  static const empty = FilePick();

  factory FilePick.fromWire(Object? value) {
    final files = <PickedFile>[];
    final refused = <RefusedFile>[];
    for (final item in value is List ? value : const []) {
      if (item is! Map) continue;
      final name = item['name'] as String? ?? 'file';
      final bytes = item['bytes'];
      if (bytes is Uint8List) {
        files.add(
          PickedFile(
            name: name,
            mimeType: item['mimeType'] as String? ?? 'application/octet-stream',
            bytes: bytes,
          ),
        );
      } else {
        refused.add(
          RefusedFile(name, item['error'] as String? ?? RefusedFile.unreadable),
        );
      }
    }
    return FilePick(files: files, refused: refused);
  }

  final List<PickedFile> files;
  final List<RefusedFile> refused;

  bool get isEmpty => files.isEmpty && refused.isEmpty;
}

/// Images dropped onto the drop target [token].
@immutable
class FileDrop {
  const FileDrop(this.token, this.pick);
  final int token;
  final FilePick pick;
}

class ChannelFilesPlatform implements FilesPlatform {
  ChannelFilesPlatform() {
    channel.setMethodCallHandler(_fromKotlin);
  }

  static const channel = MethodChannel('org.mozufu.pirc/files');

  final _drops = StreamController<FileDrop>.broadcast();

  Future<Object?> _fromKotlin(MethodCall call) async {
    if (call.method != 'dropped') return null;
    final args = call.arguments as Map;
    final token = (args['token'] as num?)?.toInt();
    if (token != null && !_drops.isClosed) {
      _drops.add(FileDrop(token, FilePick.fromWire(args['files'])));
    }
    return null;
  }

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await channel.invokeMethod<T>(method, args);
    } on PlatformException catch (error) {
      throw FilesFailure(error.code);
    }
  }

  @override
  Future<FilePick> pick({
    bool multiple = true,
    List<String> mimeTypes = const [],
    int maxBytes = FilesPlatform.maxFileBytes,
  }) async {
    final picked = await _invoke<Object>('pick', {
      'multiple': multiple,
      'mimeTypes': mimeTypes,
      'maxBytes': maxBytes,
    });
    return picked == null ? FilePick.empty : FilePick.fromWire(picked);
  }

  @override
  Future<String?> save(
    Uint8List bytes, {
    required String name,
    required String mimeType,
  }) {
    if (bytes.length > FilesPlatform.maxSaveBytes) {
      throw const FilesFailure(FilesError.invalid);
    }
    return _invoke<String>('save', {
      'bytes': bytes,
      'name': name,
      'mimeType': mimeType,
    });
  }

  @override
  Future<void> shareText(String text, {String? subject}) {
    if (text.length > FilesPlatform.maxShareText) {
      return shareFile(
        utf8.encode(text),
        name: '${subject == null || subject.isEmpty ? 'text' : subject}.txt',
        mimeType: 'text/plain',
      );
    }
    return _invoke<void>('shareText', {'text': text, 'subject': ?subject});
  }

  @override
  Future<void> shareFile(
    Uint8List bytes, {
    required String name,
    required String mimeType,
  }) async {
    if (bytes.isEmpty || bytes.length > FilesPlatform.maxShareBytes) {
      throw const FilesFailure(FilesError.invalid);
    }
    int? share;
    try {
      for (
        var start = 0;
        start < bytes.length;
        start += FilesPlatform.partBytes
      ) {
        final end = math.min(start + FilesPlatform.partBytes, bytes.length);
        share = await _invoke<int>('sharePart', {
          'share': ?share,
          'bytes': Uint8List.sublistView(bytes, start, end),
        });
      }
    } on FilesFailure {
      if (share != null) {
        try {
          await _invoke<void>('shareDiscard', {'share': share});
        } on FilesFailure {
          // The upload is gone already.
        }
      }
      rethrow;
    }
    await _invoke<void>('shareFile', {
      'share': share,
      'name': name,
      'mimeType': mimeType,
    });
  }

  @override
  Future<bool> clipboardHasImages() async =>
      await _invoke<bool>('clipboardHasImages') ?? false;

  @override
  Future<FilePick> clipboardImages() async =>
      FilePick.fromWire(await _invoke<Object>('clipboardImages'));

  @override
  Future<void> setDropTarget(int token, Rect rect, double devicePixelRatio) =>
      _invoke<void>('setDropTarget', {
        'token': token,
        'left': rect.left,
        'top': rect.top,
        'right': rect.right,
        'bottom': rect.bottom,
        'devicePixelRatio': devicePixelRatio,
      });

  @override
  Future<void> clearDropTarget(int token) =>
      _invoke<void>('clearDropTarget', {'token': token});

  @override
  Stream<FileDrop> get drops => _drops.stream;

  void dispose() {
    channel.setMethodCallHandler(null);
    unawaited(_drops.close());
  }
}

/// For tests: answers each [pick] with the next of [picks] (a [FilePick] or
/// a [FilesFailure]; empty means cancelled) and records the rest.
class FakeFilesPlatform implements FilesPlatform {
  FakeFilesPlatform({List<Object>? picks, this.clipboard = FilePick.empty})
    : picks = picks ?? [];

  final List<Object> picks;
  FilePick clipboard;

  /// Answers of [save]: the saved name, null (cancelled) or a failure.
  final saves = <Object?>[];
  final saved = <(String name, String mimeType, Uint8List bytes)>[];
  final pickCalls = <(bool multiple, List<String> mimeTypes, int maxBytes)>[];

  /// How often the clipboard's images were read.
  int clipboardReads = 0;
  final sharedTexts = <(String text, String? subject)>[];
  final sharedFiles = <(String name, String mimeType, Uint8List bytes)>[];
  final dropTargets = <int, Rect>{};
  final _drops = StreamController<FileDrop>.broadcast();

  @override
  Future<FilePick> pick({
    bool multiple = true,
    List<String> mimeTypes = const [],
    int maxBytes = FilesPlatform.maxFileBytes,
  }) async {
    pickCalls.add((multiple, mimeTypes, maxBytes));
    final next = picks.isEmpty ? FilePick.empty : picks.removeAt(0);
    if (next is FilesFailure) throw next;
    return next as FilePick;
  }

  @override
  Future<String?> save(
    Uint8List bytes, {
    required String name,
    required String mimeType,
  }) async {
    final next = saves.isEmpty ? name : saves.removeAt(0);
    if (next is FilesFailure) throw next;
    if (next != null) saved.add((name, mimeType, bytes));
    return next as String?;
  }

  @override
  Future<void> shareText(String text, {String? subject}) async =>
      sharedTexts.add((text, subject));

  @override
  Future<void> shareFile(
    Uint8List bytes, {
    required String name,
    required String mimeType,
  }) async => sharedFiles.add((name, mimeType, bytes));

  @override
  Future<bool> clipboardHasImages() async => !clipboard.isEmpty;

  @override
  Future<FilePick> clipboardImages() async {
    clipboardReads++;
    return clipboard;
  }

  @override
  Future<void> setDropTarget(
    int token,
    Rect rect,
    double devicePixelRatio,
  ) async => dropTargets[token] = rect;

  @override
  Future<void> clearDropTarget(int token) async => dropTargets.remove(token);

  @override
  Stream<FileDrop> get drops => _drops.stream;

  /// Drops [pick] onto the current target, as Kotlin does.
  void drop(FilePick pick) {
    for (final token in dropTargets.keys) {
      _drops.add(FileDrop(token, pick));
    }
  }
}

/// The files channel of this platform: Android only.
final filesPlatformProvider = Provider<FilesPlatform?>((ref) {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
  final files = ChannelFilesPlatform();
  ref.onDispose(files.dispose);
  return files;
});
