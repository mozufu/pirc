import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
    Locale('zh', 'TW'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'pirc'**
  String get appTitle;

  /// No description provided for @tabChat.
  ///
  /// In en, this message translates to:
  /// **'Chat'**
  String get tabChat;

  /// No description provided for @tabWork.
  ///
  /// In en, this message translates to:
  /// **'Work'**
  String get tabWork;

  /// No description provided for @tabActivity.
  ///
  /// In en, this message translates to:
  /// **'Activity'**
  String get tabActivity;

  /// No description provided for @tabCalendar.
  ///
  /// In en, this message translates to:
  /// **'Calendar'**
  String get tabCalendar;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @back.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get back;

  /// No description provided for @emptyChat.
  ///
  /// In en, this message translates to:
  /// **'No pots or groups yet'**
  String get emptyChat;

  /// No description provided for @emptyWork.
  ///
  /// In en, this message translates to:
  /// **'No sessions yet'**
  String get emptyWork;

  /// No description provided for @emptyActivity.
  ///
  /// In en, this message translates to:
  /// **'No activity yet'**
  String get emptyActivity;

  /// No description provided for @emptyCalendar.
  ///
  /// In en, this message translates to:
  /// **'Nothing scheduled'**
  String get emptyCalendar;

  /// No description provided for @nothingOpen.
  ///
  /// In en, this message translates to:
  /// **'Select an item to open it'**
  String get nothingOpen;

  /// No description provided for @openItem.
  ///
  /// In en, this message translates to:
  /// **'Item {id}'**
  String openItem(String id);

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @languageSystem.
  ///
  /// In en, this message translates to:
  /// **'Follow the system'**
  String get languageSystem;

  /// No description provided for @languageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @languageTraditionalChinese.
  ///
  /// In en, this message translates to:
  /// **'繁體中文'**
  String get languageTraditionalChinese;

  /// No description provided for @appearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get appearance;

  /// No description provided for @appearanceSystem.
  ///
  /// In en, this message translates to:
  /// **'Follow the system'**
  String get appearanceSystem;

  /// No description provided for @appearanceLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get appearanceLight;

  /// No description provided for @appearanceDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get appearanceDark;

  /// No description provided for @pairTitle.
  ///
  /// In en, this message translates to:
  /// **'Pair this device'**
  String get pairTitle;

  /// No description provided for @pairBody.
  ///
  /// In en, this message translates to:
  /// **'Paste the pairing link that the Gateway\'s web page shows.'**
  String get pairBody;

  /// No description provided for @pairLinkLabel.
  ///
  /// In en, this message translates to:
  /// **'Pairing link'**
  String get pairLinkLabel;

  /// No description provided for @pairAction.
  ///
  /// In en, this message translates to:
  /// **'Pair'**
  String get pairAction;

  /// No description provided for @pairChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking…'**
  String get pairChecking;

  /// No description provided for @pairPaired.
  ///
  /// In en, this message translates to:
  /// **'Paired'**
  String get pairPaired;

  /// No description provided for @pairNotALink.
  ///
  /// In en, this message translates to:
  /// **'This is not a pairing link.'**
  String get pairNotALink;

  /// No description provided for @pairTokenRefused.
  ///
  /// In en, this message translates to:
  /// **'The Gateway did not accept this link. Create a new one.'**
  String get pairTokenRefused;

  /// No description provided for @pairAppTooOld.
  ///
  /// In en, this message translates to:
  /// **'This app is too old for the Gateway. Update the app.'**
  String get pairAppTooOld;

  /// No description provided for @pairUnreachable.
  ///
  /// In en, this message translates to:
  /// **'The Gateway could not be reached.'**
  String get pairUnreachable;

  /// No description provided for @pairFailed.
  ///
  /// In en, this message translates to:
  /// **'Pairing failed.'**
  String get pairFailed;

  /// No description provided for @offlineBanner.
  ///
  /// In en, this message translates to:
  /// **'Offline. What you see may be out of date.'**
  String get offlineBanner;

  /// No description provided for @reconnecting.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting…'**
  String get reconnecting;

  /// No description provided for @loadingTitle.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting and fetching the latest state…'**
  String get loadingTitle;

  /// No description provided for @loadingNote.
  ///
  /// In en, this message translates to:
  /// **'No buttons are shown until the state is known.'**
  String get loadingNote;

  /// No description provided for @upgradeTitle.
  ///
  /// In en, this message translates to:
  /// **'Update the app'**
  String get upgradeTitle;

  /// No description provided for @upgradeBody.
  ///
  /// In en, this message translates to:
  /// **'This version of the app is too old for your Gateway. Update it to continue.'**
  String get upgradeBody;

  /// No description provided for @signedOutTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign in again'**
  String get signedOutTitle;

  /// No description provided for @signedOutBody.
  ///
  /// In en, this message translates to:
  /// **'Your sign-in has ended. Reload the page to sign in again.'**
  String get signedOutBody;

  /// No description provided for @openDrawer.
  ///
  /// In en, this message translates to:
  /// **'Open the menu'**
  String get openDrawer;

  /// No description provided for @closeDrawer.
  ///
  /// In en, this message translates to:
  /// **'Close the menu'**
  String get closeDrawer;

  /// No description provided for @gatewayConnected.
  ///
  /// In en, this message translates to:
  /// **'Gateway connected'**
  String get gatewayConnected;

  /// No description provided for @gatewayOffline.
  ///
  /// In en, this message translates to:
  /// **'Gateway offline'**
  String get gatewayOffline;

  /// No description provided for @hosts.
  ///
  /// In en, this message translates to:
  /// **'Hosts'**
  String get hosts;

  /// No description provided for @hostsFailed.
  ///
  /// In en, this message translates to:
  /// **'The hosts could not be loaded.'**
  String get hostsFailed;

  /// No description provided for @noHosts.
  ///
  /// In en, this message translates to:
  /// **'No host is connected.'**
  String get noHosts;

  /// No description provided for @hostIdle.
  ///
  /// In en, this message translates to:
  /// **'No work running'**
  String get hostIdle;

  /// No description provided for @hostRunning.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 session running} other{{count} sessions running}}'**
  String hostRunning(int count);

  /// No description provided for @switchToLight.
  ///
  /// In en, this message translates to:
  /// **'Switch to light'**
  String get switchToLight;

  /// No description provided for @switchToDark.
  ///
  /// In en, this message translates to:
  /// **'Switch to dark'**
  String get switchToDark;

  /// No description provided for @workSubtitle.
  ///
  /// In en, this message translates to:
  /// **'By project'**
  String get workSubtitle;

  /// No description provided for @searchWork.
  ///
  /// In en, this message translates to:
  /// **'Search work and projects'**
  String get searchWork;

  /// No description provided for @filterAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get filterAll;

  /// No description provided for @filterNeedsYou.
  ///
  /// In en, this message translates to:
  /// **'Needs you'**
  String get filterNeedsYou;

  /// No description provided for @filterRunning.
  ///
  /// In en, this message translates to:
  /// **'Running'**
  String get filterRunning;

  /// No description provided for @filterMine.
  ///
  /// In en, this message translates to:
  /// **'Mine'**
  String get filterMine;

  /// No description provided for @filterPots.
  ///
  /// In en, this message translates to:
  /// **'Opened by pots'**
  String get filterPots;

  /// No description provided for @noteNeedsYou.
  ///
  /// In en, this message translates to:
  /// **'Work that needs your answer, approval or review. Reading it is not handling it: a row leaves only when it is handled.'**
  String get noteNeedsYou;

  /// No description provided for @notePots.
  ///
  /// In en, this message translates to:
  /// **'A pot coordinates the work it opens. You can answer, stop or take it over.'**
  String get notePots;

  /// No description provided for @noteMine.
  ///
  /// In en, this message translates to:
  /// **'Only the work you opened.'**
  String get noteMine;

  /// No description provided for @groupCount.
  ///
  /// In en, this message translates to:
  /// **'{count}'**
  String groupCount(int count);

  /// No description provided for @noProject.
  ///
  /// In en, this message translates to:
  /// **'No project'**
  String get noProject;

  /// No description provided for @fromPot.
  ///
  /// In en, this message translates to:
  /// **'From {name}'**
  String fromPot(String name);

  /// No description provided for @fromYou.
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get fromYou;

  /// No description provided for @stateWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for your answer'**
  String get stateWaiting;

  /// No description provided for @stateRunning.
  ///
  /// In en, this message translates to:
  /// **'Running'**
  String get stateRunning;

  /// No description provided for @stateQueued.
  ///
  /// In en, this message translates to:
  /// **'Queued'**
  String get stateQueued;

  /// No description provided for @stateStopping.
  ///
  /// In en, this message translates to:
  /// **'Stopping…'**
  String get stateStopping;

  /// No description provided for @stateIdle.
  ///
  /// In en, this message translates to:
  /// **'Idle'**
  String get stateIdle;

  /// No description provided for @stateSettled.
  ///
  /// In en, this message translates to:
  /// **'Settled'**
  String get stateSettled;

  /// No description provided for @approvalWaiting.
  ///
  /// In en, this message translates to:
  /// **'Not started · waiting for you to approve {model}'**
  String approvalWaiting(String model);

  /// No description provided for @needsYouPill.
  ///
  /// In en, this message translates to:
  /// **'Needs you'**
  String get needsYouPill;

  /// No description provided for @yesterday.
  ///
  /// In en, this message translates to:
  /// **'Yesterday'**
  String get yesterday;

  /// No description provided for @pinned.
  ///
  /// In en, this message translates to:
  /// **'Pinned'**
  String get pinned;

  /// No description provided for @moreActions.
  ///
  /// In en, this message translates to:
  /// **'More actions'**
  String get moreActions;

  /// No description provided for @actionRename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get actionRename;

  /// No description provided for @actionPin.
  ///
  /// In en, this message translates to:
  /// **'Pin'**
  String get actionPin;

  /// No description provided for @actionUnpin.
  ///
  /// In en, this message translates to:
  /// **'Unpin'**
  String get actionUnpin;

  /// No description provided for @actionSettle.
  ///
  /// In en, this message translates to:
  /// **'Settle'**
  String get actionSettle;

  /// No description provided for @actionUnsettle.
  ///
  /// In en, this message translates to:
  /// **'Reopen'**
  String get actionUnsettle;

  /// No description provided for @actionDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete…'**
  String get actionDelete;

  /// No description provided for @deleteWorkTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete this work?'**
  String get deleteWorkTitle;

  /// No description provided for @deleteWorkBody.
  ///
  /// In en, this message translates to:
  /// **'Its conversation is deleted. This cannot be undone.'**
  String get deleteWorkBody;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @actionFailed.
  ///
  /// In en, this message translates to:
  /// **'That did not work: {message}'**
  String actionFailed(String message);

  /// No description provided for @emptyFilter.
  ///
  /// In en, this message translates to:
  /// **'Nothing here.'**
  String get emptyFilter;

  /// No description provided for @listFailed.
  ///
  /// In en, this message translates to:
  /// **'The list could not be loaded.'**
  String get listFailed;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get retry;

  /// No description provided for @newConversation.
  ///
  /// In en, this message translates to:
  /// **'New conversation'**
  String get newConversation;

  /// No description provided for @questionWaits.
  ///
  /// In en, this message translates to:
  /// **'A question waits for you'**
  String get questionWaits;

  /// No description provided for @newContent.
  ///
  /// In en, this message translates to:
  /// **'New content'**
  String get newContent;

  /// No description provided for @turnFailed.
  ///
  /// In en, this message translates to:
  /// **'This turn failed.'**
  String get turnFailed;

  /// No description provided for @turnStopped.
  ///
  /// In en, this message translates to:
  /// **'Stopped.'**
  String get turnStopped;

  /// No description provided for @toolSteps.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 tool step} other{{count} tool steps}}'**
  String toolSteps(int count);

  /// No description provided for @toolFailures.
  ///
  /// In en, this message translates to:
  /// **'{count} failed'**
  String toolFailures(int count);

  /// No description provided for @stepFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get stepFailed;

  /// No description provided for @stepDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get stepDone;

  /// No description provided for @sessionDeleted.
  ///
  /// In en, this message translates to:
  /// **'This work was deleted.'**
  String get sessionDeleted;

  /// No description provided for @sessionFailed.
  ///
  /// In en, this message translates to:
  /// **'This work could not be loaded.'**
  String get sessionFailed;

  /// No description provided for @partialOutputLost.
  ///
  /// In en, this message translates to:
  /// **'Some output was lost while reconnecting.'**
  String get partialOutputLost;

  /// No description provided for @controlledElsewhere.
  ///
  /// In en, this message translates to:
  /// **'Controlled by another device'**
  String get controlledElsewhere;

  /// No description provided for @takeControl.
  ///
  /// In en, this message translates to:
  /// **'Take control'**
  String get takeControl;

  /// No description provided for @dockGoal.
  ///
  /// In en, this message translates to:
  /// **'Goal'**
  String get dockGoal;

  /// No description provided for @dockTodo.
  ///
  /// In en, this message translates to:
  /// **'Tasks'**
  String get dockTodo;

  /// No description provided for @dockQueue.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 queued message} other{{count} queued messages}}'**
  String dockQueue(int count);

  /// No description provided for @whenSteer.
  ///
  /// In en, this message translates to:
  /// **'Steer'**
  String get whenSteer;

  /// No description provided for @whenQueue.
  ///
  /// In en, this message translates to:
  /// **'Queue'**
  String get whenQueue;

  /// No description provided for @thinkingOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get thinkingOff;

  /// No description provided for @thinkingMinimal.
  ///
  /// In en, this message translates to:
  /// **'Minimal'**
  String get thinkingMinimal;

  /// No description provided for @thinkingLow.
  ///
  /// In en, this message translates to:
  /// **'Low'**
  String get thinkingLow;

  /// No description provided for @thinkingMedium.
  ///
  /// In en, this message translates to:
  /// **'Medium'**
  String get thinkingMedium;

  /// No description provided for @thinkingHigh.
  ///
  /// In en, this message translates to:
  /// **'High'**
  String get thinkingHigh;

  /// No description provided for @thinkingXhigh.
  ///
  /// In en, this message translates to:
  /// **'Extra high'**
  String get thinkingXhigh;

  /// No description provided for @thinkingDefault.
  ///
  /// In en, this message translates to:
  /// **'Default thinking'**
  String get thinkingDefault;

  /// No description provided for @modelRow.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get modelRow;

  /// No description provided for @thinkingRow.
  ///
  /// In en, this message translates to:
  /// **'Thinking'**
  String get thinkingRow;

  /// No description provided for @modelDefault.
  ///
  /// In en, this message translates to:
  /// **'Default model'**
  String get modelDefault;

  /// No description provided for @thinkingUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This model has no thinking levels'**
  String get thinkingUnsupported;

  /// No description provided for @composerLocked.
  ///
  /// In en, this message translates to:
  /// **'Take over to send messages'**
  String get composerLocked;

  /// No description provided for @composerReadOnly.
  ///
  /// In en, this message translates to:
  /// **'Another device controls this work'**
  String get composerReadOnly;

  /// No description provided for @composerOffline.
  ///
  /// In en, this message translates to:
  /// **'Offline. Your draft is kept.'**
  String get composerOffline;

  /// No description provided for @composerHint.
  ///
  /// In en, this message translates to:
  /// **'Message…'**
  String get composerHint;

  /// No description provided for @commandRejected.
  ///
  /// In en, this message translates to:
  /// **'The work refused this message.'**
  String get commandRejected;

  /// No description provided for @staleEnvironment.
  ///
  /// In en, this message translates to:
  /// **'The work\'s environment changed. Your draft is kept.'**
  String get staleEnvironment;

  /// No description provided for @attach.
  ///
  /// In en, this message translates to:
  /// **'Attach files'**
  String get attach;

  /// No description provided for @stopWork.
  ///
  /// In en, this message translates to:
  /// **'Stop this work'**
  String get stopWork;

  /// No description provided for @send.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get send;

  /// No description provided for @notSureArrived.
  ///
  /// In en, this message translates to:
  /// **'Not sure it arrived'**
  String get notSureArrived;

  /// No description provided for @checkStatus.
  ///
  /// In en, this message translates to:
  /// **'Check status'**
  String get checkStatus;

  /// No description provided for @pickWorkspace.
  ///
  /// In en, this message translates to:
  /// **'Choose a project'**
  String get pickWorkspace;

  /// No description provided for @firstSending.
  ///
  /// In en, this message translates to:
  /// **'Sending…'**
  String get firstSending;

  /// No description provided for @firstRefused.
  ///
  /// In en, this message translates to:
  /// **'The first message was refused.'**
  String get firstRefused;

  /// No description provided for @sendAgain.
  ///
  /// In en, this message translates to:
  /// **'Send again'**
  String get sendAgain;

  /// No description provided for @firstNotSent.
  ///
  /// In en, this message translates to:
  /// **'Not sent.'**
  String get firstNotSent;

  /// No description provided for @newConversationEmpty.
  ///
  /// In en, this message translates to:
  /// **'Choose a project and write the first message.'**
  String get newConversationEmpty;

  /// No description provided for @noWorkspaces.
  ///
  /// In en, this message translates to:
  /// **'No projects yet.'**
  String get noWorkspaces;

  /// No description provided for @hostOffline.
  ///
  /// In en, this message translates to:
  /// **'{host} · offline'**
  String hostOffline(String host);

  /// No description provided for @workspaceHostOffline.
  ///
  /// In en, this message translates to:
  /// **'Its host is offline'**
  String get workspaceHostOffline;

  /// No description provided for @workspaceUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Its mode is not available on this Gateway'**
  String get workspaceUnavailable;

  /// No description provided for @handledElsewhere.
  ///
  /// In en, this message translates to:
  /// **'{title} · handled on another device'**
  String handledElsewhere(String title);

  /// No description provided for @questionExpired.
  ///
  /// In en, this message translates to:
  /// **'Expired'**
  String get questionExpired;

  /// No description provided for @expiresAt.
  ///
  /// In en, this message translates to:
  /// **'Expires at {time}'**
  String expiresAt(String time);

  /// No description provided for @no.
  ///
  /// In en, this message translates to:
  /// **'No'**
  String get no;

  /// No description provided for @yes.
  ///
  /// In en, this message translates to:
  /// **'Yes'**
  String get yes;

  /// No description provided for @questionSkipped.
  ///
  /// In en, this message translates to:
  /// **'Skipped'**
  String get questionSkipped;

  /// No description provided for @skip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get skip;

  /// No description provided for @approvalReadOnly.
  ///
  /// In en, this message translates to:
  /// **'Read only'**
  String get approvalReadOnly;

  /// No description provided for @approvalAuto.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get approvalAuto;

  /// No description provided for @approvalFullAccess.
  ///
  /// In en, this message translates to:
  /// **'Full access'**
  String get approvalFullAccess;

  /// No description provided for @approvalMode.
  ///
  /// In en, this message translates to:
  /// **'Approval mode'**
  String get approvalMode;

  /// No description provided for @approvalFullAccessWarning.
  ///
  /// In en, this message translates to:
  /// **'The agent may run any command and change any file without asking. Use this only for work you trust.'**
  String get approvalFullAccessWarning;

  /// No description provided for @approvalFullAccessConfirm.
  ///
  /// In en, this message translates to:
  /// **'Allow full access'**
  String get approvalFullAccessConfirm;

  /// No description provided for @notSentByYou.
  ///
  /// In en, this message translates to:
  /// **'Not sent by you'**
  String get notSentByYou;

  /// No description provided for @potCoordinates.
  ///
  /// In en, this message translates to:
  /// **'{name} coordinates this work. You can answer its questions or stop it; take over to send instructions.'**
  String potCoordinates(String name);

  /// No description provided for @takeOver.
  ///
  /// In en, this message translates to:
  /// **'Take over'**
  String get takeOver;

  /// No description provided for @takenOver.
  ///
  /// In en, this message translates to:
  /// **'{name} sends no more instructions here.'**
  String takenOver(String name);

  /// No description provided for @resultGenerating.
  ///
  /// In en, this message translates to:
  /// **'Generating…'**
  String get resultGenerating;

  /// No description provided for @resultFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get resultFailed;

  /// No description provided for @resultReadSoFar.
  ///
  /// In en, this message translates to:
  /// **'Read what is ready'**
  String get resultReadSoFar;

  /// No description provided for @resultOpen.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get resultOpen;

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @copied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get copied;

  /// No description provided for @share.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get share;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @resultMissing.
  ///
  /// In en, this message translates to:
  /// **'This result is no longer in the conversation.'**
  String get resultMissing;

  /// No description provided for @resultVersions.
  ///
  /// In en, this message translates to:
  /// **'Versions'**
  String get resultVersions;

  /// No description provided for @resultNewer.
  ///
  /// In en, this message translates to:
  /// **'Version {version} is ready.'**
  String resultNewer(int version);

  /// No description provided for @resultSwitch.
  ///
  /// In en, this message translates to:
  /// **'Switch to v{version}'**
  String resultSwitch(int version);

  /// No description provided for @resultFailedShowingLast.
  ///
  /// In en, this message translates to:
  /// **'Version {version} failed. The last good version is shown.'**
  String resultFailedShowingLast(int version);

  /// No description provided for @resultNoColumns.
  ///
  /// In en, this message translates to:
  /// **'This table has no columns.'**
  String get resultNoColumns;

  /// No description provided for @resultUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This kind of result is shown as its summary.'**
  String get resultUnsupported;

  /// No description provided for @accessNeeded.
  ///
  /// In en, this message translates to:
  /// **'Approval needed'**
  String get accessNeeded;

  /// No description provided for @accessOpenInBrowser.
  ///
  /// In en, this message translates to:
  /// **'Open this address in a browser where you are signed in, and approve:'**
  String get accessOpenInBrowser;

  /// No description provided for @accessRequestExpires.
  ///
  /// In en, this message translates to:
  /// **'The request expires at {time}.'**
  String accessRequestExpires(String time);

  /// No description provided for @accessDenied.
  ///
  /// In en, this message translates to:
  /// **'The request was denied.'**
  String get accessDenied;

  /// No description provided for @accessExpired.
  ///
  /// In en, this message translates to:
  /// **'The request or the access expired.'**
  String get accessExpired;

  /// No description provided for @accessAsk.
  ///
  /// In en, this message translates to:
  /// **'Ask for access'**
  String get accessAsk;

  /// No description provided for @settingsDevices.
  ///
  /// In en, this message translates to:
  /// **'Devices'**
  String get settingsDevices;

  /// No description provided for @accessDevicesReason.
  ///
  /// In en, this message translates to:
  /// **'Listing and removing paired devices needs a short approval from a browser.'**
  String get accessDevicesReason;

  /// No description provided for @deviceLastUsed.
  ///
  /// In en, this message translates to:
  /// **'Last used {time}'**
  String deviceLastUsed(String time);

  /// No description provided for @deviceRevoke.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get deviceRevoke;

  /// No description provided for @deviceRevokeNeedsAccess.
  ///
  /// In en, this message translates to:
  /// **'Removing a device needs access to remove devices.'**
  String get deviceRevokeNeedsAccess;

  /// No description provided for @devicePair.
  ///
  /// In en, this message translates to:
  /// **'Pair a new device'**
  String get devicePair;

  /// No description provided for @accessPairReason.
  ///
  /// In en, this message translates to:
  /// **'Pairing a new device needs a short approval from a browser.'**
  String get accessPairReason;

  /// No description provided for @deviceRevokeTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove {name}?'**
  String deviceRevokeTitle(String name);

  /// No description provided for @deviceRevokeBody.
  ///
  /// In en, this message translates to:
  /// **'It can no longer reach this Gateway until it is paired again.'**
  String get deviceRevokeBody;

  /// No description provided for @devicePaired.
  ///
  /// In en, this message translates to:
  /// **'{name} is ready'**
  String devicePaired(String name);

  /// No description provided for @devicePairOnce.
  ///
  /// In en, this message translates to:
  /// **'This link and code are shown only once. Open the link on the new device or scan the code.'**
  String get devicePairOnce;

  /// No description provided for @deviceExpires.
  ///
  /// In en, this message translates to:
  /// **'The new device works until {time} unless it is renewed.'**
  String deviceExpires(String time);

  /// No description provided for @done.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get done;

  /// No description provided for @deviceName.
  ///
  /// In en, this message translates to:
  /// **'Device name'**
  String get deviceName;

  /// No description provided for @devicePairAction.
  ///
  /// In en, this message translates to:
  /// **'Pair'**
  String get devicePairAction;

  /// No description provided for @capabilityProviders.
  ///
  /// In en, this message translates to:
  /// **'Change model providers and their credentials'**
  String get capabilityProviders;

  /// No description provided for @capabilityDevicesRead.
  ///
  /// In en, this message translates to:
  /// **'See the list of paired devices'**
  String get capabilityDevicesRead;

  /// No description provided for @capabilityDevicesRevoke.
  ///
  /// In en, this message translates to:
  /// **'Remove paired devices'**
  String get capabilityDevicesRevoke;

  /// No description provided for @capabilityDevicesPair.
  ///
  /// In en, this message translates to:
  /// **'Pair new devices that can use this Gateway'**
  String get capabilityDevicesPair;

  /// No description provided for @approvalTitle.
  ///
  /// In en, this message translates to:
  /// **'{device} asks for access'**
  String approvalTitle(String device);

  /// No description provided for @approvalPairingLifetime.
  ///
  /// In en, this message translates to:
  /// **'Each new device works for {idle} days without use and at most {max} days.'**
  String approvalPairingLifetime(int idle, int max);

  /// No description provided for @approvalGrantLifetime.
  ///
  /// In en, this message translates to:
  /// **'The access lasts 15 minutes and only on that device.'**
  String get approvalGrantLifetime;

  /// No description provided for @approvalApproved.
  ///
  /// In en, this message translates to:
  /// **'Approved. Go back to the app.'**
  String get approvalApproved;

  /// No description provided for @approvalDenied.
  ///
  /// In en, this message translates to:
  /// **'Denied.'**
  String get approvalDenied;

  /// No description provided for @approvalNotPending.
  ///
  /// In en, this message translates to:
  /// **'This request is no longer waiting.'**
  String get approvalNotPending;

  /// No description provided for @approvalDeny.
  ///
  /// In en, this message translates to:
  /// **'Deny'**
  String get approvalDeny;

  /// No description provided for @approvalApprove.
  ///
  /// In en, this message translates to:
  /// **'Approve'**
  String get approvalApprove;

  /// No description provided for @approvalMissing.
  ///
  /// In en, this message translates to:
  /// **'This request does not exist or has expired.'**
  String get approvalMissing;

  /// No description provided for @panelsTitle.
  ///
  /// In en, this message translates to:
  /// **'Panels'**
  String get panelsTitle;

  /// No description provided for @panelMore.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get panelMore;

  /// No description provided for @panelFiles.
  ///
  /// In en, this message translates to:
  /// **'Files'**
  String get panelFiles;

  /// No description provided for @panelGit.
  ///
  /// In en, this message translates to:
  /// **'Git'**
  String get panelGit;

  /// No description provided for @panelTerminal.
  ///
  /// In en, this message translates to:
  /// **'Terminal'**
  String get panelTerminal;

  /// No description provided for @panelTasks.
  ///
  /// In en, this message translates to:
  /// **'Tasks'**
  String get panelTasks;

  /// No description provided for @panelMemory.
  ///
  /// In en, this message translates to:
  /// **'Memory'**
  String get panelMemory;

  /// No description provided for @panelBrowser.
  ///
  /// In en, this message translates to:
  /// **'Browser'**
  String get panelBrowser;

  /// No description provided for @panelContext.
  ///
  /// In en, this message translates to:
  /// **'Context'**
  String get panelContext;

  /// No description provided for @panelCheckpoints.
  ///
  /// In en, this message translates to:
  /// **'Checkpoints'**
  String get panelCheckpoints;

  /// No description provided for @panelOffline.
  ///
  /// In en, this message translates to:
  /// **'Offline. This panel loads when the Gateway is reachable.'**
  String get panelOffline;

  /// No description provided for @panelHostOffline.
  ///
  /// In en, this message translates to:
  /// **'The host is offline.'**
  String get panelHostOffline;

  /// No description provided for @panelFailed.
  ///
  /// In en, this message translates to:
  /// **'This panel could not be loaded.'**
  String get panelFailed;

  /// No description provided for @panelReadOnly.
  ///
  /// In en, this message translates to:
  /// **'Read only: another device controls this work.'**
  String get panelReadOnly;

  /// No description provided for @panelsOpen.
  ///
  /// In en, this message translates to:
  /// **'Panels'**
  String get panelsOpen;

  /// No description provided for @filesRoot.
  ///
  /// In en, this message translates to:
  /// **'Root'**
  String get filesRoot;

  /// No description provided for @refresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get refresh;

  /// No description provided for @filesEmpty.
  ///
  /// In en, this message translates to:
  /// **'This folder is empty.'**
  String get filesEmpty;

  /// No description provided for @filesImageTooLarge.
  ///
  /// In en, this message translates to:
  /// **'This image is too large to show.'**
  String get filesImageTooLarge;

  /// No description provided for @filesBinary.
  ///
  /// In en, this message translates to:
  /// **'This file is not text.'**
  String get filesBinary;

  /// No description provided for @panelTruncated.
  ///
  /// In en, this message translates to:
  /// **'Only the first part is shown.'**
  String get panelTruncated;

  /// No description provided for @gitNoDiff.
  ///
  /// In en, this message translates to:
  /// **'No changes.'**
  String get gitNoDiff;

  /// No description provided for @gitChanges.
  ///
  /// In en, this message translates to:
  /// **'Changes'**
  String get gitChanges;

  /// No description provided for @gitHistory.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get gitHistory;

  /// No description provided for @gitNoCommits.
  ///
  /// In en, this message translates to:
  /// **'No commits yet.'**
  String get gitNoCommits;

  /// No description provided for @gitClean.
  ///
  /// In en, this message translates to:
  /// **'No changes.'**
  String get gitClean;

  /// No description provided for @gitNotRepo.
  ///
  /// In en, this message translates to:
  /// **'This folder is not a Git repository.'**
  String get gitNotRepo;

  /// No description provided for @gitDetached.
  ///
  /// In en, this message translates to:
  /// **'No branch'**
  String get gitDetached;

  /// No description provided for @gitAheadBehind.
  ///
  /// In en, this message translates to:
  /// **'{upstream} · {ahead} ahead · {behind} behind'**
  String gitAheadBehind(String upstream, int ahead, int behind);

  /// No description provided for @tasksEmpty.
  ///
  /// In en, this message translates to:
  /// **'No background tasks or teammates.'**
  String get tasksEmpty;

  /// No description provided for @tasksBackground.
  ///
  /// In en, this message translates to:
  /// **'Background tasks'**
  String get tasksBackground;

  /// No description provided for @tasksTeam.
  ///
  /// In en, this message translates to:
  /// **'Teammates'**
  String get tasksTeam;

  /// No description provided for @tasksStop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get tasksStop;

  /// No description provided for @tasksNoOutput.
  ///
  /// In en, this message translates to:
  /// **'No output yet.'**
  String get tasksNoOutput;

  /// No description provided for @memoryEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nothing remembered yet.'**
  String get memoryEmpty;

  /// No description provided for @memoryCounts.
  ///
  /// In en, this message translates to:
  /// **'{observations} observations · {reflections} reflections'**
  String memoryCounts(int observations, int reflections);

  /// No description provided for @memoryOff.
  ///
  /// In en, this message translates to:
  /// **'Memory is off for this work.'**
  String get memoryOff;

  /// No description provided for @memoryReflections.
  ///
  /// In en, this message translates to:
  /// **'Reflections'**
  String get memoryReflections;

  /// No description provided for @memoryObservations.
  ///
  /// In en, this message translates to:
  /// **'Observations'**
  String get memoryObservations;

  /// No description provided for @contextEmpty.
  ///
  /// In en, this message translates to:
  /// **'Send a message first to see its context.'**
  String get contextEmpty;

  /// No description provided for @contextUsage.
  ///
  /// In en, this message translates to:
  /// **'About {used} of {window} tokens'**
  String contextUsage(int used, int window);

  /// No description provided for @contextTokens.
  ///
  /// In en, this message translates to:
  /// **'About {count} tokens'**
  String contextTokens(int count);

  /// No description provided for @contextTools.
  ///
  /// In en, this message translates to:
  /// **'{count} tools'**
  String contextTools(int count);

  /// No description provided for @terminalStarting.
  ///
  /// In en, this message translates to:
  /// **'Starting…'**
  String get terminalStarting;

  /// No description provided for @terminalNew.
  ///
  /// In en, this message translates to:
  /// **'New terminal'**
  String get terminalNew;

  /// No description provided for @terminalsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No terminals.'**
  String get terminalsEmpty;

  /// No description provided for @terminalExited.
  ///
  /// In en, this message translates to:
  /// **'Exited ({code})'**
  String terminalExited(String code);

  /// No description provided for @terminalClose.
  ///
  /// In en, this message translates to:
  /// **'Close terminal'**
  String get terminalClose;

  /// No description provided for @terminalReadOnly.
  ///
  /// In en, this message translates to:
  /// **'Read only: take control to type here.'**
  String get terminalReadOnly;

  /// No description provided for @browserUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The browser is not available on this host.'**
  String get browserUnavailable;

  /// No description provided for @browserEmpty.
  ///
  /// In en, this message translates to:
  /// **'No browser is open for this work.'**
  String get browserEmpty;

  /// No description provided for @browserReturn.
  ///
  /// In en, this message translates to:
  /// **'Return control'**
  String get browserReturn;

  /// No description provided for @browserTake.
  ///
  /// In en, this message translates to:
  /// **'Take control'**
  String get browserTake;

  /// No description provided for @browserStopRecording.
  ///
  /// In en, this message translates to:
  /// **'Stop recording'**
  String get browserStopRecording;

  /// No description provided for @browserRecord.
  ///
  /// In en, this message translates to:
  /// **'Record'**
  String get browserRecord;

  /// No description provided for @browserAgentWaiting.
  ///
  /// In en, this message translates to:
  /// **'The agent waits for you.'**
  String get browserAgentWaiting;

  /// No description provided for @browserNoFrame.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the page…'**
  String get browserNoFrame;

  /// No description provided for @browserType.
  ///
  /// In en, this message translates to:
  /// **'Type and press Enter'**
  String get browserType;

  /// No description provided for @checkpointsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No checkpoints yet.'**
  String get checkpointsEmpty;

  /// No description provided for @checkpointsOff.
  ///
  /// In en, this message translates to:
  /// **'Checkpoints are off for this project.'**
  String get checkpointsOff;

  /// No description provided for @checkpointsFiles.
  ///
  /// In en, this message translates to:
  /// **'{count} files · {coverage}'**
  String checkpointsFiles(int count, String coverage);

  /// No description provided for @checkpointsPreview.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get checkpointsPreview;

  /// No description provided for @checkpointsPreviewBody.
  ///
  /// In en, this message translates to:
  /// **'{bytes} bytes copied · {excluded} left out'**
  String checkpointsPreviewBody(int bytes, int excluded);

  /// No description provided for @checkpointsJob.
  ///
  /// In en, this message translates to:
  /// **'Recovery: {state}'**
  String checkpointsJob(String state);

  /// No description provided for @checkpointsPreviewAction.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get checkpointsPreviewAction;

  /// No description provided for @checkpointsRecover.
  ///
  /// In en, this message translates to:
  /// **'Recover'**
  String get checkpointsRecover;

  /// No description provided for @checkpointsContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue in a new conversation'**
  String get checkpointsContinue;

  /// No description provided for @settingsGeneral.
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get settingsGeneral;

  /// No description provided for @textSize.
  ///
  /// In en, this message translates to:
  /// **'Text size'**
  String get textSize;

  /// No description provided for @textSmall.
  ///
  /// In en, this message translates to:
  /// **'Small'**
  String get textSmall;

  /// No description provided for @textDefault.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get textDefault;

  /// No description provided for @textLarge.
  ///
  /// In en, this message translates to:
  /// **'Large'**
  String get textLarge;

  /// No description provided for @textLarger.
  ///
  /// In en, this message translates to:
  /// **'Larger'**
  String get textLarger;

  /// No description provided for @startTab.
  ///
  /// In en, this message translates to:
  /// **'When the app opens'**
  String get startTab;

  /// No description provided for @settingsAccount.
  ///
  /// In en, this message translates to:
  /// **'Account and this device'**
  String get settingsAccount;

  /// No description provided for @accountName.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get accountName;

  /// No description provided for @accountGateway.
  ///
  /// In en, this message translates to:
  /// **'Gateway'**
  String get accountGateway;

  /// No description provided for @unpair.
  ///
  /// In en, this message translates to:
  /// **'Unpair this device…'**
  String get unpair;

  /// No description provided for @unpairTitle.
  ///
  /// In en, this message translates to:
  /// **'Unpair this device?'**
  String get unpairTitle;

  /// No description provided for @unpairBody.
  ///
  /// In en, this message translates to:
  /// **'The device token and the drafts on this device are removed. Pairing again needs a new link.'**
  String get unpairBody;

  /// No description provided for @unpairConfirm.
  ///
  /// In en, this message translates to:
  /// **'Unpair'**
  String get unpairConfirm;

  /// No description provided for @settingsAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsAbout;

  /// No description provided for @aboutApp.
  ///
  /// In en, this message translates to:
  /// **'App version'**
  String get aboutApp;

  /// No description provided for @aboutGateway.
  ///
  /// In en, this message translates to:
  /// **'Gateway version'**
  String get aboutGateway;

  /// No description provided for @aboutLicences.
  ///
  /// In en, this message translates to:
  /// **'Licences'**
  String get aboutLicences;

  /// No description provided for @settingsAi.
  ///
  /// In en, this message translates to:
  /// **'AI'**
  String get settingsAi;

  /// No description provided for @settingsProviders.
  ///
  /// In en, this message translates to:
  /// **'Model providers and default model'**
  String get settingsProviders;

  /// No description provided for @settingsMemory.
  ///
  /// In en, this message translates to:
  /// **'Memory'**
  String get settingsMemory;

  /// No description provided for @settingsModes.
  ///
  /// In en, this message translates to:
  /// **'Modes'**
  String get settingsModes;

  /// No description provided for @settingsNotificationsAndAccess.
  ///
  /// In en, this message translates to:
  /// **'Notifications and access'**
  String get settingsNotificationsAndAccess;

  /// No description provided for @settingsNotifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get settingsNotifications;

  /// No description provided for @settingsCalendar.
  ///
  /// In en, this message translates to:
  /// **'Calendar and agent access'**
  String get settingsCalendar;

  /// No description provided for @accessProvidersReason.
  ///
  /// In en, this message translates to:
  /// **'Changing model providers needs a short approval from a browser.'**
  String get accessProvidersReason;

  /// No description provided for @providersDefaultModel.
  ///
  /// In en, this message translates to:
  /// **'Default model'**
  String get providersDefaultModel;

  /// No description provided for @providersList.
  ///
  /// In en, this message translates to:
  /// **'Providers'**
  String get providersList;

  /// No description provided for @providersRow.
  ///
  /// In en, this message translates to:
  /// **'{api} · {count} models'**
  String providersRow(String api, int count);

  /// No description provided for @providersReplaceKey.
  ///
  /// In en, this message translates to:
  /// **'Replace the API key'**
  String get providersReplaceKey;

  /// No description provided for @providersRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get providersRemove;

  /// No description provided for @providersAdd.
  ///
  /// In en, this message translates to:
  /// **'Add a provider'**
  String get providersAdd;

  /// No description provided for @providersAccounts.
  ///
  /// In en, this message translates to:
  /// **'Accounts'**
  String get providersAccounts;

  /// No description provided for @providersConnected.
  ///
  /// In en, this message translates to:
  /// **'Signed in'**
  String get providersConnected;

  /// No description provided for @providersNotConnected.
  ///
  /// In en, this message translates to:
  /// **'Not signed in'**
  String get providersNotConnected;

  /// No description provided for @providersSignOut.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get providersSignOut;

  /// No description provided for @providersSignIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get providersSignIn;

  /// No description provided for @providersApiKey.
  ///
  /// In en, this message translates to:
  /// **'API key'**
  String get providersApiKey;

  /// No description provided for @providersPreset.
  ///
  /// In en, this message translates to:
  /// **'Provider'**
  String get providersPreset;

  /// No description provided for @providersId.
  ///
  /// In en, this message translates to:
  /// **'Name on this Gateway'**
  String get providersId;

  /// No description provided for @providersModelsFound.
  ///
  /// In en, this message translates to:
  /// **'{count} models found'**
  String providersModelsFound(int count);

  /// No description provided for @providersFindModels.
  ///
  /// In en, this message translates to:
  /// **'Find models'**
  String get providersFindModels;

  /// No description provided for @providersSignInTo.
  ///
  /// In en, this message translates to:
  /// **'Sign in to {name}'**
  String providersSignInTo(String name);

  /// No description provided for @providersConsent.
  ///
  /// In en, this message translates to:
  /// **'I accept this provider\'s terms for use through pirc.'**
  String get providersConsent;

  /// No description provided for @providersOpenAddress.
  ///
  /// In en, this message translates to:
  /// **'Open this address and sign in:'**
  String get providersOpenAddress;

  /// No description provided for @providersSignedIn.
  ///
  /// In en, this message translates to:
  /// **'Signed in.'**
  String get providersSignedIn;

  /// No description provided for @memoryRestore.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get memoryRestore;

  /// No description provided for @memoryForget.
  ///
  /// In en, this message translates to:
  /// **'Forget'**
  String get memoryForget;

  /// No description provided for @memoryProposals.
  ///
  /// In en, this message translates to:
  /// **'Waiting for your answer'**
  String get memoryProposals;

  /// No description provided for @memoryReject.
  ///
  /// In en, this message translates to:
  /// **'Reject'**
  String get memoryReject;

  /// No description provided for @memoryApprove.
  ///
  /// In en, this message translates to:
  /// **'Approve'**
  String get memoryApprove;

  /// No description provided for @memoryAboutYou.
  ///
  /// In en, this message translates to:
  /// **'About you'**
  String get memoryAboutYou;

  /// No description provided for @memoryNone.
  ///
  /// In en, this message translates to:
  /// **'Nothing yet.'**
  String get memoryNone;

  /// No description provided for @memoryNotes.
  ///
  /// In en, this message translates to:
  /// **'Notes'**
  String get memoryNotes;

  /// No description provided for @memoryRemoved.
  ///
  /// In en, this message translates to:
  /// **'Removed'**
  String get memoryRemoved;

  /// No description provided for @pushTargets.
  ///
  /// In en, this message translates to:
  /// **'Where notifications go'**
  String get pushTargets;

  /// No description provided for @pushNone.
  ///
  /// In en, this message translates to:
  /// **'No device receives notifications yet.'**
  String get pushNone;

  /// No description provided for @pushFailing.
  ///
  /// In en, this message translates to:
  /// **'Delivery is failing'**
  String get pushFailing;

  /// No description provided for @pushSendTest.
  ///
  /// In en, this message translates to:
  /// **'Send a test'**
  String get pushSendTest;

  /// No description provided for @pushSent.
  ///
  /// In en, this message translates to:
  /// **'Sent to {count} targets.'**
  String pushSent(int count);

  /// No description provided for @calendarAllowRead.
  ///
  /// In en, this message translates to:
  /// **'Agents may read the calendar'**
  String get calendarAllowRead;

  /// No description provided for @calendarAllowPropose.
  ///
  /// In en, this message translates to:
  /// **'Agents may propose changes'**
  String get calendarAllowPropose;

  /// No description provided for @calendarAllowProposeNote.
  ///
  /// In en, this message translates to:
  /// **'Each change waits for your answer in the conversation.'**
  String get calendarAllowProposeNote;

  /// No description provided for @modesNoWarnings.
  ///
  /// In en, this message translates to:
  /// **'The Gateway does not report mode files or their warnings yet; see its log.'**
  String get modesNoWarnings;

  /// No description provided for @transitionTitle.
  ///
  /// In en, this message translates to:
  /// **'Switching hosts'**
  String get transitionTitle;

  /// No description provided for @transitionCancelled.
  ///
  /// In en, this message translates to:
  /// **'The switch was cancelled; the work stays where it was.'**
  String get transitionCancelled;

  /// No description provided for @transitionStopping.
  ///
  /// In en, this message translates to:
  /// **'Stopping work on the current host'**
  String get transitionStopping;

  /// No description provided for @transitionRevoking.
  ///
  /// In en, this message translates to:
  /// **'Confirming its access is removed'**
  String get transitionRevoking;

  /// No description provided for @transitionPreparing.
  ///
  /// In en, this message translates to:
  /// **'Preparing the new host'**
  String get transitionPreparing;

  /// No description provided for @transitionSwitched.
  ///
  /// In en, this message translates to:
  /// **'Switched'**
  String get transitionSwitched;

  /// No description provided for @transitionSourceOffline.
  ///
  /// In en, this message translates to:
  /// **'The current host is offline. Nothing starts on the new host before it confirms.'**
  String get transitionSourceOffline;

  /// No description provided for @transitionNeedsAck.
  ///
  /// In en, this message translates to:
  /// **'Some access could not be proven removed. Review it to continue.'**
  String get transitionNeedsAck;

  /// No description provided for @transitionNeedsAuthority.
  ///
  /// In en, this message translates to:
  /// **'The permission to switch expired. Renew it to continue.'**
  String get transitionNeedsAuthority;

  /// No description provided for @transitionUncertain.
  ///
  /// In en, this message translates to:
  /// **'Not sure the last step arrived. Waiting for the host.'**
  String get transitionUncertain;

  /// No description provided for @transitionPlanChanged.
  ///
  /// In en, this message translates to:
  /// **'The plan changed. Preview the switch again.'**
  String get transitionPlanChanged;

  /// No description provided for @transitionAcknowledge.
  ///
  /// In en, this message translates to:
  /// **'Continue anyway'**
  String get transitionAcknowledge;

  /// No description provided for @transitionReauthorize.
  ///
  /// In en, this message translates to:
  /// **'Renew permission'**
  String get transitionReauthorize;

  /// No description provided for @transitionCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel the switch'**
  String get transitionCancel;

  /// No description provided for @composerTransitioning.
  ///
  /// In en, this message translates to:
  /// **'Switching hosts. Your draft is kept.'**
  String get composerTransitioning;

  /// No description provided for @envFolders.
  ///
  /// In en, this message translates to:
  /// **'Folders and their rights'**
  String get envFolders;

  /// No description provided for @envRead.
  ///
  /// In en, this message translates to:
  /// **'Read'**
  String get envRead;

  /// No description provided for @envWrite.
  ///
  /// In en, this message translates to:
  /// **'Read and write'**
  String get envWrite;

  /// No description provided for @envDeny.
  ///
  /// In en, this message translates to:
  /// **'No access'**
  String get envDeny;

  /// No description provided for @envRevoke.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get envRevoke;

  /// No description provided for @envAddFolder.
  ///
  /// In en, this message translates to:
  /// **'Add a folder'**
  String get envAddFolder;

  /// No description provided for @envFolderPath.
  ///
  /// In en, this message translates to:
  /// **'Folder path on the host'**
  String get envFolderPath;

  /// No description provided for @envSwitch.
  ///
  /// In en, this message translates to:
  /// **'Switch host…'**
  String get envSwitch;

  /// No description provided for @envSwitchTo.
  ///
  /// In en, this message translates to:
  /// **'Switch to'**
  String get envSwitchTo;

  /// No description provided for @envPreviewTitle.
  ///
  /// In en, this message translates to:
  /// **'Switch to {target}?'**
  String envPreviewTitle(String target);

  /// No description provided for @envPreviewStops.
  ///
  /// In en, this message translates to:
  /// **'Running work, terminals and the browser stop on the current host.'**
  String get envPreviewStops;

  /// No description provided for @envPreviewStays.
  ///
  /// In en, this message translates to:
  /// **'The conversation, its tasks and your drafts stay. Files are not copied.'**
  String get envPreviewStays;

  /// No description provided for @envConfirm.
  ///
  /// In en, this message translates to:
  /// **'Switch'**
  String get envConfirm;

  /// No description provided for @envBlockedCrossNode.
  ///
  /// In en, this message translates to:
  /// **'Moving to another host is not available yet.'**
  String get envBlockedCrossNode;

  /// No description provided for @envBlockedPendingWork.
  ///
  /// In en, this message translates to:
  /// **'Work is still running here.'**
  String get envBlockedPendingWork;

  /// No description provided for @envBlockedNode.
  ///
  /// In en, this message translates to:
  /// **'The host is offline or cannot do this.'**
  String get envBlockedNode;

  /// No description provided for @envBlockedUnchanged.
  ///
  /// In en, this message translates to:
  /// **'This is the current environment.'**
  String get envBlockedUnchanged;

  /// No description provided for @envBlockedResource.
  ///
  /// In en, this message translates to:
  /// **'A folder or resource is missing on the target.'**
  String get envBlockedResource;

  /// No description provided for @scopeOccurrence.
  ///
  /// In en, this message translates to:
  /// **'This one'**
  String get scopeOccurrence;

  /// No description provided for @scopeFollowing.
  ///
  /// In en, this message translates to:
  /// **'This and later ones'**
  String get scopeFollowing;

  /// No description provided for @scopeSeries.
  ///
  /// In en, this message translates to:
  /// **'The whole series'**
  String get scopeSeries;

  /// No description provided for @eventNew.
  ///
  /// In en, this message translates to:
  /// **'New event'**
  String get eventNew;

  /// No description provided for @eventEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get eventEdit;

  /// No description provided for @eventTitle.
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get eventTitle;

  /// No description provided for @eventAllDay.
  ///
  /// In en, this message translates to:
  /// **'All day'**
  String get eventAllDay;

  /// No description provided for @eventStart.
  ///
  /// In en, this message translates to:
  /// **'Starts (YYYY-MM-DD)'**
  String get eventStart;

  /// No description provided for @eventTime.
  ///
  /// In en, this message translates to:
  /// **'Time (HH:mm)'**
  String get eventTime;

  /// No description provided for @eventEnd.
  ///
  /// In en, this message translates to:
  /// **'Ends (YYYY-MM-DD)'**
  String get eventEnd;

  /// No description provided for @eventRepeat.
  ///
  /// In en, this message translates to:
  /// **'Repeat'**
  String get eventRepeat;

  /// No description provided for @repeatNone.
  ///
  /// In en, this message translates to:
  /// **'Does not repeat'**
  String get repeatNone;

  /// No description provided for @repeatDaily.
  ///
  /// In en, this message translates to:
  /// **'Every day'**
  String get repeatDaily;

  /// No description provided for @repeatWeekly.
  ///
  /// In en, this message translates to:
  /// **'Every week'**
  String get repeatWeekly;

  /// No description provided for @repeatMonthly.
  ///
  /// In en, this message translates to:
  /// **'Every month'**
  String get repeatMonthly;

  /// No description provided for @repeatYearly.
  ///
  /// In en, this message translates to:
  /// **'Every year'**
  String get repeatYearly;

  /// No description provided for @eventLocation.
  ///
  /// In en, this message translates to:
  /// **'Place'**
  String get eventLocation;

  /// No description provided for @eventNotes.
  ///
  /// In en, this message translates to:
  /// **'Notes'**
  String get eventNotes;

  /// No description provided for @taskNew.
  ///
  /// In en, this message translates to:
  /// **'New agent task'**
  String get taskNew;

  /// No description provided for @taskEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit task'**
  String get taskEdit;

  /// No description provided for @taskPrompt.
  ///
  /// In en, this message translates to:
  /// **'What the agent does'**
  String get taskPrompt;

  /// No description provided for @taskPickTarget.
  ///
  /// In en, this message translates to:
  /// **'Choose a project'**
  String get taskPickTarget;

  /// No description provided for @taskRepeats.
  ///
  /// In en, this message translates to:
  /// **'Repeats'**
  String get taskRepeats;

  /// No description provided for @taskCron.
  ///
  /// In en, this message translates to:
  /// **'When (cron)'**
  String get taskCron;

  /// No description provided for @taskCronHelp.
  ///
  /// In en, this message translates to:
  /// **'minute hour day month weekday, e.g. 0 9 * * 1-5'**
  String get taskCronHelp;

  /// No description provided for @taskAt.
  ///
  /// In en, this message translates to:
  /// **'When'**
  String get taskAt;

  /// No description provided for @calendarNew.
  ///
  /// In en, this message translates to:
  /// **'New'**
  String get calendarNew;

  /// No description provided for @calendarPrevious.
  ///
  /// In en, this message translates to:
  /// **'Previous'**
  String get calendarPrevious;

  /// No description provided for @calendarNext.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get calendarNext;

  /// No description provided for @viewMonth.
  ///
  /// In en, this message translates to:
  /// **'Month'**
  String get viewMonth;

  /// No description provided for @viewWeek.
  ///
  /// In en, this message translates to:
  /// **'Week'**
  String get viewWeek;

  /// No description provided for @viewDay.
  ///
  /// In en, this message translates to:
  /// **'Day'**
  String get viewDay;

  /// No description provided for @viewList.
  ///
  /// In en, this message translates to:
  /// **'List'**
  String get viewList;

  /// No description provided for @calendarToday.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get calendarToday;

  /// No description provided for @taskMissed.
  ///
  /// In en, this message translates to:
  /// **'Missed'**
  String get taskMissed;

  /// No description provided for @taskMark.
  ///
  /// In en, this message translates to:
  /// **'Agent task'**
  String get taskMark;

  /// No description provided for @taskPlanned.
  ///
  /// In en, this message translates to:
  /// **'Planned'**
  String get taskPlanned;

  /// No description provided for @taskDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get taskDone;

  /// No description provided for @calendarItemGone.
  ///
  /// In en, this message translates to:
  /// **'This item is not in the shown range any more.'**
  String get calendarItemGone;

  /// No description provided for @eventDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete this event?'**
  String get eventDeleteTitle;

  /// No description provided for @eventRepeats.
  ///
  /// In en, this message translates to:
  /// **'Repeats'**
  String get eventRepeats;

  /// No description provided for @taskAllowRun.
  ///
  /// In en, this message translates to:
  /// **'Run it now'**
  String get taskAllowRun;

  /// No description provided for @taskDismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get taskDismiss;

  /// No description provided for @taskTargetGone.
  ///
  /// In en, this message translates to:
  /// **'Paused: its project is gone. Edit it and pick a new one.'**
  String get taskTargetGone;

  /// No description provided for @taskPaused.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get taskPaused;

  /// No description provided for @taskRunNow.
  ///
  /// In en, this message translates to:
  /// **'Run now'**
  String get taskRunNow;

  /// No description provided for @taskResume.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get taskResume;

  /// No description provided for @taskPause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get taskPause;

  /// No description provided for @legendEvent.
  ///
  /// In en, this message translates to:
  /// **'Event'**
  String get legendEvent;

  /// No description provided for @calendarDayCount.
  ///
  /// In en, this message translates to:
  /// **'{day} · {count, plural, =1{1 item} other{{count} items}}'**
  String calendarDayCount(String day, int count);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when language+country codes are specified.
  switch (locale.languageCode) {
    case 'zh':
      {
        switch (locale.countryCode) {
          case 'TW':
            return AppLocalizationsZhTw();
        }
        break;
      }
  }

  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
