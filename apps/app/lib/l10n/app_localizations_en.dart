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
  String get chatOnline => 'Connected';

  @override
  String get chatOffline => 'Offline';

  @override
  String get chatNewTooltip => 'New pot or group';

  @override
  String get searchChat => 'Search pots, groups and messages';

  @override
  String get chatFilterUnread => 'Unread';

  @override
  String get chatFilterPots => 'Pots';

  @override
  String get chatFilterGroups => 'Groups';

  @override
  String get chatEmptyFilter => 'No chats here.';

  @override
  String get chatNoMessages => 'No messages yet';

  @override
  String get chatAuthorYou => 'You';

  @override
  String chatPreviewBy(String name, String message) {
    return '$name: $message';
  }

  @override
  String groupMemberCount(int count) {
    return '$count people';
  }

  @override
  String get potPaused => 'Paused';

  @override
  String get potWorking => 'Working';

  @override
  String get potUnavailable => 'Unavailable';

  @override
  String get chatNewPot => 'New pot';

  @override
  String get chatNewGroup => 'Create group';

  @override
  String get newSheetTitle => 'New';

  @override
  String get newSheetNote =>
      'New conversations (work) start from the top right of the Work tab.';

  @override
  String get newPotDetail =>
      'Set its name, avatar, personality and what it looks after';

  @override
  String get newGroupDetail =>
      'Bring a few pots together to talk, with one as host';

  @override
  String get newGroupNeedsTwo => 'Create at least two pots first';

  @override
  String approvalSheetTitle(String pot, String model) {
    return '$pot wants to use $model';
  }

  @override
  String get approvalRowWork => 'Work';

  @override
  String get approvalRowModel => 'Model';

  @override
  String get approvalRowWhy => 'Why';

  @override
  String get approvalRowBudget => 'Budget';

  @override
  String get approvalNotStarted => 'Not started';

  @override
  String approvalEstimate(String cost, String pot, String left) {
    return 'Estimated $cost · $pot has $left left this month';
  }

  @override
  String approvalEstimateNoLimit(String cost) {
    return 'Estimated $cost · no money limit';
  }

  @override
  String approvalNote(String model, String pot) {
    return 'You set $model to “Ask you”. Allowing works for this time only; to stop being asked, change it to “Direct” in $pot\'s settings.';
  }

  @override
  String get deny => 'Deny';

  @override
  String get denyWithReason => 'Deny with a reason';

  @override
  String get allowOnce => 'Allow once';

  @override
  String denyReasonHint(String pot) {
    return 'Tell $pot why, for example “Compare once more with Sonnet and list what differs”';
  }

  @override
  String get denyAndSend => 'Deny and send the reason';

  @override
  String get answered => 'Answered';

  @override
  String get answeredAllowedOnce => 'Allowed once';

  @override
  String get answeredUsed => 'Allowed once (used)';

  @override
  String get answeredDenied => 'Denied';

  @override
  String answeredDeniedWithReason(String reason) {
    return 'Denied: $reason';
  }

  @override
  String budgetSheetTitle(String pot) {
    return '$pot asks for more budget';
  }

  @override
  String get budgetRowAsk => 'Asks for';

  @override
  String budgetMoreMoney(String amount) {
    return '$amount more this month';
  }

  @override
  String budgetMoreTokens(String tokens) {
    return '$tokens more tokens today';
  }

  @override
  String budgetLeftMoney(String amount) {
    return '$amount left this month';
  }

  @override
  String budgetLeftTokens(String tokens) {
    return '$tokens tokens left today';
  }

  @override
  String budgetNote(String pot) {
    return 'Approving raises $pot\'s limit for the current period only.';
  }

  @override
  String get approve => 'Approve';

  @override
  String get approveOtherAmount => 'Approve another amount';

  @override
  String get approveThisAmount => 'Approve this amount';

  @override
  String get budgetAmountMoneyHint => 'Amount in US dollars';

  @override
  String get budgetAmountTokensHint => 'Number of tokens';

  @override
  String get answeredApproved => 'Approved';

  @override
  String answeredApprovedAmount(String amount) {
    return 'Approved $amount';
  }

  @override
  String get emptyWork => 'No sessions yet';

  @override
  String get emptyActivity => 'No activity yet';

  @override
  String get emptyCalendar => 'Nothing scheduled';

  @override
  String get nothingOpen => 'Select an item to open it';

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
  String controlledByName(String name) {
    return 'Controlled by $name';
  }

  @override
  String continuedOn(String name) {
    return 'Continued on $name';
  }

  @override
  String takeoverConfirm(String name) {
    return '$name was just working here. Send anyway?';
  }

  @override
  String get anotherDevice => 'Another device';

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
  String get thinkingMax => 'Max';

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
  String answeredOn(String name, String time) {
    return 'Answered on $name · $time';
  }

  @override
  String answeredOnName(String name) {
    return 'Answered on $name';
  }

  @override
  String get questionAnswered => 'Answered';

  @override
  String get questionOther => 'Other (type your own answer)';

  @override
  String get sessionUntitled => 'New session';

  @override
  String get approvalAutoModeTitle =>
      'Auto mode: allow a potentially dangerous action?';

  @override
  String get approvalReadOnlyTitle => 'Read-only mode: allow this action?';

  @override
  String approvalMessage(
    String label,
    String tool,
    String place,
    String text,
    String reason,
  ) {
    return '$label ($tool, in $place):\n\n$text\n\nReason: $reason';
  }

  @override
  String get approvalLabelFileChange => 'File change';

  @override
  String get approvalLabelInput => 'Input';

  @override
  String get approvalLabelScript => 'Script';

  @override
  String get approvalLabelCommand => 'Command';

  @override
  String get questionInputPlaceholder => 'Enter your answer';

  @override
  String get questionWithdrawn => 'Withdrawn';

  @override
  String get questionStale => 'Ended when the session restarted';

  @override
  String questionEnded(String title) {
    return '$title · ended';
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
  String potBarOpen(String name) {
    return 'open the conversation with $name';
  }

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

  @override
  String get accessNeeded => 'Approval needed';

  @override
  String get accessOpenInBrowser =>
      'Open this address in a browser where you are signed in, and approve:';

  @override
  String accessRequestExpires(String time) {
    return 'The request expires at $time.';
  }

  @override
  String get accessDenied => 'The request was denied.';

  @override
  String get accessExpired => 'The request or the access expired.';

  @override
  String get accessAsk => 'Ask for access';

  @override
  String get settingsDevices => 'Devices';

  @override
  String get accessDevicesReason =>
      'Listing and removing paired devices needs a short approval from a browser.';

  @override
  String deviceLastUsed(String time) {
    return 'Last used $time';
  }

  @override
  String get deviceRevoke => 'Remove';

  @override
  String get deviceRevokeNeedsAccess =>
      'Removing a device needs access to remove devices.';

  @override
  String get devicePair => 'Pair a new device';

  @override
  String get accessPairReason =>
      'Pairing a new device needs a short approval from a browser.';

  @override
  String deviceRevokeTitle(String name) {
    return 'Remove $name?';
  }

  @override
  String get deviceRevokeBody =>
      'It can no longer reach this Gateway until it is paired again.';

  @override
  String devicePaired(String name) {
    return '$name is ready';
  }

  @override
  String get devicePairOnce =>
      'This link and code are shown only once. Open the link on the new device or scan the code.';

  @override
  String deviceExpires(String time) {
    return 'The new device works until $time unless it is renewed.';
  }

  @override
  String get done => 'Done';

  @override
  String get deviceName => 'Device name';

  @override
  String get devicePairAction => 'Pair';

  @override
  String get capabilityProviders =>
      'Change model providers and their credentials';

  @override
  String get capabilityDevicesRead => 'See the list of paired devices';

  @override
  String get capabilityDevicesRevoke => 'Remove paired devices';

  @override
  String get capabilityDevicesPair =>
      'Pair new devices that can use this Gateway';

  @override
  String approvalTitle(String device) {
    return '$device asks for access';
  }

  @override
  String approvalPairingLifetime(int idle, int max) {
    return 'Each new device works for $idle days without use and at most $max days.';
  }

  @override
  String get approvalGrantLifetime =>
      'The access lasts 15 minutes and only on that device.';

  @override
  String get approvalApproved => 'Approved. Go back to the app.';

  @override
  String get approvalDenied => 'Denied.';

  @override
  String get approvalNotPending => 'This request is no longer waiting.';

  @override
  String get approvalDeny => 'Deny';

  @override
  String get approvalApprove => 'Approve';

  @override
  String get approvalMissing => 'This request does not exist or has expired.';

  @override
  String get panelsTitle => 'Panels';

  @override
  String get panelMore => 'More';

  @override
  String get panelFiles => 'Files';

  @override
  String get panelGit => 'Git';

  @override
  String get panelTerminal => 'Terminal';

  @override
  String get panelTasks => 'Tasks';

  @override
  String get panelBrowser => 'Browser';

  @override
  String get panelContext => 'Context';

  @override
  String get panelCheckpoints => 'Checkpoints';

  @override
  String get panelOffline =>
      'Offline. This panel loads when the Gateway is reachable.';

  @override
  String get panelHostOffline => 'The host is offline.';

  @override
  String get panelFailed => 'This panel could not be loaded.';

  @override
  String get panelReadOnly => 'Read only: another device controls this work.';

  @override
  String get panelsOpen => 'Panels';

  @override
  String get filesRoot => 'Root';

  @override
  String get refresh => 'Refresh';

  @override
  String get filesEmpty => 'This folder is empty.';

  @override
  String get filesImageTooLarge => 'This image is too large to show.';

  @override
  String get filesBinary => 'This file is not text.';

  @override
  String get panelTruncated => 'Only the first part is shown.';

  @override
  String get gitNoDiff => 'No changes.';

  @override
  String get gitChanges => 'Changes';

  @override
  String get gitHistory => 'History';

  @override
  String get gitNoCommits => 'No commits yet.';

  @override
  String get gitClean => 'No changes.';

  @override
  String get gitNotRepo => 'This folder is not a Git repository.';

  @override
  String get gitDetached => 'No branch';

  @override
  String gitAheadBehind(String upstream, int ahead, int behind) {
    return '$upstream · $ahead ahead · $behind behind';
  }

  @override
  String get tasksEmpty => 'No background tasks or teammates.';

  @override
  String get tasksBackground => 'Background tasks';

  @override
  String get tasksTeam => 'Teammates';

  @override
  String get tasksStop => 'Stop';

  @override
  String get tasksNoOutput => 'No output yet.';

  @override
  String get contextEmpty => 'Send a message first to see its context.';

  @override
  String contextUsage(int used, int window) {
    return 'About $used of $window tokens';
  }

  @override
  String contextTokens(int count) {
    return 'About $count tokens';
  }

  @override
  String contextTools(int count) {
    return '$count tools';
  }

  @override
  String get terminalStarting => 'Starting…';

  @override
  String get terminalNew => 'New terminal';

  @override
  String get terminalsEmpty => 'No terminals.';

  @override
  String terminalExited(String code) {
    return 'Exited ($code)';
  }

  @override
  String get terminalClose => 'Close terminal';

  @override
  String get terminalReadOnly => 'Read only: take control to type here.';

  @override
  String get terminalIsolatedUnavailable =>
      'This Node cannot start an isolated work terminal. No command was started.';

  @override
  String terminalNotStarted(String reason) {
    return 'The terminal did not start ($reason).';
  }

  @override
  String get browserUnavailable => 'The browser is not available on this host.';

  @override
  String get browserEmpty => 'No browser is open for this work.';

  @override
  String get browserReturn => 'Return control';

  @override
  String get browserTake => 'Take control';

  @override
  String get browserStopRecording => 'Stop recording';

  @override
  String get browserRecord => 'Record';

  @override
  String get browserAgentWaiting => 'The agent waits for you.';

  @override
  String get browserNoFrame => 'Waiting for the page…';

  @override
  String get browserType => 'Type and press Enter';

  @override
  String get checkpointsEmpty => 'No checkpoints yet.';

  @override
  String get checkpointsOff => 'Checkpoints are off for this project.';

  @override
  String checkpointsFiles(int count, String coverage) {
    return '$count files · $coverage';
  }

  @override
  String get checkpointsPreview => 'Preview';

  @override
  String checkpointsPreviewBody(int bytes, int excluded) {
    return '$bytes bytes copied · $excluded left out';
  }

  @override
  String checkpointsJob(String state) {
    return 'Recovery: $state';
  }

  @override
  String get checkpointsPreviewAction => 'Preview';

  @override
  String get checkpointsRecover => 'Recover';

  @override
  String get checkpointsContinue => 'Continue in a new conversation';

  @override
  String get settingsGeneral => 'General';

  @override
  String get textSize => 'Text size';

  @override
  String get textSmall => 'Small';

  @override
  String get textDefault => 'Default';

  @override
  String get textLarge => 'Large';

  @override
  String get textLarger => 'Larger';

  @override
  String get startTab => 'When the app opens';

  @override
  String get settingsThisDevice => 'This device';

  @override
  String get thisDeviceWebHint =>
      'Leave empty to let the Gateway name it from the browser.';

  @override
  String get thisDeviceNameRule => 'A name must be 1 to 60 characters.';

  @override
  String get thisDeviceSaved => 'Device name saved.';

  @override
  String get settingsAccount => 'Account and this device';

  @override
  String get accountName => 'Account';

  @override
  String get accountGateway => 'Gateway';

  @override
  String get unpair => 'Unpair this device…';

  @override
  String get unpairTitle => 'Unpair this device?';

  @override
  String get unpairBody =>
      'The device token and the drafts on this device are removed. Pairing again needs a new link.';

  @override
  String get unpairConfirm => 'Unpair';

  @override
  String get settingsAbout => 'About';

  @override
  String get aboutApp => 'App version';

  @override
  String get aboutGateway => 'Gateway version';

  @override
  String get aboutLicences => 'Licences';

  @override
  String get settingsAi => 'AI';

  @override
  String get settingsProviders => 'Model providers and default model';

  @override
  String get settingsMemory => 'Memory';

  @override
  String get settingsModes => 'Modes';

  @override
  String get settingsNotificationsAndAccess => 'Notifications and access';

  @override
  String get settingsNotifications => 'Notifications';

  @override
  String get settingsCalendar => 'Calendar and agent access';

  @override
  String get accessProvidersReason =>
      'Changing model providers needs a short approval from a browser.';

  @override
  String get providersDefaultModel => 'Default model';

  @override
  String get providersList => 'Providers';

  @override
  String providersRow(String api, int count) {
    return '$api · $count models';
  }

  @override
  String get providersReplaceKey => 'Replace the API key';

  @override
  String get providersRemove => 'Remove';

  @override
  String get providersAdd => 'Add a provider';

  @override
  String get providersAccounts => 'Accounts';

  @override
  String get providersConnected => 'Signed in';

  @override
  String get providersNotConnected => 'Not signed in';

  @override
  String get providersSignOut => 'Sign out';

  @override
  String get providersSignIn => 'Sign in';

  @override
  String get providersApiKey => 'API key';

  @override
  String get providersPreset => 'Provider';

  @override
  String get providersId => 'Name on this Gateway';

  @override
  String providersModelsFound(int count) {
    return '$count models found';
  }

  @override
  String get providersFindModels => 'Find models';

  @override
  String providersSignInTo(String name) {
    return 'Sign in to $name';
  }

  @override
  String get providersConsent =>
      'I accept this provider\'s terms for use through pirc.';

  @override
  String get providersOpenAddress => 'Open this address and sign in:';

  @override
  String get providersSignedIn => 'Signed in.';

  @override
  String get memoryRestore => 'Restore';

  @override
  String get memoryForget => 'Forget';

  @override
  String get memoryProposals => 'Waiting for your answer';

  @override
  String get memoryReject => 'Reject';

  @override
  String get memoryApprove => 'Approve';

  @override
  String get memoryAboutYou => 'About you';

  @override
  String get memoryNone => 'Nothing yet.';

  @override
  String get memoryNotes => 'Notes';

  @override
  String get memoryRemoved => 'Removed';

  @override
  String get pushTargets => 'Where notifications go';

  @override
  String get pushNone => 'No device receives notifications yet.';

  @override
  String get pushFailing => 'Delivery is failing';

  @override
  String get pushSendTest => 'Send a test';

  @override
  String pushSent(int count) {
    return 'Sent to $count targets.';
  }

  @override
  String get notificationChecking =>
      'Reconnecting and checking the latest state';

  @override
  String get notificationHandled => 'This was already handled';

  @override
  String get notificationExpired => 'This question expired';

  @override
  String get notificationExpiredDetail => 'It can no longer be answered.';

  @override
  String get notificationOffline => 'Could not check the latest state';

  @override
  String notificationChoiceKept(String choice) {
    return 'Your choice is kept: $choice';
  }

  @override
  String get notificationOpenConversation => 'Open conversation';

  @override
  String get answerSheetTitle => 'Confirm your answer';

  @override
  String answerSheetCheckedHere(String time) {
    return 'From the notification · checked at $time: the question is still open, control on this device';
  }

  @override
  String answerSheetChecked(String time) {
    return 'From the notification · checked at $time: the question is still open';
  }

  @override
  String answerSheetControlledBy(String name) {
    return 'Controlled by $name. Take control to send.';
  }

  @override
  String get answerSheetTakeControl => 'Take control';

  @override
  String get answerSheetSend => 'Send answer';

  @override
  String get pushThisPhoneOn => 'This phone gets notifications';

  @override
  String get pushThisPhoneOff => 'This phone gets no notifications';

  @override
  String get pushConnecting => 'Connecting to the distributor…';

  @override
  String get pushSetupFailed => 'Push could not be set up';

  @override
  String pushLastDelivered(String time) {
    return 'last delivered $time';
  }

  @override
  String get pushThisDevice => 'This phone';

  @override
  String get pushOn => 'Push notifications';

  @override
  String get pushDistributor => 'Distributor';

  @override
  String get pushChooseDistributor => 'Choose';

  @override
  String get pushNoDistributor =>
      'No UnifiedPush distributor is installed. Install one, such as ntfy, then come back to turn push on.';

  @override
  String get pushConflict =>
      'These settings were changed elsewhere. The current values are shown; make your change again.';

  @override
  String get pushTargetGone =>
      'The Gateway no longer has this phone. Turn push off and on again.';

  @override
  String get pushCategories => 'Categories';

  @override
  String get pushCategoryNeedsYou => 'Needs you';

  @override
  String get pushCategoryNeedsYouNote =>
      'Questions, missed runs, model approvals, budget requests, handovers';

  @override
  String get pushCategoryDone => 'Done';

  @override
  String get pushCategoryDoneNote =>
      'Finished schedules, pot replies, what pots noticed';

  @override
  String get pushCategoryProgress => 'Progress';

  @override
  String get pushCategoryProgressNote => 'A pot opening work';

  @override
  String get pushCategoryCalendar => 'Calendar reminders';

  @override
  String get pushCategoryCalendarNote => 'Reminders of your events';

  @override
  String get pushLevelImmediate => 'At once';

  @override
  String get pushLevelDigest => 'Summary';

  @override
  String get pushLevelOff => 'Off';

  @override
  String get pushDigestAt => 'Summary time';

  @override
  String get pushDigestAtNote =>
      'Items set to Summary arrive together once a day.';

  @override
  String get pushQuietHours => 'Quiet hours';

  @override
  String get pushQuietHoursNote =>
      'Needs-you items arrive silently; done and progress wait for the summary when quiet hours end.';

  @override
  String get pushQuietStart => 'Starts';

  @override
  String get pushQuietEnd => 'Ends';

  @override
  String get pushLockScreen => 'Lock screen';

  @override
  String get pushLockScreenShows => 'Show';

  @override
  String get pushLockHidden => 'No content';

  @override
  String get pushLockTitle => 'Title only';

  @override
  String get pushLockFull => 'Everything';

  @override
  String get pushLockScreenNote =>
      'Android shows only the title when its lock screen setting hides sensitive notification content (Settings → Notifications → Notifications on lock screen). With that setting off, Android shows the whole notification; \"No content\" always hides it.';

  @override
  String pushTimeZone(String zone) {
    return 'Times are in $zone.';
  }

  @override
  String get pushPermissionTitle => 'Permission';

  @override
  String get pushPermissionGranted => 'pirc may show notifications';

  @override
  String get pushPermissionDenied =>
      'Android does not let pirc show notifications';

  @override
  String get pushPermissionAsk => 'Allow';

  @override
  String get pushChannelsNote =>
      'Sound, vibration and pop-ups are set per category in Android\'s notification settings.';

  @override
  String get pushOpenSystemSettings => 'Open system notification settings';

  @override
  String get pushStyle => 'Style';

  @override
  String get quickReplyOverlay => 'Quick reply over other apps';

  @override
  String get quickReplyOverlayNote =>
      'Shows the question and its choices over other apps, and checks the latest state before you can send. Needs \"Display over other apps\"; without it a normal notification is shown.';

  @override
  String get quickReplyOverlayWaiting =>
      'Off until \"Display over other apps\" is allowed.';

  @override
  String get calendarAllowRead => 'Agents may read the calendar';

  @override
  String get calendarAllowPropose => 'Agents may propose changes';

  @override
  String get calendarAllowProposeNote =>
      'Each change waits for your answer in the conversation.';

  @override
  String get modesNoWarnings =>
      'The Gateway does not report mode files or their warnings yet; see its log.';

  @override
  String get transitionTitle => 'Switching hosts';

  @override
  String get transitionCancelled =>
      'The switch was cancelled; the work stays where it was.';

  @override
  String get transitionStopping => 'Stopping work on the current host';

  @override
  String get transitionRevoking => 'Confirming its access is removed';

  @override
  String get transitionPreparing => 'Preparing the new host';

  @override
  String get transitionSwitched => 'Switched';

  @override
  String get transitionSourceOffline =>
      'The current host is offline. Nothing starts on the new host before it confirms.';

  @override
  String get transitionNeedsAck =>
      'Some access could not be proven removed. Review it to continue.';

  @override
  String get transitionNeedsAuthority =>
      'The permission to switch expired. Renew it to continue.';

  @override
  String get transitionUncertain =>
      'Not sure the last step arrived. Waiting for the host.';

  @override
  String get transitionPlanChanged =>
      'The plan changed. Preview the switch again.';

  @override
  String get transitionAcknowledge => 'Continue anyway';

  @override
  String get transitionReauthorize => 'Renew permission';

  @override
  String get transitionCancel => 'Cancel the switch';

  @override
  String get composerTransitioning => 'Switching hosts. Your draft is kept.';

  @override
  String get envFolders => 'Folders and their rights';

  @override
  String get envRead => 'Read';

  @override
  String get envWrite => 'Read and write';

  @override
  String get envDeny => 'No access';

  @override
  String get envRevoke => 'Remove';

  @override
  String get envAddFolder => 'Add a folder';

  @override
  String get envFolderPath => 'Folder path on the host';

  @override
  String get envSwitch => 'Switch host…';

  @override
  String get envSwitchTo => 'Switch to';

  @override
  String envPreviewTitle(String target) {
    return 'Switch to $target?';
  }

  @override
  String get envPreviewStops =>
      'Running work, terminals and the browser stop on the current host.';

  @override
  String get envPreviewStays =>
      'The conversation, its tasks and your drafts stay. Files are not copied.';

  @override
  String get envConfirm => 'Switch';

  @override
  String get envBlockedCrossNode =>
      'Moving to another host is not available yet.';

  @override
  String get envBlockedPendingWork => 'Work is still running here.';

  @override
  String get envBlockedNode => 'The host is offline or cannot do this.';

  @override
  String get envBlockedUnchanged => 'This is the current environment.';

  @override
  String get envBlockedResource =>
      'A folder or resource is missing on the target.';

  @override
  String get scopeOccurrence => 'This one';

  @override
  String get scopeFollowing => 'This and later ones';

  @override
  String get scopeSeries => 'The whole series';

  @override
  String get eventNew => 'New event';

  @override
  String get eventEdit => 'Edit';

  @override
  String get eventTitle => 'Title';

  @override
  String get eventAllDay => 'All day';

  @override
  String get eventStart => 'Starts (YYYY-MM-DD)';

  @override
  String get eventTime => 'Time (HH:mm)';

  @override
  String get eventEnd => 'Ends (YYYY-MM-DD)';

  @override
  String get eventRepeat => 'Repeat';

  @override
  String get repeatNone => 'Does not repeat';

  @override
  String get repeatDaily => 'Every day';

  @override
  String get repeatWeekly => 'Every week';

  @override
  String get repeatMonthly => 'Every month';

  @override
  String get repeatYearly => 'Every year';

  @override
  String get eventLocation => 'Place';

  @override
  String get eventNotes => 'Notes';

  @override
  String get taskNew => 'New agent task';

  @override
  String get taskEdit => 'Edit task';

  @override
  String get taskPrompt => 'What the agent does';

  @override
  String get taskPickTarget => 'Choose a project';

  @override
  String get taskRepeats => 'Repeats';

  @override
  String get taskCron => 'When (cron)';

  @override
  String get taskCronHelp => 'minute hour day month weekday, e.g. 0 9 * * 1-5';

  @override
  String get taskAt => 'When';

  @override
  String get calendarNew => 'New';

  @override
  String get calendarPrevious => 'Previous';

  @override
  String get calendarNext => 'Next';

  @override
  String get viewMonth => 'Month';

  @override
  String get viewWeek => 'Week';

  @override
  String get viewDay => 'Day';

  @override
  String get viewList => 'List';

  @override
  String get calendarToday => 'Today';

  @override
  String get taskMissed => 'Missed';

  @override
  String get taskMark => 'Agent task';

  @override
  String get taskPlanned => 'Planned';

  @override
  String get taskDone => 'Done';

  @override
  String get calendarItemGone =>
      'This item is not in the shown range any more.';

  @override
  String get eventDeleteTitle => 'Delete this event?';

  @override
  String get eventRepeats => 'Repeats';

  @override
  String get taskAllowRun => 'Run it now';

  @override
  String get taskDismiss => 'Dismiss';

  @override
  String get taskSkipAsk => 'Skip this missed run?';

  @override
  String get taskSkipAskNote =>
      'It will not run. The task runs again at its next time.';

  @override
  String get taskTargetGone =>
      'Paused: its project is gone. Edit it and pick a new one.';

  @override
  String get taskPaused => 'Paused';

  @override
  String get taskRunNow => 'Run now';

  @override
  String get taskResume => 'Resume';

  @override
  String get taskPause => 'Pause';

  @override
  String get legendEvent => 'Event';

  @override
  String calendarDayCount(String day, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items',
      one: '1 item',
    );
    return '$day · $_temp0';
  }

  @override
  String get projectRemove => 'Remove project…';

  @override
  String projectRemoveTitle(String name) {
    return 'Remove $name?';
  }

  @override
  String get projectRemoveBody =>
      'It leaves your lists and its agent tasks pause. Its folder, files and history stay on the host; adding the same folder again brings it back.';

  @override
  String get projectRemoveConfirm => 'Remove';

  @override
  String get projectRemoveOffline =>
      'The host is offline. Connect it so it can confirm the project is idle, then try again.';

  @override
  String get projectConversations => 'Conversations';

  @override
  String get projectResources => 'Resources';

  @override
  String get projectRules => 'Rules';

  @override
  String get capMemorySearch => 'Search memory';

  @override
  String get capRemoteRecall => 'Recall from other conversations';

  @override
  String get capSchedules => 'Create agent tasks';

  @override
  String get capWebSearch => 'Search the web';

  @override
  String get projectConfigChanged =>
      'The project config changed. Review it again before trusting it.';

  @override
  String get projectConfigInvalid => 'The project config is not valid.';

  @override
  String get projectConfigEmpty => 'This project has no config to trust.';

  @override
  String get projectTrusted => 'Trusted: its hooks and settings run.';

  @override
  String get projectNotTrusted =>
      'Not trusted: its hooks and settings do not run.';

  @override
  String get projectUntrust => 'Withdraw trust';

  @override
  String get projectTrust => 'Trust';

  @override
  String projectCreated(String name) {
    return '$name was added.';
  }

  @override
  String get projectNew => 'New project';

  @override
  String get projectHost => 'Host';

  @override
  String get projectName => 'Name';

  @override
  String get projectPath => 'Folder on the host';

  @override
  String get projectCreate => 'Add';

  @override
  String get browserRecordings => 'Recordings';

  @override
  String get browserRecordingLoad => 'Load';

  @override
  String get browserRecordingFailed => 'The recording could not be loaded.';

  @override
  String get browserRecordingOpen => 'Open in another app';

  @override
  String browserRecordingSize(String megabytes) {
    return '$megabytes MB';
  }

  @override
  String get browserRecordingPlay => 'Play in the app';

  @override
  String get recordingPlay => 'Play';

  @override
  String get recordingPause => 'Pause';

  @override
  String recordingPosition(String position, String duration) {
    return '$position of $duration';
  }

  @override
  String get recordingSpeed => 'Playback speed';

  @override
  String get recordingSave => 'Save to Downloads';

  @override
  String get recordingClose => 'Close the player';

  @override
  String recordingSaved(String name) {
    return 'Saved to Downloads as $name.';
  }

  @override
  String get recordingSaveFailed => 'The recording could not be saved.';

  @override
  String get recordingPlaybackFailed => 'The recording could not be played.';

  @override
  String get imageLabel => 'Image';

  @override
  String get imageUnreadable => 'This image cannot be shown.';

  @override
  String get statusCompleted => 'Completed';

  @override
  String get statusStopped => 'Stopped';

  @override
  String get statusTimedOut => 'Timed out';

  @override
  String get statusPending => 'Waiting';

  @override
  String get statusInProgress => 'In progress';

  @override
  String get jobPreparing => 'Preparing';

  @override
  String get jobReady => 'Ready';

  @override
  String get jobOpened => 'Opened';

  @override
  String get jobStale => 'Out of date';

  @override
  String get jobInterrupted => 'Interrupted';

  @override
  String get operationRecorded => 'Recorded';

  @override
  String get resultKindMarkdown => 'Document';

  @override
  String get resultKindCode => 'Code';

  @override
  String get resultKindTable => 'Table';

  @override
  String get timeZone => 'Time zone';

  @override
  String timeZoneDevice(String offset) {
    return 'This device\'s (UTC$offset)';
  }

  @override
  String timeZoneUtc(String offset) {
    return 'UTC$offset';
  }

  @override
  String get timeZoneNote =>
      'The calendar shows times and creates events and tasks in this time zone.';

  @override
  String get newPotTitle => 'New pot';

  @override
  String newPotStep(int step, String title) {
    return '$step / 4 · $title';
  }

  @override
  String get newPotStepLook => 'Look and personality';

  @override
  String get newPotStepWork => 'Work';

  @override
  String get newPotStepReach => 'What it can do';

  @override
  String get newPotStepModels => 'Models';

  @override
  String get newPotNext => 'Next';

  @override
  String newPotCreate(String name) {
    return 'Create $name';
  }

  @override
  String get newPotCreatePlain => 'Create';

  @override
  String get potThisPot => 'this pot';

  @override
  String get potAvatarColors => 'Avatar colour';

  @override
  String potAvatarColor(int n) {
    return 'Colour $n';
  }

  @override
  String get potAvatarUpload => 'Upload a picture';

  @override
  String get potAvatarNote =>
      'The avatar shows the name\'s first letter by default';

  @override
  String get potAvatarChoose => 'Choose another picture';

  @override
  String get potAvatarRemove => 'Remove the picture';

  @override
  String get potAvatarUploading => 'Uploading the picture…';

  @override
  String get potGroupBasic => 'Basic';

  @override
  String get potName => 'Name';

  @override
  String get potNameHint => 'What to call it';

  @override
  String get potGroupPersonality => 'Personality (soul)';

  @override
  String get potTemplateRigorous => 'Rigorous';

  @override
  String get potTemplateConcise => 'Concise';

  @override
  String get potTemplateFriendly => 'Friendly';

  @override
  String get potTemplateCustom => 'Custom';

  @override
  String get potTemplateRigorousText =>
      'Precise and careful. Checks facts before answering, says when unsure, and prefers correctness over speed.';

  @override
  String get potTemplateConciseText =>
      'Brief and direct. Answers in as few words as possible and skips pleasantries.';

  @override
  String get potTemplateFriendlyText =>
      'Warm and encouraging. Explains things plainly and checks that the user is comfortable with the next step.';

  @override
  String get potPersonalityHint => 'How it talks';

  @override
  String get potPersonalityNote =>
      'Personality only changes how it talks; it gives no permissions.';

  @override
  String get potGroupPreview => 'Speech preview';

  @override
  String get potPreviewRigorous =>
      'Found it: with the iPad\'s floating keyboard, viewInsets reports 0. Source: the Flutter MediaQuery docs.';

  @override
  String get potPreviewConcise => 'Floating keyboard: viewInsets is 0.';

  @override
  String get potPreviewFriendly =>
      'Good news, I found it! With the floating keyboard, viewInsets is 0. Shall I show you where that is in the docs?';

  @override
  String get potPreviewCustom =>
      'Here is what I found about viewInsets with the floating keyboard.';

  @override
  String get potPreviewNote => 'Preview, not a real reply';

  @override
  String get potGroupIntro => 'Intro';

  @override
  String get potIntroHint => 'One line about what it does';

  @override
  String get potIntroNote =>
      'Shown in the chat list and the @ menu, so you and other pots know whom to ask.';

  @override
  String get potGroupDescription => 'Work description';

  @override
  String get potDescriptionHint => 'How it should work';

  @override
  String get potDescriptionNote =>
      'Tells it how to work. Like the personality, nothing here gives it permissions.';

  @override
  String get potGroupResponsibilities => 'Responsibilities';

  @override
  String get potAddResponsibility => 'Add a responsibility';

  @override
  String get potResponsibilityNew => 'New responsibility';

  @override
  String get potResponsibilityEdit => 'Responsibility';

  @override
  String get potResponsibilityTitle => 'Title';

  @override
  String get potResponsibilityDetail => 'Detail (optional)';

  @override
  String get potMoveUp => 'Move up';

  @override
  String get potMoveDown => 'Move down';

  @override
  String get potRemove => 'Remove';

  @override
  String potTooLong(int max) {
    return 'At most $max characters';
  }

  @override
  String get potNameMissing => 'Give it a name';

  @override
  String get potGroupReach => 'How far it can go';

  @override
  String get potReachAnswer => 'Only answer you';

  @override
  String get potReachAnswerDetail =>
      'Doesn\'t watch anything and can\'t start work';

  @override
  String get potReachObserve => 'Watch and suggest';

  @override
  String get potReachObserveDetail =>
      'Watches only what you allow; you decide on its suggestions';

  @override
  String get potReachWork => 'Can start work';

  @override
  String potReachWorkDetail(String name) {
    return 'Opens work where you allow; each work is marked From $name and uses its budget';
  }

  @override
  String get potGroupObserve => 'What it can see';

  @override
  String get potObserveCalendar => 'Calendar';

  @override
  String get potObserveCalendarDetail => 'Your calendar\'s events';

  @override
  String get potObserveSchedules => 'Schedules';

  @override
  String get potObserveSchedulesDetail => 'Scheduled runs and their results';

  @override
  String get potObserveWorkspace => 'Project';

  @override
  String get potObserveProject => 'Chat project';

  @override
  String get potObserveSession => 'Work';

  @override
  String get potObserveWorkspaces => 'Projects';

  @override
  String get potObserveProjects => 'Chat projects';

  @override
  String get potObserveSessions => 'Works';

  @override
  String get potObserveAdd => 'Add a project or work';

  @override
  String get potObserveNothing => 'Nothing more to add.';

  @override
  String get potObserveOff =>
      'Only answering, it watches nothing. Choose “Watch and suggest” to let it see more.';

  @override
  String get potGroupDmSend => 'Message other pots';

  @override
  String get potGroupDmReceive => 'Messages from other pots';

  @override
  String get potDmAll => 'All pots';

  @override
  String get potDmSelected => 'Selected';

  @override
  String get potDmOff => 'Off';

  @override
  String get potDmNoPots => 'There are no other pots yet.';

  @override
  String potDmNote(String name) {
    return 'Messages are kept in Activity, where you can read them all. When off, $name and other pots talk only in groups.';
  }

  @override
  String potDmOffNote(String name) {
    return '$name won\'t message other pots; group conversations are not affected.';
  }

  @override
  String get potGroupWork => 'Work';

  @override
  String get potWorkLocationAdd => 'Add a place to open work';

  @override
  String get potWorkLocationsNone => 'No project to add.';

  @override
  String get potAccessRead => 'Read only';

  @override
  String get potAccessWrite => 'Read and write';

  @override
  String potAccessLabel(String access) {
    return 'Access: $access';
  }

  @override
  String potRemoveNamed(String name) {
    return 'Remove $name';
  }

  @override
  String get potMaxWorks => 'Works at the same time';

  @override
  String potMaxWorksValue(int count) {
    return 'At most $count';
  }

  @override
  String get potFewer => 'Fewer';

  @override
  String get potMore => 'More';

  @override
  String potWorkNote(String name) {
    return 'Each work it opens is marked “From $name”; you can take it over at any time.';
  }

  @override
  String get potGroupBudget => 'Budget';

  @override
  String get potBudgetMoney => 'Money per month';

  @override
  String get potBudgetTokens => 'Tokens per day';

  @override
  String get potBudgetDollars => 'US\$';

  @override
  String get potBudgetTokenUnit => 'tokens';

  @override
  String get potBudgetInvalid => 'Enter a number above 0';

  @override
  String get potBudgetNote =>
      'It and the work it opens all count. When a limit is used up it stops opening work and tells you. The token limit always applies: subscription use counts in money only when “Show API-equivalent price” is on.';

  @override
  String get potGroupReview => 'Reviews its own work';

  @override
  String get potReviewOff => 'Off';

  @override
  String get potReviewDay => '1 day';

  @override
  String get potReviewTwoDays => '2 days';

  @override
  String get potReviewWeek => '1 week';

  @override
  String get potReviewNote =>
      'How often it looks back over its responsibilities and work by itself.';

  @override
  String potReachNote(String name) {
    return 'You can change all of this later in $name\'s settings. Smaller permissions apply at once; running work is checked again against them.';
  }

  @override
  String potGroupOwnModels(String name) {
    return 'Models $name uses';
  }

  @override
  String get potMainModel => 'Main model';

  @override
  String potFallback(int n) {
    return 'Fallback $n';
  }

  @override
  String get potAddFallback => 'Add a fallback';

  @override
  String get potRemoveFallback => 'Remove this fallback';

  @override
  String get potModelsNote =>
      'When the main model can\'t be used (budget used up, service down, host offline), the fallbacks are used in order; each switch is logged in Activity, and it switches back when the main model returns.';

  @override
  String get potNoModels => 'The Gateway serves no models yet.';

  @override
  String get potModelsLoading => 'Loading the models…';

  @override
  String get potPickModel => 'Choose a model';

  @override
  String get potGroupThinking => 'Thinking';

  @override
  String get potThinkingNone => 'This model has no thinking levels';

  @override
  String get potThinkingAuto => 'Adjust by itself';

  @override
  String get potThinkingAutoDetail =>
      'Uses the level above, raising or lowering it when needed';

  @override
  String potThinkingAutoOn(String level) {
    return 'Usually “$level”. It raises or lowers it by itself when needed, without asking you; each change is logged in Activity with the reason.';
  }

  @override
  String potThinkingAutoOff(String level) {
    return 'Always “$level”; it doesn\'t change it by itself.';
  }

  @override
  String get potGroupWorkModels => 'Models for work';

  @override
  String get potModeDirect => 'Direct';

  @override
  String get potModeAsk => 'Ask you';

  @override
  String potModeLabel(String mode) {
    return 'Use: $mode';
  }

  @override
  String potWorkModelsNote(String name) {
    return 'To use a stronger model, $name opens a work, picks the model and talks to it; that work is marked From $name. Models set to “Ask you” wait for your approval before the work opens.';
  }

  @override
  String potWorkModelsOff(String reach, String name) {
    return 'In the last step you chose “$reach”, so $name can\'t open work and can\'t use other models. To let it use a stronger model, go back and choose “Can start work”.';
  }

  @override
  String get potHeaderAnswer => 'Only answers you';

  @override
  String get potHeaderObserve => 'Observing';

  @override
  String get potHeaderWork => 'Can open work';

  @override
  String potBudgetMonthUsed(String used, String limit) {
    return 'This month $used / $limit';
  }

  @override
  String potBudgetDayUsed(String used, String limit) {
    return 'Today $used / $limit tokens';
  }

  @override
  String potProfileOf(String name) {
    return '$name\'s profile';
  }

  @override
  String threadDayToday(String time) {
    return 'Today $time';
  }

  @override
  String threadDayYesterday(String time) {
    return 'Yesterday $time';
  }

  @override
  String threadComposerHint(String name) {
    return 'Message $name…';
  }

  @override
  String threadReadOnlyDeleted(String name) {
    return '$name was deleted. This conversation is read-only.';
  }

  @override
  String threadReadOnlyArchived(String name) {
    return '$name is archived. This conversation is read-only.';
  }

  @override
  String threadRefused(String name, String reason) {
    return '$name was not woken: $reason';
  }

  @override
  String get threadFailed => 'The conversation could not be loaded.';

  @override
  String get cardReview => 'Review';

  @override
  String get cardFailed => 'This item could not be loaded.';

  @override
  String cardUnknown(String kind) {
    return 'This version of the app can\'t show this item ($kind).';
  }

  @override
  String cardWorkCoordinatedBy(String name) {
    return 'Coordinated by $name';
  }

  @override
  String get cardWorkTakenOver => 'You took it over';

  @override
  String get cardWorkMissing => 'This work is no longer available';

  @override
  String cardHandoverTitle(String pot) {
    return '$pot proposes a handover';
  }

  @override
  String cardHandoverTo(String to) {
    return 'To $to';
  }

  @override
  String get cardHandoverApplied => 'Handover confirmed';

  @override
  String get cardHandoverRejected => 'Handover rejected';

  @override
  String get cardLoopTitle => 'Chain paused';

  @override
  String cardLoopBody(String pot, int wakes, int messages) {
    return '$pot started it. Since the last progress: $wakes wakes and $messages messages.';
  }

  @override
  String cardLoopLastProgress(String time) {
    return 'Last progress $time';
  }

  @override
  String get cardLoopResume => 'Resume';

  @override
  String get cardLoopStop => 'Stop the chain';

  @override
  String get cardLoopPause => 'Pause the pots involved';

  @override
  String get cardLoopStopConfirm =>
      'Stop this chain? Its waiting messages are dropped, and it can\'t be resumed.';

  @override
  String get cardLoopResumed => 'Resumed';

  @override
  String get cardLoopStopped => 'Chain stopped';

  @override
  String get cardLoopPotsPaused => 'The pots involved are paused';

  @override
  String get potActionMessage => 'Message';

  @override
  String get potActionPause => 'Pause';

  @override
  String get potActionResume => 'Resume';

  @override
  String get potActionHandOver => 'Hand over';

  @override
  String get potActionActivity => 'Activity';

  @override
  String potHostsGroups(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Hosts $count groups',
      one: 'Hosts 1 group',
    );
    return '$_temp0';
  }

  @override
  String get potPausedBannerTitle => 'Paused.';

  @override
  String get potPausedBannerText =>
      'It does not observe, suggest or start new work; its responsibilities and follow-ups stay.';

  @override
  String get potProfileNoResponsibilities => 'No responsibilities yet.';

  @override
  String get potProfileMayDo => 'What it may do';

  @override
  String get potProfileObserveNothing => 'Nothing yet';

  @override
  String get potProfileWorkPlaces => 'Where it opens work';

  @override
  String get potProfileNoPlaces => 'Nowhere yet';

  @override
  String potProfilePlace(String name, String access) {
    return '$name ($access)';
  }

  @override
  String potProfileMoneyMonth(String amount) {
    return '$amount a month';
  }

  @override
  String potProfileTokensDay(String count) {
    return '$count tokens a day';
  }

  @override
  String potProfileReviewDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Every $count days',
      one: 'Every day',
    );
    return '$_temp0';
  }

  @override
  String get potProfileReviewWeekly => 'Every week';

  @override
  String get potListSeparator => ', ';

  @override
  String get potProfileActivity => 'Recent activity';

  @override
  String get potProfileSeeAll => 'See all';

  @override
  String get potProfileNoActivity => 'Nothing yet.';

  @override
  String get potProfileMemory => 'Memory';

  @override
  String get potProfileForget => 'Forget';

  @override
  String get potProfileNoMemory => 'No notes yet.';

  @override
  String potProfileMemoryNote(String name, String used, String budget) {
    return 'Notes $name keeps for itself; only it reads them. $used of $budget characters used.';
  }

  @override
  String get activityToYou => 'You';

  @override
  String potPauseTitle(String name) {
    return 'Pause $name?';
  }

  @override
  String get potPauseWhile => 'While paused';

  @override
  String get potPauseNoDelivery => 'No new messages or events reach it';

  @override
  String get potPauseNoDeliveryDetail =>
      'They wait and arrive when you resume it';

  @override
  String get potPauseWait => 'Its reviews and reminders wait';

  @override
  String get potPauseNoWork => 'It starts no work';

  @override
  String get potPauseGoesOn => 'Goes on';

  @override
  String get potPauseWorks => 'Works it already opened keep running';

  @override
  String get potPauseWorksDetail =>
      'Each follows its own controls; to stop one, stop it in that work';

  @override
  String get potPauseThreads => 'Its conversations stay readable';

  @override
  String get potPauseNothingMoves => 'Nothing is handed over';

  @override
  String get potPauseNothingMovesDetail =>
      'Its responsibilities, permissions and memory stay; to give them away, hand over or archive';

  @override
  String potSettingsTitle(String name) {
    return '$name\'s settings';
  }

  @override
  String get potSettingsSubtitle => 'Saved section by section';

  @override
  String get potSettingsSave => 'Save';

  @override
  String get potSettingsSaved => 'Saved';

  @override
  String potSettingsConflict(String name) {
    return '$name was changed elsewhere and is read again. Your edit is kept; save again to use it.';
  }

  @override
  String get potSettingsOther => 'Other';

  @override
  String get potSettingsPause => 'Pause…';

  @override
  String get potSettingsResume => 'Resume';

  @override
  String get potSettingsHandOver => 'Hand over…';

  @override
  String get potSettingsRetire => 'Archive or delete…';

  @override
  String get activityKindDm => 'Message';

  @override
  String get activityKindGroupMessage => 'Group';

  @override
  String get activityKindAssign => 'Handed over';

  @override
  String get activityKindWorkOpened => 'Opened work';

  @override
  String get activityKindWorkInstruction => 'Instruction';

  @override
  String get activityKindFileRead => 'Read';

  @override
  String get activityKindThinkingAdjust => 'Auto-adjusted';

  @override
  String get activityKindFallback => 'Fallback';

  @override
  String get activityKindAwaitingConfirm => 'Needs your OK';

  @override
  String get activityKindAwaitingApproval => 'Needs approval';

  @override
  String get activityKindApprovalAnswered => 'Approval answered';

  @override
  String get activityKindForwardedToUser => 'To you';

  @override
  String get activityKindBudgetRequest => 'Budget request';

  @override
  String get activityKindBudgetExhausted => 'Out of budget';

  @override
  String get activityKindLoopGuard => 'Chain paused';

  @override
  String get activityKindHandoverProposed => 'Proposed handover';

  @override
  String get activityKindReview => 'Review';

  @override
  String get activityKindReminderSet => 'Reminder';

  @override
  String get activityKindAutonomyChanged => 'Autonomy';

  @override
  String get activityKindStatus => 'Status';

  @override
  String get potProfileArchived => 'Archived';

  @override
  String get handoverKindResponsibility => 'Duty';

  @override
  String get handoverKindReminder => 'Follow-up';

  @override
  String get handoverKindWork => 'Work';

  @override
  String get handoverKindGroupHost => 'Host';

  @override
  String get handoverToLabel => 'To';

  @override
  String get handoverMeAvatar => 'Me';

  @override
  String get handoverNoOne => 'No one';

  @override
  String get handoverFitOk => 'Enough permissions';

  @override
  String get handoverFitOkYou =>
      'You manage it yourself, as when you take work over';

  @override
  String handoverNeedsReach(String reach, String name) {
    return 'Needs: “$reach”, as $name has';
  }

  @override
  String handoverWillDo(String text) {
    return 'Will do: $text';
  }

  @override
  String get handoverNeedsNothing => 'Needs: nothing more';

  @override
  String get handoverReminderDoes => 'Will do: remind at the time that was set';

  @override
  String get handoverNeedsWork => 'Needs: may open work where this work runs';

  @override
  String handoverWorkDoes(String name) {
    return 'Will do: coordinate this work; its record still says From $name';
  }

  @override
  String get handoverNeedsMember => 'Needs: to be in the group';

  @override
  String get handoverHostDoes =>
      'Will do: answer messages without an @ and decide who takes them';

  @override
  String handoverGroupPots(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count people',
      one: '1 person',
    );
    return '$_temp0';
  }

  @override
  String handoverAdjust(String name) {
    return 'Adjust $name\'s permissions…';
  }

  @override
  String get handoverCheckLabel => 'Hand over this item';

  @override
  String get handoverTitle => 'Hand over';

  @override
  String handoverRoute(String from, String to) {
    return '$from → $to';
  }

  @override
  String get handoverWho => 'To whom';

  @override
  String get handoverItems => 'What to hand over';

  @override
  String handoverNote(String name) {
    return 'After the handover $name no longer does these; you can hand them back later. Both conversations and the activity record it. A pot\'s own proposal also needs your OK.';
  }

  @override
  String handoverProposedTitle(String name) {
    return '$name proposes a handover.';
  }

  @override
  String handoverProposedText(String items, String to) {
    return 'It wants to give $items to $to; nothing changes until you confirm.';
  }

  @override
  String handoverQuoted(String text) {
    return '“$text”';
  }

  @override
  String get handoverNext => 'Next';

  @override
  String handoverConfirm(int count, String name) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items',
      one: '1 item',
    );
    return 'Hand over $_temp0 to $name';
  }

  @override
  String get handoverReject => 'Reject';

  @override
  String handoverNothingFits(String name) {
    return 'None of these can go to $name; reject it or choose again.';
  }

  @override
  String get handoverApplied => 'Handed over.';

  @override
  String get handoverRejected => 'Rejected; nothing was handed over.';

  @override
  String handoverTokensLeft(String tokens) {
    return '$tokens tokens left today';
  }

  @override
  String get handoverYouSub => 'Works come to you; other items stop';

  @override
  String handoverEmpty(String name) {
    return '$name holds nothing to hand over.';
  }

  @override
  String retireTitle(String name) {
    return 'Remove $name';
  }

  @override
  String get retireSubtitle => 'First choose who takes what';

  @override
  String get retireArchive => 'Archive';

  @override
  String get retireDelete => 'Delete';

  @override
  String get retireArchiveNote =>
      'Archive: it stops and keeps its personality and memory; you can restore it later.';

  @override
  String get retireDeleteNote =>
      'Delete: its personality, memory and settings are removed; this can\'t be undone.';

  @override
  String retireItems(int count) {
    return 'Can hand over · $count';
  }

  @override
  String get retireItemsNote =>
      'Tap an item for details. A handover moves items, not permissions.';

  @override
  String get retireGiveAll => 'Give everything to…';

  @override
  String get retireStops => 'Will stop';

  @override
  String get retireKept => 'Kept';

  @override
  String retireArchiveButton(String name) {
    return 'Hand over and archive $name';
  }

  @override
  String retireDeleteButton(String name) {
    return 'Hand over and delete $name';
  }

  @override
  String retirePickTitle(String item) {
    return 'Who takes $item?';
  }

  @override
  String get retirePickSub =>
      'The receiver uses only its own permissions; when they aren\'t enough the item narrows. No permission is added.';

  @override
  String get retirePickAllTitle => 'Give everything to whom?';

  @override
  String get retirePickAllSub =>
      'Every item goes to the same one; you can still change each item after.';

  @override
  String get retirePickAllFits => 'Every item fits';

  @override
  String retirePickAllMisfits(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items don\'t fully fit',
      one: '1 item doesn\'t fully fit',
    );
    return '$_temp0';
  }

  @override
  String retireDeleteTitle(String name) {
    return 'Delete $name?';
  }

  @override
  String retireDeleteBody(String name) {
    return 'Its personality, memory and settings are removed for good; its conversations stay, read-only. Type $name to confirm.';
  }

  @override
  String get retireDeleteField => 'Pot name';

  @override
  String groupNewCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count pots selected',
      one: '1 pot selected',
      zero: 'No pots selected',
    );
    return '$_temp0';
  }

  @override
  String get groupAvatarFaces => 'Members\' faces';

  @override
  String get groupAvatarNote =>
      'Members\' faces by default; you can also pick a colour or upload a picture';

  @override
  String get groupName => 'Name';

  @override
  String get groupNameHint => 'Group name';

  @override
  String get groupMembers => 'Members';

  @override
  String get groupHost => 'Host';

  @override
  String get groupHostNote =>
      'Without an @, the host answers and decides who to hand things to. The host gets no other member\'s permissions.';

  @override
  String get groupHostPickFirst =>
      'Tick the members first, then choose the host.';

  @override
  String get groupCreate => 'Create';

  @override
  String get groupNameMissing => 'Give the group a name';

  @override
  String get groupMemberRule => 'A group has 2 to 16 pots';

  @override
  String get groupHostMissing => 'Choose a host among the members';

  @override
  String get groupHostTag => 'Host';

  @override
  String groupMemberHost(String name) {
    return '$name (host)';
  }

  @override
  String groupComposerHint(String host) {
    return 'Without @, $host answers…';
  }

  @override
  String get groupComposerHintNoHost => 'Message the group…';

  @override
  String groupComposerTo(String names) {
    return 'To $names…';
  }

  @override
  String get groupTargetTo => 'To';

  @override
  String groupTargetRemove(String name) {
    return 'Don\'t send to $name';
  }

  @override
  String get groupMention => '@ a member';

  @override
  String get groupMentionLabel => 'Choose who to @';

  @override
  String get groupMentionHeader =>
      'Who is it for? Each uses only its own permissions and budget';

  @override
  String get groupMentionAll => 'Everyone';

  @override
  String get groupMentionAllWarning =>
      'Every member will be woken and reply, each on its own budget';

  @override
  String get groupInfo => 'Group info';

  @override
  String get groupEditLook => 'Change name and avatar';

  @override
  String groupMembersCount(int count) {
    return 'Members · $count';
  }

  @override
  String get groupYouDetail => 'Creator · can change the members and the host';

  @override
  String get groupEditMembers => 'Add or remove members';

  @override
  String get groupPermissionsNote =>
      'Permissions don\'t merge in a group. When the host hands something to another member, that member uses only its own permissions.';

  @override
  String get groupNoHost => 'No host';

  @override
  String get groupHostStays =>
      'The host stays a member; choose another host first';

  @override
  String get groupDelete => 'Delete group…';

  @override
  String get groupDeleteNote =>
      'Deleting the group deletes neither its members nor the works they opened.';

  @override
  String groupDeleteTitle(String name) {
    return 'Delete $name?';
  }

  @override
  String get groupDeleteBody =>
      'Its messages are deleted for good. The member pots and their works stay.';

  @override
  String get groupConflict =>
      'The group changed on another device. Your edit is kept; check it and save again.';

  @override
  String get groupGone => 'This group was deleted.';

  @override
  String get settingsPots => 'Pots';

  @override
  String settingsPotsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count pots',
      one: '1 pot',
    );
    return '$_temp0';
  }

  @override
  String settingsPotsMonth(String used, String cap) {
    return 'this month $used / $cap';
  }

  @override
  String settingsPotsMonthNoCap(String used) {
    return 'this month $used';
  }

  @override
  String get potsPageSubtitle => 'Tap one to open its settings';

  @override
  String get potsTotals => 'All pots together';

  @override
  String get potsTotalMonth => 'This month';

  @override
  String get potsTotalToday => 'Tokens today';

  @override
  String potsTotalNoCap(String used) {
    return '$used · no limit';
  }

  @override
  String get potsCaps => 'Total limits';

  @override
  String potsCapsBoth(String money, String tokens) {
    return '$money/month · $tokens/day';
  }

  @override
  String potsCapsMoney(String money) {
    return '$money/month';
  }

  @override
  String potsCapsTokens(String tokens) {
    return '$tokens tokens/day';
  }

  @override
  String get potsNoLimit => 'No limit';

  @override
  String get potsCapsMonth => 'A month';

  @override
  String get potsCapsDay => 'A day';

  @override
  String get potsCapsUsd => 'USD';

  @override
  String get potsCapsTokensUnit => 'tokens';

  @override
  String get potsCapsSheetNote =>
      '0 means no total limit. Subscription use counts toward money only when \"Show API-equivalent price\" is on.';

  @override
  String get potsCapsMoneyInvalid =>
      'Enter an amount of 0 or more, such as 50 or 12.5.';

  @override
  String get potsCapsTokensInvalid =>
      'Enter a whole number of tokens, 0 or more.';

  @override
  String get potsExhausted => 'When used up';

  @override
  String get potsExhaustedAsk => 'Stop and tell you';

  @override
  String get potsExhaustedAskDetail =>
      'A pot\'s next model request is refused, and you are told.';

  @override
  String get potsExhaustedPause => 'Pause all pots';

  @override
  String get potsExhaustedPauseDetail =>
      'Messages and events wait until the limit starts over.';

  @override
  String get potsRetention => 'Activity kept';

  @override
  String potsRetentionDays(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days days',
      one: '1 day',
    );
    return '$_temp0';
  }

  @override
  String get potsRetentionUnit => 'days';

  @override
  String get potsRetentionNote =>
      '1 to 3650 days. Older activity, and the names of deleted pots, are removed.';

  @override
  String get potsRetentionInvalid => 'Enter a number of days from 1 to 3650.';

  @override
  String get potsApiEquivalent => 'Show API-equivalent price';

  @override
  String get potsApiEquivalentDetail =>
      'Subscription use counts toward money limits at API prices, marked as an estimate.';

  @override
  String get potsCapsNote =>
      'Each pot also has its own limits; whichever is reached first applies.';

  @override
  String get potsSettingsConflict =>
      'The settings changed on another device and are read again. Your edit is kept; save again to use it.';

  @override
  String get potsNone => 'No pots yet.';

  @override
  String potsThinkingAuto(String level) {
    return '$level (auto)';
  }

  @override
  String get potsArchived => 'Archived';

  @override
  String potsArchivedOn(String date) {
    return 'Archived $date';
  }

  @override
  String get potsRestore => 'Restore…';

  @override
  String potsRestoreTitle(String name) {
    return 'Restore $name?';
  }

  @override
  String potsRestoreBody(String name) {
    return '$name comes back paused, with its settings and conversation. Resume it from its profile.';
  }

  @override
  String get potsRestoreConfirm => 'Restore';

  @override
  String potsRestoreConflict(String name) {
    return '$name changed elsewhere and was read again. Try again.';
  }

  @override
  String get meEdit => 'Edit';

  @override
  String get meOverview => 'Overview';

  @override
  String get meStatTotal => 'Tokens in total';

  @override
  String get meStatTopDay => 'Most tokens in a day';

  @override
  String get meStatSpent => 'Spent this month';

  @override
  String get meStatRequests => 'Requests this month';

  @override
  String get meStatLongestStreak => 'Longest streak';

  @override
  String get meStatStreak => 'Current streak';

  @override
  String meDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count days',
      one: '1 day',
    );
    return '$_temp0';
  }

  @override
  String get meStatsNote =>
      'Includes you and all pots; costs follow each provider\'s prices.';

  @override
  String meEstimate(String amount) {
    return 'Subscription use this month at API prices: about $amount. This is an estimate, not money spent.';
  }

  @override
  String get meActivity => 'Token activity';

  @override
  String get meDaily => 'Each day';

  @override
  String get meWeekly => 'Each week';

  @override
  String get meCumulative => 'Running total';

  @override
  String get meTabDay => 'Day';

  @override
  String get meTabWeek => 'Week';

  @override
  String get meTabTotal => 'Total';

  @override
  String get meLess => 'Less';

  @override
  String get meMore => 'More';

  @override
  String meHeatmapLabel(int weeks) {
    return 'Tokens per day, last $weeks weeks';
  }

  @override
  String get meWeeksLabel => 'Tokens per week, last 12 weeks';

  @override
  String get meTotalLabel => 'Running total of tokens';

  @override
  String get meTwelveWeeksAgo => '12 weeks ago';

  @override
  String meThisWeek(String value) {
    return 'This week $value';
  }

  @override
  String meNow(String value) {
    return 'Now $value';
  }

  @override
  String meDayTip(String date, String tokens) {
    return '$date · $tokens tokens';
  }

  @override
  String meDayTipNone(String date) {
    return '$date · no use';
  }

  @override
  String get meByWho => 'Who used how much this month';

  @override
  String get meByModel => 'Models used this month';

  @override
  String meYou(String name) {
    return '$name (you)';
  }

  @override
  String get meDeletedPot => 'Deleted pot';

  @override
  String get meNothingThisMonth => 'Nothing used this month yet.';

  @override
  String get meOnlyYou => 'Only you can see this.';

  @override
  String meDrawerMonth(String amount) {
    return 'This month $amount';
  }

  @override
  String meDrawerStreak(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count-day streak',
      one: '1-day streak',
    );
    return '$_temp0';
  }

  @override
  String get meOpen => 'You and usage';

  @override
  String get meEditTitle => 'Edit profile';

  @override
  String get meName => 'Name';

  @override
  String get meNameHint => 'Your name';

  @override
  String get meNameNote =>
      'Pots call you by this name; groups and Activity show it too.';

  @override
  String get meNameInvalid => 'A name is 1 to 60 characters.';

  @override
  String get meConflict =>
      'Your profile changed on another device and is read again. Your edit is kept; save again to use it.';

  @override
  String get activitySubtitle => 'What pots are doing';

  @override
  String get activityFilterKind => 'Filter by type';

  @override
  String get activityFilterPots => 'Filter by pot';

  @override
  String get activityAllKinds => 'All types';

  @override
  String activitySeePov(String name) {
    return 'See $name\'s point of view';
  }

  @override
  String get activitySeePovDetail =>
      'Browse its record through the chat list it sees · read only';

  @override
  String get activityFootnote =>
      'Messages between pots, instructions sent to work and files read are all recorded here; there is no channel you can\'t see.';

  @override
  String get activityEmptyFilter => 'Nothing matches this filter.';

  @override
  String get activityNoticed => 'Noticed';

  @override
  String get activityMarkRead => 'Mark read';

  @override
  String get activityNoticeOpen => 'New';

  @override
  String get activityNoticeSeen => 'Seen';

  @override
  String activityNoticedMerged(int count) {
    return '$count pots';
  }

  @override
  String get activityConditionRunFinished => 'A work finished its run';

  @override
  String get activityConditionWaitingInput => 'A work is waiting for you';

  @override
  String get activityConditionStartingSoon => 'Starting soon';

  @override
  String get activityConditionRunFailed => 'A work\'s run failed';

  @override
  String povTitle(String name) {
    return '$name\'s point of view';
  }

  @override
  String get povSubtitle => 'Read only · the chat list it sees';

  @override
  String povNote(String name) {
    return 'This is what $name sees, including the messages it sends into work. You can\'t send messages as it here.';
  }

  @override
  String povThreadNote(String name) {
    return 'As $name · on the right is what it sent';
  }

  @override
  String get povWorks => 'Works I coordinate';

  @override
  String get povSent => 'Messages it sent';

  @override
  String get povShowOlder => 'Show older';

  @override
  String get povNoThreads => 'It is in no conversation yet.';

  @override
  String get povYou => 'You (user)';

  @override
  String get povAuthorMe => 'Me';

  @override
  String povMe(String name) {
    return 'Me ($name)';
  }

  @override
  String get povWorkLabel => 'Work';

  @override
  String povReadOnly(String name) {
    return 'Read only: $name\'s record';
  }

  @override
  String get povGoToWork => 'Go to work';

  @override
  String get povBackToActivity => 'Back to activity';

  @override
  String get povDmSubtitle =>
      'Message · you can see every message between pots';

  @override
  String get povDirectSubtitle => 'Its conversation with you';

  @override
  String get povNoInstructions =>
      'It has sent no instructions into this work yet.';

  @override
  String get povDelivered => 'Delivered';

  @override
  String get povRefused => 'Refused';

  @override
  String get povUncertain => 'Not confirmed';

  @override
  String get pairScan => 'Scan QR code';

  @override
  String get pairScanFailed =>
      'The scanner could not be opened. Try again, or paste the link.';

  @override
  String get pairScanDownloading =>
      'The scanner is still being installed. Try again in a moment.';

  @override
  String get pairScanUnsupported =>
      'This device cannot scan QR codes. Paste the link instead.';

  @override
  String get pairNotACode => 'This QR code is not a pairing link.';

  @override
  String get pairNotACodeV2 =>
      'This QR code is not a pairing link or a Gateway address.';

  @override
  String pairLinkOpened(String gateway) {
    return 'A pairing link for $gateway was opened. Tap Pair to use it.';
  }

  @override
  String get pairExpired => 'Pairing expired; your settings are kept.';

  @override
  String get pairV2Title => 'Pair with a browser';

  @override
  String get pairV2Body =>
      'Give the Gateway address, typed or from a QR code. You approve this device in a browser that is signed in to the Gateway.';

  @override
  String get pairV2AddressLabel => 'Gateway address';

  @override
  String get pairV2DefaultName => 'Android phone';

  @override
  String get pairV2Start => 'Continue';

  @override
  String get pairV2Creating => 'Asking the Gateway…';

  @override
  String get pairV2NotAnAddress =>
      'This is not a Gateway address, such as https://pirc.example.';

  @override
  String get pairV2BadName => 'Give a device name of 1 to 100 characters.';

  @override
  String pairV2Device(String name) {
    return 'This device: $name';
  }

  @override
  String get pairV2OpenInBrowser => 'Open in a browser to approve';

  @override
  String get pairV2OpenBrowser => 'Open the browser';

  @override
  String get pairV2BrowserFailed =>
      'The browser could not be opened. Open this address yourself:';

  @override
  String pairV2Expires(String time) {
    return 'The request ends at $time.';
  }

  @override
  String get pairV2Waiting => 'Waiting for the approval in the browser…';

  @override
  String get pairV2Approved =>
      'Approved. Type the 6-digit code that the browser shows.';

  @override
  String get pairV2CodeLabel => '6-digit code';

  @override
  String get pairV2Claim => 'Pair';

  @override
  String get pairV2Claiming => 'Checking…';

  @override
  String pairV2WrongCode(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Wrong code. $count tries left.',
      one: 'Wrong code. 1 try left.',
    );
    return '$_temp0';
  }

  @override
  String get pairV2TooManyCodes =>
      'Too many wrong codes ended this request. Start again to make a new one.';

  @override
  String get pairV2Denied =>
      'The request was denied in the browser. Start again to make a new one.';

  @override
  String get pairV2Expired =>
      'The request expired. Start again to make a new one.';

  @override
  String get pairV2TooManyRequests =>
      'Too many pairing requests are open on the Gateway. Try again in a few minutes.';

  @override
  String get pairV2TooManyPhones =>
      'This account already has 10 paired phones. Remove one in a browser, then send the code again.';

  @override
  String get pairV2Failed => 'Pairing failed. Start again.';

  @override
  String get pairV2StartAgain => 'Start again';

  @override
  String get pairV2Paired => 'Paired. Connecting…';

  @override
  String pairApprovalTitle(String device) {
    return 'Pair $device?';
  }

  @override
  String pairApprovalPlatform(String platform) {
    return 'Platform: $platform';
  }

  @override
  String get pairApprovalNote =>
      'Approve only a device you are pairing now. Once paired, it can do everything you can on this Gateway.';

  @override
  String get pairApprovalCodeTitle => 'Type this code in the app';

  @override
  String pairApprovalCodeNote(String time) {
    return 'The code works until $time. Do not share it.';
  }

  @override
  String get pairApprovalDenied => 'Denied. The device was not paired.';

  @override
  String get pairApprovalDecided => 'This request was already decided.';

  @override
  String get pairApprovalExpired =>
      'This request expired. Start again in the app.';

  @override
  String pairingEndsWarning(String date) {
    return 'Pairing ends on $date. Open pirc on this phone before then, or pair again.';
  }

  @override
  String pairLinkScanned(String gateway) {
    return 'A pairing link for $gateway was scanned. Tap Pair to use it.';
  }

  @override
  String get filePickerFailed => 'The file picker could not open.';

  @override
  String filesTooLarge(String names) {
    return 'Not added, too large: $names.';
  }

  @override
  String filesUnreadable(String names) {
    return 'Not added, could not be read: $names.';
  }

  @override
  String filesTooMany(String names) {
    return 'Not added, more than 16 files or 64 MiB at once: $names.';
  }

  @override
  String get pictureNotRead => 'This picture could not be read.';

  @override
  String get pictureTooLarge => 'This picture is too large.';

  @override
  String get shareFailed => 'This could not be shared.';

  @override
  String get messageMediaTap => 'Tap to load the media';

  @override
  String messageMediaFrom(String host) {
    return 'From $host';
  }

  @override
  String get messageMediaFailed => 'The media could not be loaded.';

  @override
  String get messageMediaUnsupported => 'This media cannot be played here.';
}
