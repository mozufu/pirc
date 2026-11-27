import 'package:flutter/services.dart';
import 'package:pirc_render/src/render_l10n.dart';

/// JSON values that cross the script runtime boundary.
typedef Json = Map<String, dynamic>;

/// [value] as a [Json] map with string keys, or an empty map.
Json obj(dynamic value) =>
    value is Map ? value.map((k, v) => MapEntry('$k', v)) : {};

/// [value] as a list of [Json] maps, or an empty list.
List<Json> rows(dynamic value) => value is List ? value.map(obj).toList() : [];

/// A short message for a failed document operation. Platform messages that
/// look like stack text are replaced.
String describeDocumentError(Object error) {
  if (error is StateError) return error.message;
  if (error is FormatException) return error.message;
  if (error is PlatformException) {
    final message = error.message;
    if (message != null &&
        !message.contains('java.') &&
        !message.contains('Exception') &&
        !message.contains('null object')) {
      return message;
    }
    return tr("操作未完成，請重試。");
  }
  return tr("操作未完成，請重新載入後再試。");
}
