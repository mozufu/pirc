import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';

/// The lifecycle kinds, all labelled "Status".
const lifecycleActivityKinds = {
  'created',
  'updated',
  'paused',
  'resumed',
  'archived',
  'restored',
  'deleted',
};

/// The tag of an activity row (E5): the settled label of [kind], or the
/// kind itself when it is new to the app.
String activityKindLabel(AppLocalizations l10n, String kind) => switch (kind) {
  'dm' => l10n.activityKindDm,
  'group_message' => l10n.activityKindGroupMessage,
  'assign' => l10n.activityKindAssign,
  'work_opened' => l10n.activityKindWorkOpened,
  'work_instruction' => l10n.activityKindWorkInstruction,
  'file_read' => l10n.activityKindFileRead,
  'thinking_adjust' => l10n.activityKindThinkingAdjust,
  'fallback' => l10n.activityKindFallback,
  'awaiting_confirm' => l10n.activityKindAwaitingConfirm,
  'awaiting_approval' => l10n.activityKindAwaitingApproval,
  'approval_answered' => l10n.activityKindApprovalAnswered,
  'forwarded_to_user' => l10n.activityKindForwardedToUser,
  'budget_request' => l10n.activityKindBudgetRequest,
  'budget_exhausted' => l10n.activityKindBudgetExhausted,
  'loop_guard' => l10n.activityKindLoopGuard,
  'handover_proposed' => l10n.activityKindHandoverProposed,
  'review' => l10n.activityKindReview,
  'reminder_set' => l10n.activityKindReminderSet,
  'autonomy_changed' => l10n.activityKindAutonomyChanged,
  _ when lifecycleActivityKinds.contains(kind) => l10n.activityKindStatus,
  _ => kind,
};

/// The type filter's choices (E5's filter button), each the kinds it sends
/// as `kind=`: one per settled label, the lifecycle kinds together as
/// "Status".
const activityKindFilters = <List<String>>[
  ['dm'],
  ['group_message'],
  ['assign'],
  ['work_opened'],
  ['work_instruction'],
  ['file_read'],
  ['thinking_adjust'],
  ['fallback'],
  ['awaiting_confirm'],
  ['awaiting_approval'],
  ['approval_answered'],
  ['forwarded_to_user'],
  ['budget_request'],
  ['budget_exhausted'],
  ['loop_guard'],
  ['handover_proposed'],
  ['review'],
  ['reminder_set'],
  ['autonomy_changed'],
  [
    'created',
    'updated',
    'paused',
    'resumed',
    'archived',
    'restored',
    'deleted',
  ],
];

/// The tag's look: yellow where the user is waited on, the stronger fill
/// for private messages between pots (`e-tag.attn`, `e-tag.dm`).
LogTagTone activityKindTone(String kind) => switch (kind) {
  'awaiting_confirm' ||
  'awaiting_approval' ||
  'forwarded_to_user' ||
  'budget_request' ||
  'handover_proposed' => LogTagTone.attention,
  'dm' => LogTagTone.direct,
  _ => LogTagTone.plain,
};
