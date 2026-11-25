// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'pirc';

  @override
  String get tabChat => 'Chat';

  @override
  String get tabWork => 'Work';

  @override
  String get tabActivity => 'Activity';

  @override
  String get tabCalendar => 'Calendar';

  @override
  String get settings => 'Settings';

  @override
  String get back => 'Back';

  @override
  String get emptyChat => 'No pots or groups yet';

  @override
  String get emptyWork => 'No sessions yet';

  @override
  String get emptyActivity => 'No activity yet';

  @override
  String get emptyCalendar => 'Nothing scheduled';

  @override
  String get nothingOpen => 'Select an item to open it';

  @override
  String openItem(String id) {
    return 'Item $id';
  }

  @override
  String get language => 'Language';

  @override
  String get languageSystem => 'Follow the system';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageTraditionalChinese => '繁體中文';

  @override
  String get appearance => 'Appearance';

  @override
  String get appearanceSystem => 'Follow the system';

  @override
  String get appearanceLight => 'Light';

  @override
  String get appearanceDark => 'Dark';

  @override
  String get pairTitle => 'Pair this device';

  @override
  String get pairBody =>
      'Paste the pairing link that the Gateway\'s web page shows.';

  @override
  String get pairLinkLabel => 'Pairing link';

  @override
  String get pairAction => 'Pair';

  @override
  String get pairChecking => 'Checking…';

  @override
  String get pairPaired => 'Paired';

  @override
  String get pairNotALink => 'This is not a pairing link.';

  @override
  String get pairTokenRefused =>
      'The Gateway did not accept this link. Create a new one.';

  @override
  String get pairAppTooOld =>
      'This app is too old for the Gateway. Update the app.';

  @override
  String get pairUnreachable => 'The Gateway could not be reached.';

  @override
  String get pairFailed => 'Pairing failed.';

  @override
  String get offlineBanner => 'Offline. What you see may be out of date.';

  @override
  String get reconnecting => 'Reconnecting…';

  @override
  String get loadingTitle => 'Reconnecting and fetching the latest state…';

  @override
  String get loadingNote => 'No buttons are shown until the state is known.';

  @override
  String get upgradeTitle => 'Update the app';

  @override
  String get upgradeBody =>
      'This version of the app is too old for your Gateway. Update it to continue.';

  @override
  String get signedOutTitle => 'Sign in again';

  @override
  String get signedOutBody =>
      'Your sign-in has ended. Reload the page to sign in again.';

  @override
  String get openDrawer => 'Open the menu';

  @override
  String get closeDrawer => 'Close the menu';

  @override
  String get gatewayConnected => 'Gateway connected';

  @override
  String get gatewayOffline => 'Gateway offline';

  @override
  String get hosts => 'Hosts';

  @override
  String get hostsFailed => 'The hosts could not be loaded.';

  @override
  String get noHosts => 'No host is connected.';

  @override
  String get hostIdle => 'No work running';

  @override
  String hostRunning(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count sessions running',
      one: '1 session running',
    );
    return '$_temp0';
  }

  @override
  String get switchToLight => 'Switch to light';

  @override
  String get switchToDark => 'Switch to dark';

  @override
  String get workSubtitle => 'By project';

  @override
  String get searchWork => 'Search work and projects';

  @override
  String get filterAll => 'All';

  @override
  String get filterNeedsYou => 'Needs you';

  @override
  String get filterRunning => 'Running';

  @override
  String get filterMine => 'Mine';

  @override
  String get filterPots => 'Opened by pots';

  @override
  String get noteNeedsYou =>
      'Work that needs your answer, approval or review. Reading it is not handling it: a row leaves only when it is handled.';

  @override
  String get notePots =>
      'A pot coordinates the work it opens. You can answer, stop or take it over.';

  @override
  String get noteMine => 'Only the work you opened.';

  @override
  String groupCount(int count) {
    return '$count';
  }

  @override
  String get noProject => 'No project';

  @override
  String fromPot(String name) {
    return 'From $name';
  }

  @override
  String get fromYou => 'You';

  @override
  String get stateWaiting => 'Waiting for your answer';

  @override
  String get stateRunning => 'Running';

  @override
  String get stateQueued => 'Queued';

  @override
  String get stateStopping => 'Stopping…';

  @override
  String get stateIdle => 'Idle';

  @override
  String get stateSettled => 'Settled';

  @override
  String approvalWaiting(String model) {
    return 'Not started · waiting for you to approve $model';
  }

  @override
  String get needsYouPill => 'Needs you';

  @override
  String get yesterday => 'Yesterday';

  @override
  String get pinned => 'Pinned';

  @override
  String get moreActions => 'More actions';

  @override
  String get actionRename => 'Rename';

  @override
  String get actionPin => 'Pin';

  @override
  String get actionUnpin => 'Unpin';

  @override
  String get actionSettle => 'Settle';

  @override
  String get actionUnsettle => 'Reopen';

  @override
  String get actionDelete => 'Delete…';

  @override
  String get deleteWorkTitle => 'Delete this work?';

  @override
  String get deleteWorkBody =>
      'Its conversation is deleted. This cannot be undone.';

  @override
  String get delete => 'Delete';

  @override
  String get cancel => 'Cancel';

  @override
  String get save => 'Save';

  @override
  String actionFailed(String message) {
    return 'That did not work: $message';
  }

  @override
  String get emptyFilter => 'Nothing here.';

  @override
  String get listFailed => 'The list could not be loaded.';

  @override
  String get retry => 'Try again';

  @override
  String get newConversation => 'New conversation';

  @override
  String get questionWaits => 'A question waits for you';

  @override
  String get newContent => 'New content';

  @override
  String get turnFailed => 'This turn failed.';

  @override
  String get turnStopped => 'Stopped.';

  @override
  String toolSteps(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count tool steps',
      one: '1 tool step',
    );
    return '$_temp0';
  }

  @override
  String toolFailures(int count) {
    return '$count failed';
  }

  @override
  String get stepFailed => 'Failed';

  @override
  String get stepDone => 'Done';

  @override
  String get sessionDeleted => 'This work was deleted.';

  @override
  String get sessionFailed => 'This work could not be loaded.';

  @override
  String get partialOutputLost => 'Some output was lost while reconnecting.';

  @override
  String get controlledElsewhere => 'Controlled by another device';

  @override
  String get takeControl => 'Take control';

  @override
  String get dockGoal => 'Goal';

  @override
  String get dockTodo => 'Tasks';

  @override
  String dockQueue(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count queued messages',
      one: '1 queued message',
    );
    return '$_temp0';
  }

  @override
  String get whenSteer => 'Steer';

  @override
  String get whenQueue => 'Queue';

  @override
  String get thinkingOff => 'Off';

  @override
  String get thinkingMinimal => 'Minimal';

  @override
  String get thinkingLow => 'Low';

  @override
  String get thinkingMedium => 'Medium';

  @override
  String get thinkingHigh => 'High';

  @override
  String get thinkingXhigh => 'Extra high';

  @override
  String get thinkingDefault => 'Default thinking';

  @override
  String get modelRow => 'Model';

  @override
  String get thinkingRow => 'Thinking';

  @override
  String get modelDefault => 'Default model';

  @override
  String get thinkingUnsupported => 'This model has no thinking levels';

  @override
  String get composerLocked => 'Take over to send messages';

  @override
  String get composerReadOnly => 'Another device controls this work';

  @override
  String get composerOffline => 'Offline. Your draft is kept.';

  @override
  String get composerHint => 'Message…';

  @override
  String get commandRejected => 'The work refused this message.';

  @override
  String get staleEnvironment =>
      'The work\'s environment changed. Your draft is kept.';

  @override
  String get attach => 'Attach files';

  @override
  String get stopWork => 'Stop this work';

  @override
  String get send => 'Send';

  @override
  String get notSureArrived => 'Not sure it arrived';

  @override
  String get checkStatus => 'Check status';

  @override
  String get pickWorkspace => 'Choose a project';

  @override
  String get firstSending => 'Sending…';

  @override
  String get firstRefused => 'The first message was refused.';

  @override
  String get sendAgain => 'Send again';

  @override
  String get firstNotSent => 'Not sent.';

  @override
  String get newConversationEmpty =>
      'Choose a project and write the first message.';

  @override
  String get noWorkspaces => 'No projects yet.';

  @override
  String hostOffline(String host) {
    return '$host · offline';
  }

  @override
  String get workspaceHostOffline => 'Its host is offline';

  @override
  String get workspaceUnavailable =>
      'Its mode is not available on this Gateway';

  @override
  String handledElsewhere(String title) {
    return '$title · handled on another device';
  }

  @override
  String get questionExpired => 'Expired';

  @override
  String expiresAt(String time) {
    return 'Expires at $time';
  }

  @override
  String get no => 'No';

  @override
  String get yes => 'Yes';

  @override
  String get questionSkipped => 'Skipped';

  @override
  String get skip => 'Skip';

  @override
  String get approvalReadOnly => 'Read only';

  @override
  String get approvalAuto => 'Auto';

  @override
  String get approvalFullAccess => 'Full access';

  @override
  String get approvalMode => 'Approval mode';

  @override
  String get approvalFullAccessWarning =>
      'The agent may run any command and change any file without asking. Use this only for work you trust.';

  @override
  String get approvalFullAccessConfirm => 'Allow full access';

  @override
  String get notSentByYou => 'Not sent by you';

  @override
  String potCoordinates(String name) {
    return '$name coordinates this work. You can answer its questions or stop it; take over to send instructions.';
  }

  @override
  String get takeOver => 'Take over';

  @override
  String takenOver(String name) {
    return '$name sends no more instructions here.';
  }

  @override
  String get resultGenerating => 'Generating…';

  @override
  String get resultFailed => 'Failed';

  @override
  String get resultReadSoFar => 'Read what is ready';

  @override
  String get resultOpen => 'Open';

  @override
  String get copy => 'Copy';

  @override
  String get copied => 'Copied';

  @override
  String get share => 'Share';

  @override
  String get close => 'Close';

  @override
  String get resultMissing => 'This result is no longer in the conversation.';

  @override
  String get resultVersions => 'Versions';

  @override
  String resultNewer(int version) {
    return 'Version $version is ready.';
  }

  @override
  String resultSwitch(int version) {
    return 'Switch to v$version';
  }

  @override
  String resultFailedShowingLast(int version) {
    return 'Version $version failed. The last good version is shown.';
  }

  @override
  String get resultNoColumns => 'This table has no columns.';

  @override
  String get resultUnsupported =>
      'This kind of result is shown as its summary.';
}
