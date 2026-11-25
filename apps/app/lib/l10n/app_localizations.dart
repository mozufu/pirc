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
