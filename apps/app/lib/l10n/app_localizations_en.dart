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
  String get panelMemory => 'Memory';

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
  String get memoryEmpty => 'Nothing remembered yet.';

  @override
  String memoryCounts(int observations, int reflections) {
    return '$observations observations · $reflections reflections';
  }

  @override
  String get memoryOff => 'Memory is off for this work.';

  @override
  String get memoryReflections => 'Reflections';

  @override
  String get memoryObservations => 'Observations';

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
}
