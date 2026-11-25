import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'result_reader.dart';

/// The side pane of a work conversation: one kind of content at a time
/// (rule C). [side] is `result:<artifact>`.
Widget? workSide(BuildContext context, String sessionId, String side) {
  void close() => context.go(
    Uri(path: '/work', queryParameters: {'open': sessionId}).toString(),
  );
  if (side.startsWith('result:')) {
    return ResultReader(
      key: ValueKey(side),
      sessionId: sessionId,
      artifactId: side.substring('result:'.length),
      onClose: close,
    );
  }
  return null;
}
