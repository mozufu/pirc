import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'panels/panel_container.dart';
import 'result_reader.dart';

/// The Work tab location that opens [open] (a session, `project:<id>` or the
/// new-conversation key), with [side] in the side pane.
///
/// [from] is where Back goes: a conversation opened from a project page
/// returns to that page. When [from] is not given and [context] shows the
/// same item, the current one is kept, so opening a panel or a result does
/// not lose it.
String workLocation(
  String open, {
  String? side,
  String? from,
  BuildContext? context,
}) {
  if (from == null && context != null) {
    final here = GoRouterState.of(context).uri.queryParameters;
    if (here['open'] == open) from = here['from'];
  }
  return Uri(
    path: '/work',
    queryParameters: {'open': open, 'side': ?side, 'from': ?from},
  ).toString();
}

/// Where Back goes from the open Work item: the item named by `from`, else
/// the list.
String workBackLocation(BuildContext context) {
  final from = GoRouterState.of(context).uri.queryParameters['from'];
  return from == null || from.isEmpty ? '/work' : workLocation(from);
}

/// The side pane of a work conversation: one kind of content at a time
/// (rule C). [side] is `result:<artifact>` or `panel:<section>`.
Widget? workSide(BuildContext context, String sessionId, String side) {
  void close() => context.go(workLocation(sessionId, context: context));
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
        workLocation(sessionId, side: panelSide(next), context: context),
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
