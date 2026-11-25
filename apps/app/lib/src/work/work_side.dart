import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'panels/panel_container.dart';
import 'result_reader.dart';

/// The side pane of a work conversation: one kind of content at a time
/// (rule C). [side] is `result:<artifact>` or `panel:<section>`.
Widget? workSide(BuildContext context, String sessionId, String side) {
  void close() => context.go(
    Uri(path: '/work', queryParameters: {'open': sessionId}).toString(),
  );
  final section = side.startsWith('panel:')
      ? PanelSection.parse(side.substring('panel:'.length))
      : null;
  if (section != null) {
    return PanelContainer(
      key: const ValueKey('panels'),
      sessionId: sessionId,
      section: section,
      onClose: close,
      onSelect: (next) => context.go(
        Uri(
          path: '/work',
          queryParameters: {'open': sessionId, 'side': panelSide(next)},
        ).toString(),
      ),
    );
  }
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
