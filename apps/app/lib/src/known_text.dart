import 'package:pirc_client/pirc_client.dart';

import '../l10n/app_localizations.dart';

/// A session's name for display: the placeholder in the app's words.
String sessionTitle(AppLocalizations l10n, String name) =>
    name == placeholderSessionName ? l10n.sessionUntitled : name;

/// A question's title for display: the agent's approval titles in the app's
/// words, anything else as sent.
String questionTitle(AppLocalizations l10n, String title) => switch (title) {
  autoModeApprovalTitle => l10n.approvalAutoModeTitle,
  readOnlyApprovalTitle => l10n.approvalReadOnlyTitle,
  _ => title,
};

/// An option's label for display: the agent's "Other" in the app's words.
String optionLabel(AppLocalizations l10n, InteractionOption option) =>
    option.other ? l10n.questionOther : option.label;

/// A typed answer's hint for display: the agent's in the app's words.
String? inputPlaceholder(AppLocalizations l10n, String? placeholder) =>
    placeholder == askInputPlaceholder
    ? l10n.questionInputPlaceholder
    : placeholder;

/// An approval question's message for display. The agent writes
/// `<label> (<tool>, in <place>):\n\n<text>\n\nReason: <reason>`; the frame is
/// shown in the app's words, the command and the reason (the classifier's) as
/// sent. Anything else, or a message under another title, is shown as sent.
String questionMessage(AppLocalizations l10n, String title, String message) {
  if (title != autoModeApprovalTitle && title != readOnlyApprovalTitle) {
    return message;
  }
  const reasonMark = '\n\nReason: ';
  final cut = message.lastIndexOf(reasonMark);
  if (cut < 0) return message;
  final head = message.substring(0, cut);
  final reason = message.substring(cut + reasonMark.length);
  final textAt = head.indexOf('):\n\n');
  if (textAt < 0) return message;
  final header = head.substring(0, textAt);
  final text = head.substring(textAt + 4);
  final label = <String, String>{
    approvalLabelFileChange: l10n.approvalLabelFileChange,
    approvalLabelInput: l10n.approvalLabelInput,
    approvalLabelScript: l10n.approvalLabelScript,
    approvalLabelCommand: l10n.approvalLabelCommand,
  }.entries.where((e) => header.startsWith('${e.key} (')).firstOrNull;
  if (label == null) return message;
  final where = header.substring(label.key.length + 2);
  final inAt = where.indexOf(', in ');
  if (inAt < 0) return message;
  return l10n.approvalMessage(
    label.value,
    where.substring(0, inAt),
    where.substring(inAt + 5),
    text,
    reason,
  );
}
