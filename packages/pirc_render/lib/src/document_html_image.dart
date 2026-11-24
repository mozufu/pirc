import 'render_l10n.dart';
import 'package:flutter/foundation.dart';

/// Image loading state from the current script snapshot, separate from authored
/// HTML/CSS attributes. Pixel handles belong to this native document only.
@immutable
class NativeDocumentHtmlImage {
  const NativeDocumentHtmlImage({
    required this.status,
    this.imageId,
    this.vector = false,
    this.animated = false,
  });
  final String status;
  final String? imageId;
  final bool vector;
  final bool animated;
}

Map<String, NativeDocumentHtmlImage> decodeNativeDocumentHtmlImages(
  Object? input, {
  required Set<String> available,
  Set<String> vectors = const {},
  Set<String> animated = const {},
}) {
  final raw = input ?? const [];
  if (raw is! List || raw.length > 5000) {
    throw FormatException(tr("Invalid HTML image snapshot."));
  }
  final result = <String, NativeDocumentHtmlImage>{};
  for (final entry in raw) {
    if (entry is! Map) throw FormatException(tr("Invalid HTML image state."));
    final id = entry['id'], status = entry['status'], image = entry['imageId'];
    if (id is! String ||
        !RegExp(r'^pirc-[1-9][0-9]*$').hasMatch(id) ||
        result.containsKey(id) ||
        !const {'empty', 'pending', 'loaded', 'error'}.contains(status) ||
        (status == 'loaded'
            ? image is! String || !available.contains(image)
            : image != null)) {
      throw FormatException(tr("Invalid HTML image ownership."));
    }
    result[id] = NativeDocumentHtmlImage(
      status: status as String,
      imageId: image as String?,
      vector: image != null && vectors.contains(image),
      animated: image != null && animated.contains(image),
    );
  }
  return Map.unmodifiable(result);
}
