import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';

import '../../platform/files.dart';

/// A file the user picked, not uploaded yet.
@immutable
class PendingAttachment {
  const PendingAttachment({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.bytes,
  });

  final String id;
  final String name;
  final String mimeType;
  final Uint8List bytes;

  /// As a first-send declaration (with its SHA-256).
  SubmissionAttachment get declaration => SubmissionAttachment(
    id: id,
    name: name,
    mimeType: mimeType,
    byteSize: bytes.length,
    sha256: sha256.convert(bytes).toString(),
  );
}

/// What a pick, a paste or a drop gives: the files to add, and the files
/// that were not read (too large, too many or unreadable).
@immutable
class AttachmentPick {
  const AttachmentPick(this.files, {this.refused = const []});

  factory AttachmentPick.from(FilePick pick) => AttachmentPick([
    for (final file in pick.files)
      PendingAttachment(
        id: randomId(),
        name: file.name,
        mimeType: file.mimeType,
        bytes: file.bytes,
      ),
  ], refused: pick.refused);

  final List<PendingAttachment> files;
  final List<RefusedFile> refused;
}

/// Picks files: the system picker of the files channel on Android, and
/// `file_selector` on Web and macOS. Throws when the picker cannot open.
/// Tests replace it.
final filePickerProvider = Provider<Future<AttachmentPick> Function()>((ref) {
  final files = ref.watch(filesPlatformProvider);
  if (files != null) return () async => AttachmentPick.from(await files.pick());
  return () async {
    final files = await openFiles();
    return AttachmentPick([
      for (final file in files)
        PendingAttachment(
          id: randomId(),
          name: file.name,
          mimeType: file.mimeType ?? _mimeFor(file.name),
          bytes: await file.readAsBytes(),
        ),
    ]);
  };
});

String _mimeFor(String name) {
  final extension = name.split('.').last.toLowerCase();
  return const {
        'png': 'image/png',
        'jpg': 'image/jpeg',
        'jpeg': 'image/jpeg',
        'gif': 'image/gif',
        'webp': 'image/webp',
        'pdf': 'application/pdf',
        'txt': 'text/plain',
        'md': 'text/markdown',
        'json': 'application/json',
      }[extension] ??
      'application/octet-stream';
}
