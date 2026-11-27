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
