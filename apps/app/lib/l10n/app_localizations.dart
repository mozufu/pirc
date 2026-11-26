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

  /// No description provided for @chatOnline.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get chatOnline;

  /// No description provided for @chatOffline.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get chatOffline;

  /// No description provided for @chatNewTooltip.
  ///
  /// In en, this message translates to:
  /// **'New pot or group'**
  String get chatNewTooltip;

  /// No description provided for @searchChat.
  ///
  /// In en, this message translates to:
  /// **'Search pots, groups and messages'**
  String get searchChat;

  /// No description provided for @chatFilterUnread.
  ///
  /// In en, this message translates to:
  /// **'Unread'**
  String get chatFilterUnread;

  /// No description provided for @chatFilterPots.
  ///
  /// In en, this message translates to:
  /// **'Pots'**
  String get chatFilterPots;

  /// No description provided for @chatFilterGroups.
  ///
  /// In en, this message translates to:
  /// **'Groups'**
  String get chatFilterGroups;

  /// No description provided for @chatEmptyFilter.
  ///
  /// In en, this message translates to:
  /// **'No chats here.'**
  String get chatEmptyFilter;

  /// No description provided for @chatNoMessages.
  ///
  /// In en, this message translates to:
  /// **'No messages yet'**
  String get chatNoMessages;

  /// No description provided for @chatAuthorYou.
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get chatAuthorYou;

  /// No description provided for @chatPreviewBy.
  ///
  /// In en, this message translates to:
  /// **'{name}: {message}'**
  String chatPreviewBy(String name, String message);

  /// No description provided for @groupMemberCount.
  ///
  /// In en, this message translates to:
  /// **'{count} people'**
  String groupMemberCount(int count);

  /// No description provided for @potPaused.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get potPaused;

  /// No description provided for @potWorking.
  ///
  /// In en, this message translates to:
  /// **'Working'**
  String get potWorking;

  /// No description provided for @potUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Unavailable'**
  String get potUnavailable;

  /// No description provided for @chatNewPot.
  ///
  /// In en, this message translates to:
  /// **'New pot'**
  String get chatNewPot;

  /// No description provided for @chatNewGroup.
  ///
  /// In en, this message translates to:
  /// **'Create group'**
  String get chatNewGroup;

  /// No description provided for @newSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'New'**
  String get newSheetTitle;

  /// No description provided for @newSheetNote.
  ///
  /// In en, this message translates to:
  /// **'New conversations (work) start from the top right of the Work tab.'**
  String get newSheetNote;

  /// No description provided for @newPotDetail.
  ///
  /// In en, this message translates to:
  /// **'Set its name, avatar, personality and what it looks after'**
  String get newPotDetail;

  /// No description provided for @newGroupDetail.
  ///
  /// In en, this message translates to:
  /// **'Bring a few pots together to talk, with one as host'**
  String get newGroupDetail;

  /// No description provided for @newGroupNeedsTwo.
  ///
  /// In en, this message translates to:
  /// **'Create at least two pots first'**
  String get newGroupNeedsTwo;

  /// No description provided for @approvalSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'{pot} wants to use {model}'**
  String approvalSheetTitle(String pot, String model);

  /// No description provided for @approvalRowWork.
  ///
  /// In en, this message translates to:
  /// **'Work'**
  String get approvalRowWork;

  /// No description provided for @approvalRowModel.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get approvalRowModel;

  /// No description provided for @approvalRowWhy.
  ///
  /// In en, this message translates to:
  /// **'Why'**
  String get approvalRowWhy;

  /// No description provided for @approvalRowBudget.
  ///
  /// In en, this message translates to:
  /// **'Budget'**
  String get approvalRowBudget;

  /// No description provided for @approvalNotStarted.
  ///
  /// In en, this message translates to:
  /// **'Not started'**
  String get approvalNotStarted;

  /// No description provided for @approvalEstimate.
  ///
  /// In en, this message translates to:
  /// **'Estimated {cost} · {pot} has {left} left this month'**
  String approvalEstimate(String cost, String pot, String left);

  /// No description provided for @approvalEstimateNoLimit.
  ///
  /// In en, this message translates to:
  /// **'Estimated {cost} · no money limit'**
  String approvalEstimateNoLimit(String cost);

  /// No description provided for @approvalNote.
  ///
  /// In en, this message translates to:
  /// **'You set {model} to “Ask you”. Allowing works for this time only; to stop being asked, change it to “Direct” in {pot}\'s settings.'**
  String approvalNote(String model, String pot);

  /// No description provided for @deny.
  ///
  /// In en, this message translates to:
  /// **'Deny'**
  String get deny;

  /// No description provided for @denyWithReason.
  ///
  /// In en, this message translates to:
  /// **'Deny with a reason'**
  String get denyWithReason;

  /// No description provided for @allowOnce.
  ///
  /// In en, this message translates to:
  /// **'Allow once'**
  String get allowOnce;

  /// No description provided for @denyReasonHint.
  ///
  /// In en, this message translates to:
  /// **'Tell {pot} why, for example “Compare once more with Sonnet and list what differs”'**
  String denyReasonHint(String pot);

  /// No description provided for @denyAndSend.
  ///
  /// In en, this message translates to:
  /// **'Deny and send the reason'**
  String get denyAndSend;

  /// No description provided for @answered.
  ///
  /// In en, this message translates to:
  /// **'Answered'**
  String get answered;

  /// No description provided for @answeredAllowedOnce.
  ///
  /// In en, this message translates to:
  /// **'Allowed once'**
  String get answeredAllowedOnce;

  /// No description provided for @answeredUsed.
  ///
  /// In en, this message translates to:
  /// **'Allowed once (used)'**
  String get answeredUsed;

  /// No description provided for @answeredDenied.
  ///
  /// In en, this message translates to:
  /// **'Denied'**
  String get answeredDenied;

  /// No description provided for @answeredDeniedWithReason.
  ///
  /// In en, this message translates to:
  /// **'Denied: {reason}'**
  String answeredDeniedWithReason(String reason);

  /// No description provided for @budgetSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'{pot} asks for more budget'**
  String budgetSheetTitle(String pot);

  /// No description provided for @budgetRowAsk.
  ///
  /// In en, this message translates to:
  /// **'Asks for'**
  String get budgetRowAsk;

  /// No description provided for @budgetMoreMoney.
  ///
  /// In en, this message translates to:
  /// **'{amount} more this month'**
  String budgetMoreMoney(String amount);

  /// No description provided for @budgetMoreTokens.
  ///
  /// In en, this message translates to:
  /// **'{tokens} more tokens today'**
  String budgetMoreTokens(String tokens);

  /// No description provided for @budgetLeftMoney.
  ///
  /// In en, this message translates to:
  /// **'{amount} left this month'**
  String budgetLeftMoney(String amount);

  /// No description provided for @budgetLeftTokens.
  ///
  /// In en, this message translates to:
  /// **'{tokens} tokens left today'**
  String budgetLeftTokens(String tokens);

  /// No description provided for @budgetNote.
  ///
  /// In en, this message translates to:
  /// **'Approving raises {pot}\'s limit for the current period only.'**
  String budgetNote(String pot);

  /// No description provided for @approve.
  ///
  /// In en, this message translates to:
  /// **'Approve'**
  String get approve;

  /// No description provided for @approveOtherAmount.
  ///
  /// In en, this message translates to:
  /// **'Approve another amount'**
  String get approveOtherAmount;

  /// No description provided for @approveThisAmount.
  ///
  /// In en, this message translates to:
  /// **'Approve this amount'**
  String get approveThisAmount;

  /// No description provided for @budgetAmountMoneyHint.
  ///
  /// In en, this message translates to:
  /// **'Amount in US dollars'**
  String get budgetAmountMoneyHint;

  /// No description provided for @budgetAmountTokensHint.
  ///
  /// In en, this message translates to:
  /// **'Number of tokens'**
  String get budgetAmountTokensHint;

  /// No description provided for @answeredApproved.
  ///
  /// In en, this message translates to:
  /// **'Approved'**
  String get answeredApproved;

  /// No description provided for @answeredApprovedAmount.
  ///
  /// In en, this message translates to:
  /// **'Approved {amount}'**
  String answeredApprovedAmount(String amount);

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

  /// No description provided for @controlledByName.
  ///
  /// In en, this message translates to:
  /// **'Controlled by {name}'**
  String controlledByName(String name);

  /// No description provided for @continuedOn.
  ///
  /// In en, this message translates to:
  /// **'Continued on {name}'**
  String continuedOn(String name);

  /// No description provided for @takeoverConfirm.
  ///
  /// In en, this message translates to:
  /// **'{name} was just working here. Send anyway?'**
  String takeoverConfirm(String name);

  /// No description provided for @anotherDevice.
  ///
  /// In en, this message translates to:
  /// **'Another device'**
  String get anotherDevice;

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

  /// No description provided for @thinkingMax.
  ///
  /// In en, this message translates to:
  /// **'Max'**
  String get thinkingMax;

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

  /// No description provided for @answeredOn.
  ///
  /// In en, this message translates to:
  /// **'Answered on {name} · {time}'**
  String answeredOn(String name, String time);

  /// No description provided for @answeredOnName.
  ///
  /// In en, this message translates to:
  /// **'Answered on {name}'**
  String answeredOnName(String name);

  /// No description provided for @questionAnswered.
  ///
  /// In en, this message translates to:
  /// **'Answered'**
  String get questionAnswered;

  /// No description provided for @questionWithdrawn.
  ///
  /// In en, this message translates to:
  /// **'Withdrawn'**
  String get questionWithdrawn;

  /// No description provided for @questionStale.
  ///
  /// In en, this message translates to:
  /// **'Ended when the session restarted'**
  String get questionStale;

  /// No description provided for @questionEnded.
  ///
  /// In en, this message translates to:
  /// **'{title} · ended'**
  String questionEnded(String title);

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

  /// No description provided for @potBarOpen.
  ///
  /// In en, this message translates to:
  /// **'open the conversation with {name}'**
  String potBarOpen(String name);

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

  /// No description provided for @settingsThisDevice.
  ///
  /// In en, this message translates to:
  /// **'This device'**
  String get settingsThisDevice;

  /// No description provided for @thisDeviceWebHint.
  ///
  /// In en, this message translates to:
  /// **'Leave empty to let the Gateway name it from the browser.'**
  String get thisDeviceWebHint;

  /// No description provided for @thisDeviceNameRule.
  ///
  /// In en, this message translates to:
  /// **'A name must be 1 to 60 characters.'**
  String get thisDeviceNameRule;

  /// No description provided for @thisDeviceSaved.
  ///
  /// In en, this message translates to:
  /// **'Device name saved.'**
  String get thisDeviceSaved;

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

  /// No description provided for @notificationChecking.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting and checking the latest state'**
  String get notificationChecking;

  /// No description provided for @notificationHandled.
  ///
  /// In en, this message translates to:
  /// **'This was already handled'**
  String get notificationHandled;

  /// No description provided for @notificationExpired.
  ///
  /// In en, this message translates to:
  /// **'This question expired'**
  String get notificationExpired;

  /// No description provided for @notificationExpiredDetail.
  ///
  /// In en, this message translates to:
  /// **'It can no longer be answered.'**
  String get notificationExpiredDetail;

  /// No description provided for @notificationOffline.
  ///
  /// In en, this message translates to:
  /// **'Could not check the latest state'**
  String get notificationOffline;

  /// No description provided for @notificationChoiceKept.
  ///
  /// In en, this message translates to:
  /// **'Your choice is kept: {choice}'**
  String notificationChoiceKept(String choice);

  /// No description provided for @notificationOpenConversation.
  ///
  /// In en, this message translates to:
  /// **'Open conversation'**
  String get notificationOpenConversation;

  /// No description provided for @answerSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'Confirm your answer'**
  String get answerSheetTitle;

  /// No description provided for @answerSheetCheckedHere.
  ///
  /// In en, this message translates to:
  /// **'From the notification · checked at {time}: the question is still open, control on this device'**
  String answerSheetCheckedHere(String time);

  /// No description provided for @answerSheetChecked.
  ///
  /// In en, this message translates to:
  /// **'From the notification · checked at {time}: the question is still open'**
  String answerSheetChecked(String time);

  /// No description provided for @answerSheetControlledBy.
  ///
  /// In en, this message translates to:
  /// **'Controlled by {name}. Take control to send.'**
  String answerSheetControlledBy(String name);

  /// No description provided for @answerSheetTakeControl.
  ///
  /// In en, this message translates to:
  /// **'Take control'**
  String get answerSheetTakeControl;

  /// No description provided for @answerSheetSend.
  ///
  /// In en, this message translates to:
  /// **'Send answer'**
  String get answerSheetSend;

  /// No description provided for @pushThisPhoneOn.
  ///
  /// In en, this message translates to:
  /// **'This phone gets notifications'**
  String get pushThisPhoneOn;

  /// No description provided for @pushThisPhoneOff.
  ///
  /// In en, this message translates to:
  /// **'This phone gets no notifications'**
  String get pushThisPhoneOff;

  /// No description provided for @pushConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting to the distributor…'**
  String get pushConnecting;

  /// No description provided for @pushSetupFailed.
  ///
  /// In en, this message translates to:
  /// **'Push could not be set up'**
  String get pushSetupFailed;

  /// No description provided for @pushLastDelivered.
  ///
  /// In en, this message translates to:
  /// **'last delivered {time}'**
  String pushLastDelivered(String time);

  /// No description provided for @pushThisDevice.
  ///
  /// In en, this message translates to:
  /// **'This phone'**
  String get pushThisDevice;

  /// No description provided for @pushOn.
  ///
  /// In en, this message translates to:
  /// **'Push notifications'**
  String get pushOn;

  /// No description provided for @pushDistributor.
  ///
  /// In en, this message translates to:
  /// **'Distributor'**
  String get pushDistributor;

  /// No description provided for @pushChooseDistributor.
  ///
  /// In en, this message translates to:
  /// **'Choose'**
  String get pushChooseDistributor;

  /// No description provided for @pushNoDistributor.
  ///
  /// In en, this message translates to:
  /// **'No UnifiedPush distributor is installed. Install one, such as ntfy, then come back to turn push on.'**
  String get pushNoDistributor;

  /// No description provided for @pushConflict.
  ///
  /// In en, this message translates to:
  /// **'These settings were changed elsewhere. The current values are shown; make your change again.'**
  String get pushConflict;

  /// No description provided for @pushTargetGone.
  ///
  /// In en, this message translates to:
  /// **'The Gateway no longer has this phone. Turn push off and on again.'**
  String get pushTargetGone;

  /// No description provided for @pushCategories.
  ///
  /// In en, this message translates to:
  /// **'Categories'**
  String get pushCategories;

  /// No description provided for @pushCategoryNeedsYou.
  ///
  /// In en, this message translates to:
  /// **'Needs you'**
  String get pushCategoryNeedsYou;

  /// No description provided for @pushCategoryNeedsYouNote.
  ///
  /// In en, this message translates to:
  /// **'Questions, missed runs, model approvals, budget requests, handovers'**
  String get pushCategoryNeedsYouNote;

  /// No description provided for @pushCategoryDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get pushCategoryDone;

  /// No description provided for @pushCategoryDoneNote.
  ///
  /// In en, this message translates to:
  /// **'Finished schedules, pot replies, what pots noticed'**
  String get pushCategoryDoneNote;

  /// No description provided for @pushCategoryProgress.
  ///
  /// In en, this message translates to:
  /// **'Progress'**
  String get pushCategoryProgress;

  /// No description provided for @pushCategoryProgressNote.
  ///
  /// In en, this message translates to:
  /// **'A pot opening work'**
  String get pushCategoryProgressNote;

  /// No description provided for @pushCategoryCalendar.
  ///
  /// In en, this message translates to:
  /// **'Calendar reminders'**
  String get pushCategoryCalendar;

  /// No description provided for @pushCategoryCalendarNote.
  ///
  /// In en, this message translates to:
  /// **'Reminders of your events'**
  String get pushCategoryCalendarNote;

  /// No description provided for @pushLevelImmediate.
  ///
  /// In en, this message translates to:
  /// **'At once'**
  String get pushLevelImmediate;

  /// No description provided for @pushLevelDigest.
  ///
  /// In en, this message translates to:
  /// **'Summary'**
  String get pushLevelDigest;

  /// No description provided for @pushLevelOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get pushLevelOff;

  /// No description provided for @pushDigestAt.
  ///
  /// In en, this message translates to:
  /// **'Summary time'**
  String get pushDigestAt;

  /// No description provided for @pushDigestAtNote.
  ///
  /// In en, this message translates to:
  /// **'Items set to Summary arrive together once a day.'**
  String get pushDigestAtNote;

  /// No description provided for @pushQuietHours.
  ///
  /// In en, this message translates to:
  /// **'Quiet hours'**
  String get pushQuietHours;

  /// No description provided for @pushQuietHoursNote.
  ///
  /// In en, this message translates to:
  /// **'Needs-you items arrive silently; done and progress wait for the summary when quiet hours end.'**
  String get pushQuietHoursNote;

  /// No description provided for @pushQuietStart.
  ///
  /// In en, this message translates to:
  /// **'Starts'**
  String get pushQuietStart;

  /// No description provided for @pushQuietEnd.
  ///
  /// In en, this message translates to:
  /// **'Ends'**
  String get pushQuietEnd;

  /// No description provided for @pushLockScreen.
  ///
  /// In en, this message translates to:
  /// **'Lock screen'**
  String get pushLockScreen;

  /// No description provided for @pushLockScreenShows.
  ///
  /// In en, this message translates to:
  /// **'Show'**
  String get pushLockScreenShows;

  /// No description provided for @pushLockHidden.
  ///
  /// In en, this message translates to:
  /// **'No content'**
  String get pushLockHidden;

  /// No description provided for @pushLockTitle.
  ///
  /// In en, this message translates to:
  /// **'Title only'**
  String get pushLockTitle;

  /// No description provided for @pushLockFull.
  ///
  /// In en, this message translates to:
  /// **'Everything'**
  String get pushLockFull;

  /// No description provided for @pushLockScreenNote.
  ///
  /// In en, this message translates to:
  /// **'Android shows only the title when its lock screen setting hides sensitive notification content (Settings → Notifications → Notifications on lock screen). With that setting off, Android shows the whole notification; \"No content\" always hides it.'**
  String get pushLockScreenNote;

  /// No description provided for @pushTimeZone.
  ///
  /// In en, this message translates to:
  /// **'Times are in {zone}.'**
  String pushTimeZone(String zone);

  /// No description provided for @pushPermissionTitle.
  ///
  /// In en, this message translates to:
  /// **'Permission'**
  String get pushPermissionTitle;

  /// No description provided for @pushPermissionGranted.
  ///
  /// In en, this message translates to:
  /// **'pirc may show notifications'**
  String get pushPermissionGranted;

  /// No description provided for @pushPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Android does not let pirc show notifications'**
  String get pushPermissionDenied;

  /// No description provided for @pushPermissionAsk.
  ///
  /// In en, this message translates to:
  /// **'Allow'**
  String get pushPermissionAsk;

  /// No description provided for @pushChannelsNote.
  ///
  /// In en, this message translates to:
  /// **'Sound, vibration and pop-ups are set per category in Android\'s notification settings.'**
  String get pushChannelsNote;

  /// No description provided for @pushOpenSystemSettings.
  ///
  /// In en, this message translates to:
  /// **'Open system notification settings'**
  String get pushOpenSystemSettings;

  /// No description provided for @pushStyle.
  ///
  /// In en, this message translates to:
  /// **'Style'**
  String get pushStyle;

  /// No description provided for @quickReplyOverlay.
  ///
  /// In en, this message translates to:
  /// **'Quick reply over other apps'**
  String get quickReplyOverlay;

  /// No description provided for @quickReplyOverlayNote.
  ///
  /// In en, this message translates to:
  /// **'Shows the question and its choices over other apps, and checks the latest state before you can send. Needs \"Display over other apps\"; without it a normal notification is shown.'**
  String get quickReplyOverlayNote;

  /// No description provided for @quickReplyOverlayWaiting.
  ///
  /// In en, this message translates to:
  /// **'Off until \"Display over other apps\" is allowed.'**
  String get quickReplyOverlayWaiting;

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

  /// No description provided for @taskSkipAsk.
  ///
  /// In en, this message translates to:
  /// **'Skip this missed run?'**
  String get taskSkipAsk;

  /// No description provided for @taskSkipAskNote.
  ///
  /// In en, this message translates to:
  /// **'It will not run. The task runs again at its next time.'**
  String get taskSkipAskNote;

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

  /// No description provided for @projectRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove project…'**
  String get projectRemove;

  /// No description provided for @projectRemoveTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove {name}?'**
  String projectRemoveTitle(String name);

  /// No description provided for @projectRemoveBody.
  ///
  /// In en, this message translates to:
  /// **'It leaves your lists and its agent tasks pause. Its folder, files and history stay on the host; adding the same folder again brings it back.'**
  String get projectRemoveBody;

  /// No description provided for @projectRemoveConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get projectRemoveConfirm;

  /// No description provided for @projectRemoveOffline.
  ///
  /// In en, this message translates to:
  /// **'The host is offline. Connect it so it can confirm the project is idle, then try again.'**
  String get projectRemoveOffline;

  /// No description provided for @projectConversations.
  ///
  /// In en, this message translates to:
  /// **'Conversations'**
  String get projectConversations;

  /// No description provided for @projectResources.
  ///
  /// In en, this message translates to:
  /// **'Resources'**
  String get projectResources;

  /// No description provided for @projectRules.
  ///
  /// In en, this message translates to:
  /// **'Rules'**
  String get projectRules;

  /// No description provided for @capMemorySearch.
  ///
  /// In en, this message translates to:
  /// **'Search memory'**
  String get capMemorySearch;

  /// No description provided for @capRemoteRecall.
  ///
  /// In en, this message translates to:
  /// **'Recall from other conversations'**
  String get capRemoteRecall;

  /// No description provided for @capSchedules.
  ///
  /// In en, this message translates to:
  /// **'Create agent tasks'**
  String get capSchedules;

  /// No description provided for @capWebSearch.
  ///
  /// In en, this message translates to:
  /// **'Search the web'**
  String get capWebSearch;

  /// No description provided for @projectConfigChanged.
  ///
  /// In en, this message translates to:
  /// **'The project config changed. Review it again before trusting it.'**
  String get projectConfigChanged;

  /// No description provided for @projectConfigInvalid.
  ///
  /// In en, this message translates to:
  /// **'The project config is not valid.'**
  String get projectConfigInvalid;

  /// No description provided for @projectConfigEmpty.
  ///
  /// In en, this message translates to:
  /// **'This project has no config to trust.'**
  String get projectConfigEmpty;

  /// No description provided for @projectTrusted.
  ///
  /// In en, this message translates to:
  /// **'Trusted: its hooks and settings run.'**
  String get projectTrusted;

  /// No description provided for @projectNotTrusted.
  ///
  /// In en, this message translates to:
  /// **'Not trusted: its hooks and settings do not run.'**
  String get projectNotTrusted;

  /// No description provided for @projectUntrust.
  ///
  /// In en, this message translates to:
  /// **'Withdraw trust'**
  String get projectUntrust;

  /// No description provided for @projectTrust.
  ///
  /// In en, this message translates to:
  /// **'Trust'**
  String get projectTrust;

  /// No description provided for @projectCreated.
  ///
  /// In en, this message translates to:
  /// **'{name} was added.'**
  String projectCreated(String name);

  /// No description provided for @projectNew.
  ///
  /// In en, this message translates to:
  /// **'New project'**
  String get projectNew;

  /// No description provided for @projectHost.
  ///
  /// In en, this message translates to:
  /// **'Host'**
  String get projectHost;

  /// No description provided for @projectName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get projectName;

  /// No description provided for @projectPath.
  ///
  /// In en, this message translates to:
  /// **'Folder on the host'**
  String get projectPath;

  /// No description provided for @projectCreate.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get projectCreate;

  /// No description provided for @browserRecordings.
  ///
  /// In en, this message translates to:
  /// **'Recordings'**
  String get browserRecordings;

  /// No description provided for @browserRecordingLoad.
  ///
  /// In en, this message translates to:
  /// **'Load'**
  String get browserRecordingLoad;

  /// No description provided for @browserRecordingFailed.
  ///
  /// In en, this message translates to:
  /// **'The recording could not be loaded.'**
  String get browserRecordingFailed;

  /// No description provided for @browserRecordingOpen.
  ///
  /// In en, this message translates to:
  /// **'Open in another app'**
  String get browserRecordingOpen;

  /// No description provided for @browserRecordingSize.
  ///
  /// In en, this message translates to:
  /// **'{megabytes} MB'**
  String browserRecordingSize(String megabytes);

  /// No description provided for @browserRecordingPlay.
  ///
  /// In en, this message translates to:
  /// **'Play in the app'**
  String get browserRecordingPlay;

  /// No description provided for @recordingPlay.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get recordingPlay;

  /// No description provided for @recordingPause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get recordingPause;

  /// No description provided for @recordingPosition.
  ///
  /// In en, this message translates to:
  /// **'{position} of {duration}'**
  String recordingPosition(String position, String duration);

  /// No description provided for @recordingSpeed.
  ///
  /// In en, this message translates to:
  /// **'Playback speed'**
  String get recordingSpeed;

  /// No description provided for @recordingSave.
  ///
  /// In en, this message translates to:
  /// **'Save to Downloads'**
  String get recordingSave;

  /// No description provided for @recordingClose.
  ///
  /// In en, this message translates to:
  /// **'Close the player'**
  String get recordingClose;

  /// No description provided for @recordingSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved to Downloads as {name}.'**
  String recordingSaved(String name);

  /// No description provided for @recordingSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'The recording could not be saved.'**
  String get recordingSaveFailed;

  /// No description provided for @recordingPlaybackFailed.
  ///
  /// In en, this message translates to:
  /// **'The recording could not be played.'**
  String get recordingPlaybackFailed;

  /// No description provided for @imageLabel.
  ///
  /// In en, this message translates to:
  /// **'Image'**
  String get imageLabel;

  /// No description provided for @imageUnreadable.
  ///
  /// In en, this message translates to:
  /// **'This image cannot be shown.'**
  String get imageUnreadable;

  /// No description provided for @statusCompleted.
  ///
  /// In en, this message translates to:
  /// **'Completed'**
  String get statusCompleted;

  /// No description provided for @statusStopped.
  ///
  /// In en, this message translates to:
  /// **'Stopped'**
  String get statusStopped;

  /// No description provided for @statusTimedOut.
  ///
  /// In en, this message translates to:
  /// **'Timed out'**
  String get statusTimedOut;

  /// No description provided for @statusPending.
  ///
  /// In en, this message translates to:
  /// **'Waiting'**
  String get statusPending;

  /// No description provided for @statusInProgress.
  ///
  /// In en, this message translates to:
  /// **'In progress'**
  String get statusInProgress;

  /// No description provided for @jobPreparing.
  ///
  /// In en, this message translates to:
  /// **'Preparing'**
  String get jobPreparing;

  /// No description provided for @jobReady.
  ///
  /// In en, this message translates to:
  /// **'Ready'**
  String get jobReady;

  /// No description provided for @jobOpened.
  ///
  /// In en, this message translates to:
  /// **'Opened'**
  String get jobOpened;

  /// No description provided for @jobStale.
  ///
  /// In en, this message translates to:
  /// **'Out of date'**
  String get jobStale;

  /// No description provided for @jobInterrupted.
  ///
  /// In en, this message translates to:
  /// **'Interrupted'**
  String get jobInterrupted;

  /// No description provided for @operationRecorded.
  ///
  /// In en, this message translates to:
  /// **'Recorded'**
  String get operationRecorded;

  /// No description provided for @resultKindMarkdown.
  ///
  /// In en, this message translates to:
  /// **'Document'**
  String get resultKindMarkdown;

  /// No description provided for @resultKindCode.
  ///
  /// In en, this message translates to:
  /// **'Code'**
  String get resultKindCode;

  /// No description provided for @resultKindTable.
  ///
  /// In en, this message translates to:
  /// **'Table'**
  String get resultKindTable;

  /// No description provided for @timeZone.
  ///
  /// In en, this message translates to:
  /// **'Time zone'**
  String get timeZone;

  /// No description provided for @timeZoneDevice.
  ///
  /// In en, this message translates to:
  /// **'This device\'s (UTC{offset})'**
  String timeZoneDevice(String offset);

  /// No description provided for @timeZoneUtc.
  ///
  /// In en, this message translates to:
  /// **'UTC{offset}'**
  String timeZoneUtc(String offset);

  /// No description provided for @timeZoneNote.
  ///
  /// In en, this message translates to:
  /// **'The calendar shows times and creates events and tasks in this time zone.'**
  String get timeZoneNote;

  /// No description provided for @newPotTitle.
  ///
  /// In en, this message translates to:
  /// **'New pot'**
  String get newPotTitle;

  /// No description provided for @newPotStep.
  ///
  /// In en, this message translates to:
  /// **'{step} / 4 · {title}'**
  String newPotStep(int step, String title);

  /// No description provided for @newPotStepLook.
  ///
  /// In en, this message translates to:
  /// **'Look and personality'**
  String get newPotStepLook;

  /// No description provided for @newPotStepWork.
  ///
  /// In en, this message translates to:
  /// **'Work'**
  String get newPotStepWork;

  /// No description provided for @newPotStepReach.
  ///
  /// In en, this message translates to:
  /// **'What it can do'**
  String get newPotStepReach;

  /// No description provided for @newPotStepModels.
  ///
  /// In en, this message translates to:
  /// **'Models'**
  String get newPotStepModels;

  /// No description provided for @newPotNext.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get newPotNext;

  /// No description provided for @newPotCreate.
  ///
  /// In en, this message translates to:
  /// **'Create {name}'**
  String newPotCreate(String name);

  /// No description provided for @newPotCreatePlain.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get newPotCreatePlain;

  /// No description provided for @potThisPot.
  ///
  /// In en, this message translates to:
  /// **'this pot'**
  String get potThisPot;

  /// No description provided for @potAvatarColors.
  ///
  /// In en, this message translates to:
  /// **'Avatar colour'**
  String get potAvatarColors;

  /// No description provided for @potAvatarColor.
  ///
  /// In en, this message translates to:
  /// **'Colour {n}'**
  String potAvatarColor(int n);

  /// No description provided for @potAvatarUpload.
  ///
  /// In en, this message translates to:
  /// **'Upload a picture'**
  String get potAvatarUpload;

  /// No description provided for @potAvatarNote.
  ///
  /// In en, this message translates to:
  /// **'The avatar shows the name\'s first letter by default'**
  String get potAvatarNote;

  /// No description provided for @potAvatarChoose.
  ///
  /// In en, this message translates to:
  /// **'Choose another picture'**
  String get potAvatarChoose;

  /// No description provided for @potAvatarRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove the picture'**
  String get potAvatarRemove;

  /// No description provided for @potAvatarUploading.
  ///
  /// In en, this message translates to:
  /// **'Uploading the picture…'**
  String get potAvatarUploading;

  /// No description provided for @potGroupBasic.
  ///
  /// In en, this message translates to:
  /// **'Basic'**
  String get potGroupBasic;

  /// No description provided for @potName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get potName;

  /// No description provided for @potNameHint.
  ///
  /// In en, this message translates to:
  /// **'What to call it'**
  String get potNameHint;

  /// No description provided for @potGroupPersonality.
  ///
  /// In en, this message translates to:
  /// **'Personality (soul)'**
  String get potGroupPersonality;

  /// No description provided for @potTemplateRigorous.
  ///
  /// In en, this message translates to:
  /// **'Rigorous'**
  String get potTemplateRigorous;

  /// No description provided for @potTemplateConcise.
  ///
  /// In en, this message translates to:
  /// **'Concise'**
  String get potTemplateConcise;

  /// No description provided for @potTemplateFriendly.
  ///
  /// In en, this message translates to:
  /// **'Friendly'**
  String get potTemplateFriendly;

  /// No description provided for @potTemplateCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get potTemplateCustom;

  /// No description provided for @potTemplateRigorousText.
  ///
  /// In en, this message translates to:
  /// **'Precise and careful. Checks facts before answering, says when unsure, and prefers correctness over speed.'**
  String get potTemplateRigorousText;

  /// No description provided for @potTemplateConciseText.
  ///
  /// In en, this message translates to:
  /// **'Brief and direct. Answers in as few words as possible and skips pleasantries.'**
  String get potTemplateConciseText;

  /// No description provided for @potTemplateFriendlyText.
  ///
  /// In en, this message translates to:
  /// **'Warm and encouraging. Explains things plainly and checks that the user is comfortable with the next step.'**
  String get potTemplateFriendlyText;

  /// No description provided for @potPersonalityHint.
  ///
  /// In en, this message translates to:
  /// **'How it talks'**
  String get potPersonalityHint;

  /// No description provided for @potPersonalityNote.
  ///
  /// In en, this message translates to:
  /// **'Personality only changes how it talks; it gives no permissions.'**
  String get potPersonalityNote;

  /// No description provided for @potGroupPreview.
  ///
  /// In en, this message translates to:
  /// **'Speech preview'**
  String get potGroupPreview;

  /// No description provided for @potPreviewRigorous.
  ///
  /// In en, this message translates to:
  /// **'Found it: with the iPad\'s floating keyboard, viewInsets reports 0. Source: the Flutter MediaQuery docs.'**
  String get potPreviewRigorous;

  /// No description provided for @potPreviewConcise.
  ///
  /// In en, this message translates to:
  /// **'Floating keyboard: viewInsets is 0.'**
  String get potPreviewConcise;

  /// No description provided for @potPreviewFriendly.
  ///
  /// In en, this message translates to:
  /// **'Good news, I found it! With the floating keyboard, viewInsets is 0. Shall I show you where that is in the docs?'**
  String get potPreviewFriendly;

  /// No description provided for @potPreviewCustom.
  ///
  /// In en, this message translates to:
  /// **'Here is what I found about viewInsets with the floating keyboard.'**
  String get potPreviewCustom;

  /// No description provided for @potPreviewNote.
  ///
  /// In en, this message translates to:
  /// **'Preview, not a real reply'**
  String get potPreviewNote;

  /// No description provided for @potGroupIntro.
  ///
  /// In en, this message translates to:
  /// **'Intro'**
  String get potGroupIntro;

  /// No description provided for @potIntroHint.
  ///
  /// In en, this message translates to:
  /// **'One line about what it does'**
  String get potIntroHint;

  /// No description provided for @potIntroNote.
  ///
  /// In en, this message translates to:
  /// **'Shown in the chat list and the @ menu, so you and other pots know whom to ask.'**
  String get potIntroNote;

  /// No description provided for @potGroupDescription.
  ///
  /// In en, this message translates to:
  /// **'Work description'**
  String get potGroupDescription;

  /// No description provided for @potDescriptionHint.
  ///
  /// In en, this message translates to:
  /// **'How it should work'**
  String get potDescriptionHint;

  /// No description provided for @potDescriptionNote.
  ///
  /// In en, this message translates to:
  /// **'Tells it how to work. Like the personality, nothing here gives it permissions.'**
  String get potDescriptionNote;

  /// No description provided for @potGroupResponsibilities.
  ///
  /// In en, this message translates to:
  /// **'Responsibilities'**
  String get potGroupResponsibilities;

  /// No description provided for @potAddResponsibility.
  ///
  /// In en, this message translates to:
  /// **'Add a responsibility'**
  String get potAddResponsibility;

  /// No description provided for @potResponsibilityNew.
  ///
  /// In en, this message translates to:
  /// **'New responsibility'**
  String get potResponsibilityNew;

  /// No description provided for @potResponsibilityEdit.
  ///
  /// In en, this message translates to:
  /// **'Responsibility'**
  String get potResponsibilityEdit;

  /// No description provided for @potResponsibilityTitle.
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get potResponsibilityTitle;

  /// No description provided for @potResponsibilityDetail.
  ///
  /// In en, this message translates to:
  /// **'Detail (optional)'**
  String get potResponsibilityDetail;

  /// No description provided for @potMoveUp.
  ///
  /// In en, this message translates to:
  /// **'Move up'**
  String get potMoveUp;

  /// No description provided for @potMoveDown.
  ///
  /// In en, this message translates to:
  /// **'Move down'**
  String get potMoveDown;

  /// No description provided for @potRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get potRemove;

  /// No description provided for @potTooLong.
  ///
  /// In en, this message translates to:
  /// **'At most {max} characters'**
  String potTooLong(int max);

  /// No description provided for @potNameMissing.
  ///
  /// In en, this message translates to:
  /// **'Give it a name'**
  String get potNameMissing;

  /// No description provided for @potGroupReach.
  ///
  /// In en, this message translates to:
  /// **'How far it can go'**
  String get potGroupReach;

  /// No description provided for @potReachAnswer.
  ///
  /// In en, this message translates to:
  /// **'Only answer you'**
  String get potReachAnswer;

  /// No description provided for @potReachAnswerDetail.
  ///
  /// In en, this message translates to:
  /// **'Doesn\'t watch anything and can\'t start work'**
  String get potReachAnswerDetail;

  /// No description provided for @potReachObserve.
  ///
  /// In en, this message translates to:
  /// **'Watch and suggest'**
  String get potReachObserve;

  /// No description provided for @potReachObserveDetail.
  ///
  /// In en, this message translates to:
  /// **'Watches only what you allow; you decide on its suggestions'**
  String get potReachObserveDetail;

  /// No description provided for @potReachWork.
  ///
  /// In en, this message translates to:
  /// **'Can start work'**
  String get potReachWork;

  /// No description provided for @potReachWorkDetail.
  ///
  /// In en, this message translates to:
  /// **'Opens work where you allow; each work is marked From {name} and uses its budget'**
  String potReachWorkDetail(String name);

  /// No description provided for @potGroupObserve.
  ///
  /// In en, this message translates to:
  /// **'What it can see'**
  String get potGroupObserve;

  /// No description provided for @potObserveCalendar.
  ///
  /// In en, this message translates to:
  /// **'Calendar'**
  String get potObserveCalendar;

  /// No description provided for @potObserveCalendarDetail.
  ///
  /// In en, this message translates to:
  /// **'Your calendar\'s events'**
  String get potObserveCalendarDetail;

  /// No description provided for @potObserveSchedules.
  ///
  /// In en, this message translates to:
  /// **'Schedules'**
  String get potObserveSchedules;

  /// No description provided for @potObserveSchedulesDetail.
  ///
  /// In en, this message translates to:
  /// **'Scheduled runs and their results'**
  String get potObserveSchedulesDetail;

  /// No description provided for @potObserveWorkspace.
  ///
  /// In en, this message translates to:
  /// **'Project'**
  String get potObserveWorkspace;

  /// No description provided for @potObserveProject.
  ///
  /// In en, this message translates to:
  /// **'Chat project'**
  String get potObserveProject;

  /// No description provided for @potObserveSession.
  ///
  /// In en, this message translates to:
  /// **'Work'**
  String get potObserveSession;

  /// No description provided for @potObserveWorkspaces.
  ///
  /// In en, this message translates to:
  /// **'Projects'**
  String get potObserveWorkspaces;

  /// No description provided for @potObserveProjects.
  ///
  /// In en, this message translates to:
  /// **'Chat projects'**
  String get potObserveProjects;

  /// No description provided for @potObserveSessions.
  ///
  /// In en, this message translates to:
  /// **'Works'**
  String get potObserveSessions;

  /// No description provided for @potObserveAdd.
  ///
  /// In en, this message translates to:
  /// **'Add a project or work'**
  String get potObserveAdd;

  /// No description provided for @potObserveNothing.
  ///
  /// In en, this message translates to:
  /// **'Nothing more to add.'**
  String get potObserveNothing;

  /// No description provided for @potObserveOff.
  ///
  /// In en, this message translates to:
  /// **'Only answering, it watches nothing. Choose “Watch and suggest” to let it see more.'**
  String get potObserveOff;

  /// No description provided for @potGroupDmSend.
  ///
  /// In en, this message translates to:
  /// **'Message other pots'**
  String get potGroupDmSend;

  /// No description provided for @potGroupDmReceive.
  ///
  /// In en, this message translates to:
  /// **'Messages from other pots'**
  String get potGroupDmReceive;

  /// No description provided for @potDmAll.
  ///
  /// In en, this message translates to:
  /// **'All pots'**
  String get potDmAll;

  /// No description provided for @potDmSelected.
  ///
  /// In en, this message translates to:
  /// **'Selected'**
  String get potDmSelected;

  /// No description provided for @potDmOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get potDmOff;

  /// No description provided for @potDmNoPots.
  ///
  /// In en, this message translates to:
  /// **'There are no other pots yet.'**
  String get potDmNoPots;

  /// No description provided for @potDmNote.
  ///
  /// In en, this message translates to:
  /// **'Messages are kept in Activity, where you can read them all. When off, {name} and other pots talk only in groups.'**
  String potDmNote(String name);

  /// No description provided for @potDmOffNote.
  ///
  /// In en, this message translates to:
  /// **'{name} won\'t message other pots; group conversations are not affected.'**
  String potDmOffNote(String name);

  /// No description provided for @potGroupWork.
  ///
  /// In en, this message translates to:
  /// **'Work'**
  String get potGroupWork;

  /// No description provided for @potWorkLocationAdd.
  ///
  /// In en, this message translates to:
  /// **'Add a place to open work'**
  String get potWorkLocationAdd;

  /// No description provided for @potWorkLocationsNone.
  ///
  /// In en, this message translates to:
  /// **'No project to add.'**
  String get potWorkLocationsNone;

  /// No description provided for @potAccessRead.
  ///
  /// In en, this message translates to:
  /// **'Read only'**
  String get potAccessRead;

  /// No description provided for @potAccessWrite.
  ///
  /// In en, this message translates to:
  /// **'Read and write'**
  String get potAccessWrite;

  /// No description provided for @potAccessLabel.
  ///
  /// In en, this message translates to:
  /// **'Access: {access}'**
  String potAccessLabel(String access);

  /// No description provided for @potRemoveNamed.
  ///
  /// In en, this message translates to:
  /// **'Remove {name}'**
  String potRemoveNamed(String name);

  /// No description provided for @potMaxWorks.
  ///
  /// In en, this message translates to:
  /// **'Works at the same time'**
  String get potMaxWorks;

  /// No description provided for @potMaxWorksValue.
  ///
  /// In en, this message translates to:
  /// **'At most {count}'**
  String potMaxWorksValue(int count);

  /// No description provided for @potFewer.
  ///
  /// In en, this message translates to:
  /// **'Fewer'**
  String get potFewer;

  /// No description provided for @potMore.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get potMore;

  /// No description provided for @potWorkNote.
  ///
  /// In en, this message translates to:
  /// **'Each work it opens is marked “From {name}”; you can take it over at any time.'**
  String potWorkNote(String name);

  /// No description provided for @potGroupBudget.
  ///
  /// In en, this message translates to:
  /// **'Budget'**
  String get potGroupBudget;

  /// No description provided for @potBudgetMoney.
  ///
  /// In en, this message translates to:
  /// **'Money per month'**
  String get potBudgetMoney;

  /// No description provided for @potBudgetTokens.
  ///
  /// In en, this message translates to:
  /// **'Tokens per day'**
  String get potBudgetTokens;

  /// No description provided for @potBudgetDollars.
  ///
  /// In en, this message translates to:
  /// **'US\$'**
  String get potBudgetDollars;

  /// No description provided for @potBudgetTokenUnit.
  ///
  /// In en, this message translates to:
  /// **'tokens'**
  String get potBudgetTokenUnit;

  /// No description provided for @potBudgetInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a number above 0'**
  String get potBudgetInvalid;

  /// No description provided for @potBudgetNote.
  ///
  /// In en, this message translates to:
  /// **'It and the work it opens all count. When a limit is used up it stops opening work and tells you. The token limit always applies: subscription use counts in money only when “Show API-equivalent price” is on.'**
  String get potBudgetNote;

  /// No description provided for @potGroupReview.
  ///
  /// In en, this message translates to:
  /// **'Reviews its own work'**
  String get potGroupReview;

  /// No description provided for @potReviewOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get potReviewOff;

  /// No description provided for @potReviewDay.
  ///
  /// In en, this message translates to:
  /// **'1 day'**
  String get potReviewDay;

  /// No description provided for @potReviewTwoDays.
  ///
  /// In en, this message translates to:
  /// **'2 days'**
  String get potReviewTwoDays;

  /// No description provided for @potReviewWeek.
  ///
  /// In en, this message translates to:
  /// **'1 week'**
  String get potReviewWeek;

  /// No description provided for @potReviewNote.
  ///
  /// In en, this message translates to:
  /// **'How often it looks back over its responsibilities and work by itself.'**
  String get potReviewNote;

  /// No description provided for @potReachNote.
  ///
  /// In en, this message translates to:
  /// **'You can change all of this later in {name}\'s settings. Smaller permissions apply at once; running work is checked again against them.'**
  String potReachNote(String name);

  /// No description provided for @potGroupOwnModels.
  ///
  /// In en, this message translates to:
  /// **'Models {name} uses'**
  String potGroupOwnModels(String name);

  /// No description provided for @potMainModel.
  ///
  /// In en, this message translates to:
  /// **'Main model'**
  String get potMainModel;

  /// No description provided for @potFallback.
  ///
  /// In en, this message translates to:
  /// **'Fallback {n}'**
  String potFallback(int n);

  /// No description provided for @potAddFallback.
  ///
  /// In en, this message translates to:
  /// **'Add a fallback'**
  String get potAddFallback;

  /// No description provided for @potRemoveFallback.
  ///
  /// In en, this message translates to:
  /// **'Remove this fallback'**
  String get potRemoveFallback;

  /// No description provided for @potModelsNote.
  ///
  /// In en, this message translates to:
  /// **'When the main model can\'t be used (budget used up, service down, host offline), the fallbacks are used in order; each switch is logged in Activity, and it switches back when the main model returns.'**
  String get potModelsNote;

  /// No description provided for @potNoModels.
  ///
  /// In en, this message translates to:
  /// **'The Gateway serves no models yet.'**
  String get potNoModels;

  /// No description provided for @potModelsLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading the models…'**
  String get potModelsLoading;

  /// No description provided for @potPickModel.
  ///
  /// In en, this message translates to:
  /// **'Choose a model'**
  String get potPickModel;

  /// No description provided for @potGroupThinking.
  ///
  /// In en, this message translates to:
  /// **'Thinking'**
  String get potGroupThinking;

  /// No description provided for @potThinkingNone.
  ///
  /// In en, this message translates to:
  /// **'This model has no thinking levels'**
  String get potThinkingNone;

  /// No description provided for @potThinkingAuto.
  ///
  /// In en, this message translates to:
  /// **'Adjust by itself'**
  String get potThinkingAuto;

  /// No description provided for @potThinkingAutoDetail.
  ///
  /// In en, this message translates to:
  /// **'Uses the level above, raising or lowering it when needed'**
  String get potThinkingAutoDetail;

  /// No description provided for @potThinkingAutoOn.
  ///
  /// In en, this message translates to:
  /// **'Usually “{level}”. It raises or lowers it by itself when needed, without asking you; each change is logged in Activity with the reason.'**
  String potThinkingAutoOn(String level);

  /// No description provided for @potThinkingAutoOff.
  ///
  /// In en, this message translates to:
  /// **'Always “{level}”; it doesn\'t change it by itself.'**
  String potThinkingAutoOff(String level);

  /// No description provided for @potGroupWorkModels.
  ///
  /// In en, this message translates to:
  /// **'Models for work'**
  String get potGroupWorkModels;

  /// No description provided for @potModeDirect.
  ///
  /// In en, this message translates to:
  /// **'Direct'**
  String get potModeDirect;

  /// No description provided for @potModeAsk.
  ///
  /// In en, this message translates to:
  /// **'Ask you'**
  String get potModeAsk;

  /// No description provided for @potModeLabel.
  ///
  /// In en, this message translates to:
  /// **'Use: {mode}'**
  String potModeLabel(String mode);

  /// No description provided for @potWorkModelsNote.
  ///
  /// In en, this message translates to:
  /// **'To use a stronger model, {name} opens a work, picks the model and talks to it; that work is marked From {name}. Models set to “Ask you” wait for your approval before the work opens.'**
  String potWorkModelsNote(String name);

  /// No description provided for @potWorkModelsOff.
  ///
  /// In en, this message translates to:
  /// **'In the last step you chose “{reach}”, so {name} can\'t open work and can\'t use other models. To let it use a stronger model, go back and choose “Can start work”.'**
  String potWorkModelsOff(String reach, String name);

  /// No description provided for @potHeaderAnswer.
  ///
  /// In en, this message translates to:
  /// **'Only answers you'**
  String get potHeaderAnswer;

  /// No description provided for @potHeaderObserve.
  ///
  /// In en, this message translates to:
  /// **'Observing'**
  String get potHeaderObserve;

  /// No description provided for @potHeaderWork.
  ///
  /// In en, this message translates to:
  /// **'Can open work'**
  String get potHeaderWork;

  /// No description provided for @potBudgetMonthUsed.
  ///
  /// In en, this message translates to:
  /// **'This month {used} / {limit}'**
  String potBudgetMonthUsed(String used, String limit);

  /// No description provided for @potBudgetDayUsed.
  ///
  /// In en, this message translates to:
  /// **'Today {used} / {limit} tokens'**
  String potBudgetDayUsed(String used, String limit);

  /// No description provided for @potProfileOf.
  ///
  /// In en, this message translates to:
  /// **'{name}\'s profile'**
  String potProfileOf(String name);

  /// No description provided for @threadDayToday.
  ///
  /// In en, this message translates to:
  /// **'Today {time}'**
  String threadDayToday(String time);

  /// No description provided for @threadDayYesterday.
  ///
  /// In en, this message translates to:
  /// **'Yesterday {time}'**
  String threadDayYesterday(String time);

  /// No description provided for @threadComposerHint.
  ///
  /// In en, this message translates to:
  /// **'Message {name}…'**
  String threadComposerHint(String name);

  /// No description provided for @threadReadOnlyDeleted.
  ///
  /// In en, this message translates to:
  /// **'{name} was deleted. This conversation is read-only.'**
  String threadReadOnlyDeleted(String name);

  /// No description provided for @threadReadOnlyArchived.
  ///
  /// In en, this message translates to:
  /// **'{name} is archived. This conversation is read-only.'**
  String threadReadOnlyArchived(String name);

  /// No description provided for @threadRefused.
  ///
  /// In en, this message translates to:
  /// **'{name} was not woken: {reason}'**
  String threadRefused(String name, String reason);

  /// No description provided for @threadFailed.
  ///
  /// In en, this message translates to:
  /// **'The conversation could not be loaded.'**
  String get threadFailed;

  /// No description provided for @cardReview.
  ///
  /// In en, this message translates to:
  /// **'Review'**
  String get cardReview;

  /// No description provided for @cardFailed.
  ///
  /// In en, this message translates to:
  /// **'This item could not be loaded.'**
  String get cardFailed;

  /// No description provided for @cardUnknown.
  ///
  /// In en, this message translates to:
  /// **'This version of the app can\'t show this item ({kind}).'**
  String cardUnknown(String kind);

  /// No description provided for @cardWorkCoordinatedBy.
  ///
  /// In en, this message translates to:
  /// **'Coordinated by {name}'**
  String cardWorkCoordinatedBy(String name);

  /// No description provided for @cardWorkTakenOver.
  ///
  /// In en, this message translates to:
  /// **'You took it over'**
  String get cardWorkTakenOver;

  /// No description provided for @cardWorkMissing.
  ///
  /// In en, this message translates to:
  /// **'This work is no longer available'**
  String get cardWorkMissing;

  /// No description provided for @cardHandoverTitle.
  ///
  /// In en, this message translates to:
  /// **'{pot} proposes a handover'**
  String cardHandoverTitle(String pot);

  /// No description provided for @cardHandoverTo.
  ///
  /// In en, this message translates to:
  /// **'To {to}'**
  String cardHandoverTo(String to);

  /// No description provided for @cardHandoverApplied.
  ///
  /// In en, this message translates to:
  /// **'Handover confirmed'**
  String get cardHandoverApplied;

  /// No description provided for @cardHandoverRejected.
  ///
  /// In en, this message translates to:
  /// **'Handover rejected'**
  String get cardHandoverRejected;

  /// No description provided for @cardLoopTitle.
  ///
  /// In en, this message translates to:
  /// **'Chain paused'**
  String get cardLoopTitle;

  /// No description provided for @cardLoopBody.
  ///
  /// In en, this message translates to:
  /// **'{pot} started it. Since the last progress: {wakes} wakes and {messages} messages.'**
  String cardLoopBody(String pot, int wakes, int messages);

  /// No description provided for @cardLoopLastProgress.
  ///
  /// In en, this message translates to:
  /// **'Last progress {time}'**
  String cardLoopLastProgress(String time);

  /// No description provided for @cardLoopResume.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get cardLoopResume;

  /// No description provided for @cardLoopStop.
  ///
  /// In en, this message translates to:
  /// **'Stop the chain'**
  String get cardLoopStop;

  /// No description provided for @cardLoopPause.
  ///
  /// In en, this message translates to:
  /// **'Pause the pots involved'**
  String get cardLoopPause;

  /// No description provided for @cardLoopStopConfirm.
  ///
  /// In en, this message translates to:
  /// **'Stop this chain? Its waiting messages are dropped, and it can\'t be resumed.'**
  String get cardLoopStopConfirm;

  /// No description provided for @cardLoopResumed.
  ///
  /// In en, this message translates to:
  /// **'Resumed'**
  String get cardLoopResumed;

  /// No description provided for @cardLoopStopped.
  ///
  /// In en, this message translates to:
  /// **'Chain stopped'**
  String get cardLoopStopped;

  /// No description provided for @cardLoopPotsPaused.
  ///
  /// In en, this message translates to:
  /// **'The pots involved are paused'**
  String get cardLoopPotsPaused;

  /// No description provided for @potActionMessage.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get potActionMessage;

  /// No description provided for @potActionPause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get potActionPause;

  /// No description provided for @potActionResume.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get potActionResume;

  /// No description provided for @potActionHandOver.
  ///
  /// In en, this message translates to:
  /// **'Hand over'**
  String get potActionHandOver;

  /// No description provided for @potActionActivity.
  ///
  /// In en, this message translates to:
  /// **'Activity'**
  String get potActionActivity;

  /// No description provided for @potHostsGroups.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Hosts 1 group} other{Hosts {count} groups}}'**
  String potHostsGroups(int count);

  /// No description provided for @potPausedBannerTitle.
  ///
  /// In en, this message translates to:
  /// **'Paused.'**
  String get potPausedBannerTitle;

  /// No description provided for @potPausedBannerText.
  ///
  /// In en, this message translates to:
  /// **'It does not observe, suggest or start new work; its responsibilities and follow-ups stay.'**
  String get potPausedBannerText;

  /// No description provided for @potProfileNoResponsibilities.
  ///
  /// In en, this message translates to:
  /// **'No responsibilities yet.'**
  String get potProfileNoResponsibilities;

  /// No description provided for @potProfileMayDo.
  ///
  /// In en, this message translates to:
  /// **'What it may do'**
  String get potProfileMayDo;

  /// No description provided for @potProfileObserveNothing.
  ///
  /// In en, this message translates to:
  /// **'Nothing yet'**
  String get potProfileObserveNothing;

  /// No description provided for @potProfileWorkPlaces.
  ///
  /// In en, this message translates to:
  /// **'Where it opens work'**
  String get potProfileWorkPlaces;

  /// No description provided for @potProfileNoPlaces.
  ///
  /// In en, this message translates to:
  /// **'Nowhere yet'**
  String get potProfileNoPlaces;

  /// No description provided for @potProfilePlace.
  ///
  /// In en, this message translates to:
  /// **'{name} ({access})'**
  String potProfilePlace(String name, String access);

  /// No description provided for @potProfileMoneyMonth.
  ///
  /// In en, this message translates to:
  /// **'{amount} a month'**
  String potProfileMoneyMonth(String amount);

  /// No description provided for @potProfileTokensDay.
  ///
  /// In en, this message translates to:
  /// **'{count} tokens a day'**
  String potProfileTokensDay(String count);

  /// No description provided for @potProfileReviewDays.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Every day} other{Every {count} days}}'**
  String potProfileReviewDays(int count);

  /// No description provided for @potProfileReviewWeekly.
  ///
  /// In en, this message translates to:
  /// **'Every week'**
  String get potProfileReviewWeekly;

  /// No description provided for @potListSeparator.
  ///
  /// In en, this message translates to:
  /// **', '**
  String get potListSeparator;

  /// No description provided for @potProfileActivity.
  ///
  /// In en, this message translates to:
  /// **'Recent activity'**
  String get potProfileActivity;

  /// No description provided for @potProfileSeeAll.
  ///
  /// In en, this message translates to:
  /// **'See all'**
  String get potProfileSeeAll;

  /// No description provided for @potProfileNoActivity.
  ///
  /// In en, this message translates to:
  /// **'Nothing yet.'**
  String get potProfileNoActivity;

  /// No description provided for @potProfileMemory.
  ///
  /// In en, this message translates to:
  /// **'Memory'**
  String get potProfileMemory;

  /// No description provided for @potProfileForget.
  ///
  /// In en, this message translates to:
  /// **'Forget'**
  String get potProfileForget;

  /// No description provided for @potProfileNoMemory.
  ///
  /// In en, this message translates to:
  /// **'No notes yet.'**
  String get potProfileNoMemory;

  /// No description provided for @potProfileMemoryNote.
  ///
  /// In en, this message translates to:
  /// **'Notes {name} keeps for itself; only it reads them. {used} of {budget} characters used.'**
  String potProfileMemoryNote(String name, String used, String budget);

  /// No description provided for @activityToYou.
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get activityToYou;

  /// No description provided for @potPauseTitle.
  ///
  /// In en, this message translates to:
  /// **'Pause {name}?'**
  String potPauseTitle(String name);

  /// No description provided for @potPauseWhile.
  ///
  /// In en, this message translates to:
  /// **'While paused'**
  String get potPauseWhile;

  /// No description provided for @potPauseNoDelivery.
  ///
  /// In en, this message translates to:
  /// **'No new messages or events reach it'**
  String get potPauseNoDelivery;

  /// No description provided for @potPauseNoDeliveryDetail.
  ///
  /// In en, this message translates to:
  /// **'They wait and arrive when you resume it'**
  String get potPauseNoDeliveryDetail;

  /// No description provided for @potPauseWait.
  ///
  /// In en, this message translates to:
  /// **'Its reviews and reminders wait'**
  String get potPauseWait;

  /// No description provided for @potPauseNoWork.
  ///
  /// In en, this message translates to:
  /// **'It starts no work'**
  String get potPauseNoWork;

  /// No description provided for @potPauseGoesOn.
  ///
  /// In en, this message translates to:
  /// **'Goes on'**
  String get potPauseGoesOn;

  /// No description provided for @potPauseWorks.
  ///
  /// In en, this message translates to:
  /// **'Works it already opened keep running'**
  String get potPauseWorks;

  /// No description provided for @potPauseWorksDetail.
  ///
  /// In en, this message translates to:
  /// **'Each follows its own controls; to stop one, stop it in that work'**
  String get potPauseWorksDetail;

  /// No description provided for @potPauseThreads.
  ///
  /// In en, this message translates to:
  /// **'Its conversations stay readable'**
  String get potPauseThreads;

  /// No description provided for @potPauseNothingMoves.
  ///
  /// In en, this message translates to:
  /// **'Nothing is handed over'**
  String get potPauseNothingMoves;

  /// No description provided for @potPauseNothingMovesDetail.
  ///
  /// In en, this message translates to:
  /// **'Its responsibilities, permissions and memory stay; to give them away, hand over or archive'**
  String get potPauseNothingMovesDetail;

  /// No description provided for @potSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'{name}\'s settings'**
  String potSettingsTitle(String name);

  /// No description provided for @potSettingsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Saved section by section'**
  String get potSettingsSubtitle;

  /// No description provided for @potSettingsSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get potSettingsSave;

  /// No description provided for @potSettingsSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get potSettingsSaved;

  /// No description provided for @potSettingsConflict.
  ///
  /// In en, this message translates to:
  /// **'{name} was changed elsewhere and is read again. Your edit is kept; save again to use it.'**
  String potSettingsConflict(String name);

  /// No description provided for @potSettingsOther.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get potSettingsOther;

  /// No description provided for @potSettingsPause.
  ///
  /// In en, this message translates to:
  /// **'Pause…'**
  String get potSettingsPause;

  /// No description provided for @potSettingsResume.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get potSettingsResume;

  /// No description provided for @potSettingsHandOver.
  ///
  /// In en, this message translates to:
  /// **'Hand over…'**
  String get potSettingsHandOver;

  /// No description provided for @potSettingsRetire.
  ///
  /// In en, this message translates to:
  /// **'Archive or delete…'**
  String get potSettingsRetire;

  /// No description provided for @activityKindDm.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get activityKindDm;

  /// No description provided for @activityKindGroupMessage.
  ///
  /// In en, this message translates to:
  /// **'Group'**
  String get activityKindGroupMessage;

  /// No description provided for @activityKindAssign.
  ///
  /// In en, this message translates to:
  /// **'Handed over'**
  String get activityKindAssign;

  /// No description provided for @activityKindWorkOpened.
  ///
  /// In en, this message translates to:
  /// **'Opened work'**
  String get activityKindWorkOpened;

  /// No description provided for @activityKindWorkInstruction.
  ///
  /// In en, this message translates to:
  /// **'Instruction'**
  String get activityKindWorkInstruction;

  /// No description provided for @activityKindFileRead.
  ///
  /// In en, this message translates to:
  /// **'Read'**
  String get activityKindFileRead;

  /// No description provided for @activityKindThinkingAdjust.
  ///
  /// In en, this message translates to:
  /// **'Auto-adjusted'**
  String get activityKindThinkingAdjust;

  /// No description provided for @activityKindFallback.
  ///
  /// In en, this message translates to:
  /// **'Fallback'**
  String get activityKindFallback;

  /// No description provided for @activityKindAwaitingConfirm.
  ///
  /// In en, this message translates to:
  /// **'Needs your OK'**
  String get activityKindAwaitingConfirm;

  /// No description provided for @activityKindAwaitingApproval.
  ///
  /// In en, this message translates to:
  /// **'Needs approval'**
  String get activityKindAwaitingApproval;

  /// No description provided for @activityKindApprovalAnswered.
  ///
  /// In en, this message translates to:
  /// **'Approval answered'**
  String get activityKindApprovalAnswered;

  /// No description provided for @activityKindForwardedToUser.
  ///
  /// In en, this message translates to:
  /// **'To you'**
  String get activityKindForwardedToUser;

  /// No description provided for @activityKindBudgetRequest.
  ///
  /// In en, this message translates to:
  /// **'Budget request'**
  String get activityKindBudgetRequest;

  /// No description provided for @activityKindBudgetExhausted.
  ///
  /// In en, this message translates to:
  /// **'Out of budget'**
  String get activityKindBudgetExhausted;

  /// No description provided for @activityKindLoopGuard.
  ///
  /// In en, this message translates to:
  /// **'Chain paused'**
  String get activityKindLoopGuard;

  /// No description provided for @activityKindHandoverProposed.
  ///
  /// In en, this message translates to:
  /// **'Proposed handover'**
  String get activityKindHandoverProposed;

  /// No description provided for @activityKindReview.
  ///
  /// In en, this message translates to:
  /// **'Review'**
  String get activityKindReview;

  /// No description provided for @activityKindReminderSet.
  ///
  /// In en, this message translates to:
  /// **'Reminder'**
  String get activityKindReminderSet;

  /// No description provided for @activityKindAutonomyChanged.
  ///
  /// In en, this message translates to:
  /// **'Autonomy'**
  String get activityKindAutonomyChanged;

  /// No description provided for @activityKindStatus.
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get activityKindStatus;

  /// No description provided for @potProfileArchived.
  ///
  /// In en, this message translates to:
  /// **'Archived'**
  String get potProfileArchived;

  /// No description provided for @handoverKindResponsibility.
  ///
  /// In en, this message translates to:
  /// **'Duty'**
  String get handoverKindResponsibility;

  /// No description provided for @handoverKindReminder.
  ///
  /// In en, this message translates to:
  /// **'Follow-up'**
  String get handoverKindReminder;

  /// No description provided for @handoverKindWork.
  ///
  /// In en, this message translates to:
  /// **'Work'**
  String get handoverKindWork;

  /// No description provided for @handoverKindGroupHost.
  ///
  /// In en, this message translates to:
  /// **'Host'**
  String get handoverKindGroupHost;

  /// No description provided for @handoverToLabel.
  ///
  /// In en, this message translates to:
  /// **'To'**
  String get handoverToLabel;

  /// No description provided for @handoverMeAvatar.
  ///
  /// In en, this message translates to:
  /// **'Me'**
  String get handoverMeAvatar;

  /// No description provided for @handoverNoOne.
  ///
  /// In en, this message translates to:
  /// **'No one'**
  String get handoverNoOne;

  /// No description provided for @handoverFitOk.
  ///
  /// In en, this message translates to:
  /// **'Enough permissions'**
  String get handoverFitOk;

  /// No description provided for @handoverFitOkYou.
  ///
  /// In en, this message translates to:
  /// **'You manage it yourself, as when you take work over'**
  String get handoverFitOkYou;

  /// No description provided for @handoverNeedsReach.
  ///
  /// In en, this message translates to:
  /// **'Needs: “{reach}”, as {name} has'**
  String handoverNeedsReach(String reach, String name);

  /// No description provided for @handoverWillDo.
  ///
  /// In en, this message translates to:
  /// **'Will do: {text}'**
  String handoverWillDo(String text);

  /// No description provided for @handoverNeedsNothing.
  ///
  /// In en, this message translates to:
  /// **'Needs: nothing more'**
  String get handoverNeedsNothing;

  /// No description provided for @handoverReminderDoes.
  ///
  /// In en, this message translates to:
  /// **'Will do: remind at the time that was set'**
  String get handoverReminderDoes;

  /// No description provided for @handoverNeedsWork.
  ///
  /// In en, this message translates to:
  /// **'Needs: may open work where this work runs'**
  String get handoverNeedsWork;

  /// No description provided for @handoverWorkDoes.
  ///
  /// In en, this message translates to:
  /// **'Will do: coordinate this work; its record still says From {name}'**
  String handoverWorkDoes(String name);

  /// No description provided for @handoverNeedsMember.
  ///
  /// In en, this message translates to:
  /// **'Needs: to be in the group'**
  String get handoverNeedsMember;

  /// No description provided for @handoverHostDoes.
  ///
  /// In en, this message translates to:
  /// **'Will do: answer messages without an @ and decide who takes them'**
  String get handoverHostDoes;

  /// No description provided for @handoverGroupPots.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 person} other{{count} people}}'**
  String handoverGroupPots(int count);

  /// No description provided for @handoverAdjust.
  ///
  /// In en, this message translates to:
  /// **'Adjust {name}\'s permissions…'**
  String handoverAdjust(String name);

  /// No description provided for @handoverCheckLabel.
  ///
  /// In en, this message translates to:
  /// **'Hand over this item'**
  String get handoverCheckLabel;

  /// No description provided for @handoverTitle.
  ///
  /// In en, this message translates to:
  /// **'Hand over'**
  String get handoverTitle;

  /// No description provided for @handoverRoute.
  ///
  /// In en, this message translates to:
  /// **'{from} → {to}'**
  String handoverRoute(String from, String to);

  /// No description provided for @handoverWho.
  ///
  /// In en, this message translates to:
  /// **'To whom'**
  String get handoverWho;

  /// No description provided for @handoverItems.
  ///
  /// In en, this message translates to:
  /// **'What to hand over'**
  String get handoverItems;

  /// No description provided for @handoverNote.
  ///
  /// In en, this message translates to:
  /// **'After the handover {name} no longer does these; you can hand them back later. Both conversations and the activity record it. A pot\'s own proposal also needs your OK.'**
  String handoverNote(String name);

  /// No description provided for @handoverProposedTitle.
  ///
  /// In en, this message translates to:
  /// **'{name} proposes a handover.'**
  String handoverProposedTitle(String name);

  /// No description provided for @handoverProposedText.
  ///
  /// In en, this message translates to:
  /// **'It wants to give {items} to {to}; nothing changes until you confirm.'**
  String handoverProposedText(String items, String to);

  /// No description provided for @handoverQuoted.
  ///
  /// In en, this message translates to:
  /// **'“{text}”'**
  String handoverQuoted(String text);

  /// No description provided for @handoverNext.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get handoverNext;

  /// No description provided for @handoverConfirm.
  ///
  /// In en, this message translates to:
  /// **'Hand over {count, plural, =1{1 item} other{{count} items}} to {name}'**
  String handoverConfirm(int count, String name);

  /// No description provided for @handoverReject.
  ///
  /// In en, this message translates to:
  /// **'Reject'**
  String get handoverReject;

  /// No description provided for @handoverNothingFits.
  ///
  /// In en, this message translates to:
  /// **'None of these can go to {name}; reject it or choose again.'**
  String handoverNothingFits(String name);

  /// No description provided for @handoverApplied.
  ///
  /// In en, this message translates to:
  /// **'Handed over.'**
  String get handoverApplied;

  /// No description provided for @handoverRejected.
  ///
  /// In en, this message translates to:
  /// **'Rejected; nothing was handed over.'**
  String get handoverRejected;

  /// No description provided for @handoverTokensLeft.
  ///
  /// In en, this message translates to:
  /// **'{tokens} tokens left today'**
  String handoverTokensLeft(String tokens);

  /// No description provided for @handoverYouSub.
  ///
  /// In en, this message translates to:
  /// **'Works come to you; other items stop'**
  String get handoverYouSub;

  /// No description provided for @handoverEmpty.
  ///
  /// In en, this message translates to:
  /// **'{name} holds nothing to hand over.'**
  String handoverEmpty(String name);

  /// No description provided for @retireTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove {name}'**
  String retireTitle(String name);

  /// No description provided for @retireSubtitle.
  ///
  /// In en, this message translates to:
  /// **'First choose who takes what'**
  String get retireSubtitle;

  /// No description provided for @retireArchive.
  ///
  /// In en, this message translates to:
  /// **'Archive'**
  String get retireArchive;

  /// No description provided for @retireDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get retireDelete;

  /// No description provided for @retireArchiveNote.
  ///
  /// In en, this message translates to:
  /// **'Archive: it stops and keeps its personality and memory; you can restore it later.'**
  String get retireArchiveNote;

  /// No description provided for @retireDeleteNote.
  ///
  /// In en, this message translates to:
  /// **'Delete: its personality, memory and settings are removed; this can\'t be undone.'**
  String get retireDeleteNote;

  /// No description provided for @retireItems.
  ///
  /// In en, this message translates to:
  /// **'Can hand over · {count}'**
  String retireItems(int count);

  /// No description provided for @retireItemsNote.
  ///
  /// In en, this message translates to:
  /// **'Tap an item for details. A handover moves items, not permissions.'**
  String get retireItemsNote;

  /// No description provided for @retireGiveAll.
  ///
  /// In en, this message translates to:
  /// **'Give everything to…'**
  String get retireGiveAll;

  /// No description provided for @retireStops.
  ///
  /// In en, this message translates to:
  /// **'Will stop'**
  String get retireStops;

  /// No description provided for @retireKept.
  ///
  /// In en, this message translates to:
  /// **'Kept'**
  String get retireKept;

  /// No description provided for @retireArchiveButton.
  ///
  /// In en, this message translates to:
  /// **'Hand over and archive {name}'**
  String retireArchiveButton(String name);

  /// No description provided for @retireDeleteButton.
  ///
  /// In en, this message translates to:
  /// **'Hand over and delete {name}'**
  String retireDeleteButton(String name);

  /// No description provided for @retirePickTitle.
  ///
  /// In en, this message translates to:
  /// **'Who takes {item}?'**
  String retirePickTitle(String item);

  /// No description provided for @retirePickSub.
  ///
  /// In en, this message translates to:
  /// **'The receiver uses only its own permissions; when they aren\'t enough the item narrows. No permission is added.'**
  String get retirePickSub;

  /// No description provided for @retirePickAllTitle.
  ///
  /// In en, this message translates to:
  /// **'Give everything to whom?'**
  String get retirePickAllTitle;

  /// No description provided for @retirePickAllSub.
  ///
  /// In en, this message translates to:
  /// **'Every item goes to the same one; you can still change each item after.'**
  String get retirePickAllSub;

  /// No description provided for @retirePickAllFits.
  ///
  /// In en, this message translates to:
  /// **'Every item fits'**
  String get retirePickAllFits;

  /// No description provided for @retirePickAllMisfits.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 item doesn\'t fully fit} other{{count} items don\'t fully fit}}'**
  String retirePickAllMisfits(int count);

  /// No description provided for @retireDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete {name}?'**
  String retireDeleteTitle(String name);

  /// No description provided for @retireDeleteBody.
  ///
  /// In en, this message translates to:
  /// **'Its personality, memory and settings are removed for good; its conversations stay, read-only. Type {name} to confirm.'**
  String retireDeleteBody(String name);

  /// No description provided for @retireDeleteField.
  ///
  /// In en, this message translates to:
  /// **'Pot name'**
  String get retireDeleteField;

  /// No description provided for @groupNewCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No pots selected} =1{1 pot selected} other{{count} pots selected}}'**
  String groupNewCount(int count);

  /// No description provided for @groupAvatarFaces.
  ///
  /// In en, this message translates to:
  /// **'Members\' faces'**
  String get groupAvatarFaces;

  /// No description provided for @groupAvatarNote.
  ///
  /// In en, this message translates to:
  /// **'Members\' faces by default; you can also pick a colour or upload a picture'**
  String get groupAvatarNote;

  /// No description provided for @groupName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get groupName;

  /// No description provided for @groupNameHint.
  ///
  /// In en, this message translates to:
  /// **'Group name'**
  String get groupNameHint;

  /// No description provided for @groupMembers.
  ///
  /// In en, this message translates to:
  /// **'Members'**
  String get groupMembers;

  /// No description provided for @groupHost.
  ///
  /// In en, this message translates to:
  /// **'Host'**
  String get groupHost;

  /// No description provided for @groupHostNote.
  ///
  /// In en, this message translates to:
  /// **'Without an @, the host answers and decides who to hand things to. The host gets no other member\'s permissions.'**
  String get groupHostNote;

  /// No description provided for @groupHostPickFirst.
  ///
  /// In en, this message translates to:
  /// **'Tick the members first, then choose the host.'**
  String get groupHostPickFirst;

  /// No description provided for @groupCreate.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get groupCreate;

  /// No description provided for @groupNameMissing.
  ///
  /// In en, this message translates to:
  /// **'Give the group a name'**
  String get groupNameMissing;

  /// No description provided for @groupMemberRule.
  ///
  /// In en, this message translates to:
  /// **'A group has 2 to 16 pots'**
  String get groupMemberRule;

  /// No description provided for @groupHostMissing.
  ///
  /// In en, this message translates to:
  /// **'Choose a host among the members'**
  String get groupHostMissing;

  /// No description provided for @groupHostTag.
  ///
  /// In en, this message translates to:
  /// **'Host'**
  String get groupHostTag;

  /// No description provided for @groupMemberHost.
  ///
  /// In en, this message translates to:
  /// **'{name} (host)'**
  String groupMemberHost(String name);

  /// No description provided for @groupComposerHint.
  ///
  /// In en, this message translates to:
  /// **'Without @, {host} answers…'**
  String groupComposerHint(String host);

  /// No description provided for @groupComposerHintNoHost.
  ///
  /// In en, this message translates to:
  /// **'Message the group…'**
  String get groupComposerHintNoHost;

  /// No description provided for @groupComposerTo.
  ///
  /// In en, this message translates to:
  /// **'To {names}…'**
  String groupComposerTo(String names);

  /// No description provided for @groupTargetTo.
  ///
  /// In en, this message translates to:
  /// **'To'**
  String get groupTargetTo;

  /// No description provided for @groupTargetRemove.
  ///
  /// In en, this message translates to:
  /// **'Don\'t send to {name}'**
  String groupTargetRemove(String name);

  /// No description provided for @groupMention.
  ///
  /// In en, this message translates to:
  /// **'@ a member'**
  String get groupMention;

  /// No description provided for @groupMentionLabel.
  ///
  /// In en, this message translates to:
  /// **'Choose who to @'**
  String get groupMentionLabel;

  /// No description provided for @groupMentionHeader.
  ///
  /// In en, this message translates to:
  /// **'Who is it for? Each uses only its own permissions and budget'**
  String get groupMentionHeader;

  /// No description provided for @groupMentionAll.
  ///
  /// In en, this message translates to:
  /// **'Everyone'**
  String get groupMentionAll;

  /// No description provided for @groupMentionAllWarning.
  ///
  /// In en, this message translates to:
  /// **'Every member will be woken and reply, each on its own budget'**
  String get groupMentionAllWarning;

  /// No description provided for @groupInfo.
  ///
  /// In en, this message translates to:
  /// **'Group info'**
  String get groupInfo;

  /// No description provided for @groupEditLook.
  ///
  /// In en, this message translates to:
  /// **'Change name and avatar'**
  String get groupEditLook;

  /// No description provided for @groupMembersCount.
  ///
  /// In en, this message translates to:
  /// **'Members · {count}'**
  String groupMembersCount(int count);

  /// No description provided for @groupYouDetail.
  ///
  /// In en, this message translates to:
  /// **'Creator · can change the members and the host'**
  String get groupYouDetail;

  /// No description provided for @groupEditMembers.
  ///
  /// In en, this message translates to:
  /// **'Add or remove members'**
  String get groupEditMembers;

  /// No description provided for @groupPermissionsNote.
  ///
  /// In en, this message translates to:
  /// **'Permissions don\'t merge in a group. When the host hands something to another member, that member uses only its own permissions.'**
  String get groupPermissionsNote;

  /// No description provided for @groupNoHost.
  ///
  /// In en, this message translates to:
  /// **'No host'**
  String get groupNoHost;

  /// No description provided for @groupHostStays.
  ///
  /// In en, this message translates to:
  /// **'The host stays a member; choose another host first'**
  String get groupHostStays;

  /// No description provided for @groupDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete group…'**
  String get groupDelete;

  /// No description provided for @groupDeleteNote.
  ///
  /// In en, this message translates to:
  /// **'Deleting the group deletes neither its members nor the works they opened.'**
  String get groupDeleteNote;

  /// No description provided for @groupDeleteTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete {name}?'**
  String groupDeleteTitle(String name);

  /// No description provided for @groupDeleteBody.
  ///
  /// In en, this message translates to:
  /// **'Its messages are deleted for good. The member pots and their works stay.'**
  String get groupDeleteBody;

  /// No description provided for @groupConflict.
  ///
  /// In en, this message translates to:
  /// **'The group changed on another device. Your edit is kept; check it and save again.'**
  String get groupConflict;

  /// No description provided for @groupGone.
  ///
  /// In en, this message translates to:
  /// **'This group was deleted.'**
  String get groupGone;

  /// No description provided for @settingsPots.
  ///
  /// In en, this message translates to:
  /// **'Pots'**
  String get settingsPots;

  /// No description provided for @settingsPotsCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 pot} other{{count} pots}}'**
  String settingsPotsCount(int count);

  /// No description provided for @settingsPotsMonth.
  ///
  /// In en, this message translates to:
  /// **'this month {used} / {cap}'**
  String settingsPotsMonth(String used, String cap);

  /// No description provided for @settingsPotsMonthNoCap.
  ///
  /// In en, this message translates to:
  /// **'this month {used}'**
  String settingsPotsMonthNoCap(String used);

  /// No description provided for @potsPageSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Tap one to open its settings'**
  String get potsPageSubtitle;

  /// No description provided for @potsTotals.
  ///
  /// In en, this message translates to:
  /// **'All pots together'**
  String get potsTotals;

  /// No description provided for @potsTotalMonth.
  ///
  /// In en, this message translates to:
  /// **'This month'**
  String get potsTotalMonth;

  /// No description provided for @potsTotalToday.
  ///
  /// In en, this message translates to:
  /// **'Tokens today'**
  String get potsTotalToday;

  /// No description provided for @potsTotalNoCap.
  ///
  /// In en, this message translates to:
  /// **'{used} · no limit'**
  String potsTotalNoCap(String used);

  /// No description provided for @potsCaps.
  ///
  /// In en, this message translates to:
  /// **'Total limits'**
  String get potsCaps;

  /// No description provided for @potsCapsBoth.
  ///
  /// In en, this message translates to:
  /// **'{money}/month · {tokens}/day'**
  String potsCapsBoth(String money, String tokens);

  /// No description provided for @potsCapsMoney.
  ///
  /// In en, this message translates to:
  /// **'{money}/month'**
  String potsCapsMoney(String money);

  /// No description provided for @potsCapsTokens.
  ///
  /// In en, this message translates to:
  /// **'{tokens} tokens/day'**
  String potsCapsTokens(String tokens);

  /// No description provided for @potsNoLimit.
  ///
  /// In en, this message translates to:
  /// **'No limit'**
  String get potsNoLimit;

  /// No description provided for @potsCapsMonth.
  ///
  /// In en, this message translates to:
  /// **'A month'**
  String get potsCapsMonth;

  /// No description provided for @potsCapsDay.
  ///
  /// In en, this message translates to:
  /// **'A day'**
  String get potsCapsDay;

  /// No description provided for @potsCapsUsd.
  ///
  /// In en, this message translates to:
  /// **'USD'**
  String get potsCapsUsd;

  /// No description provided for @potsCapsTokensUnit.
  ///
  /// In en, this message translates to:
  /// **'tokens'**
  String get potsCapsTokensUnit;

  /// No description provided for @potsCapsSheetNote.
  ///
  /// In en, this message translates to:
  /// **'0 means no total limit. Subscription use counts toward money only when \"Show API-equivalent price\" is on.'**
  String get potsCapsSheetNote;

  /// No description provided for @potsCapsMoneyInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter an amount of 0 or more, such as 50 or 12.5.'**
  String get potsCapsMoneyInvalid;

  /// No description provided for @potsCapsTokensInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a whole number of tokens, 0 or more.'**
  String get potsCapsTokensInvalid;

  /// No description provided for @potsExhausted.
  ///
  /// In en, this message translates to:
  /// **'When used up'**
  String get potsExhausted;

  /// No description provided for @potsExhaustedAsk.
  ///
  /// In en, this message translates to:
  /// **'Stop and tell you'**
  String get potsExhaustedAsk;

  /// No description provided for @potsExhaustedAskDetail.
  ///
  /// In en, this message translates to:
  /// **'A pot\'s next model request is refused, and you are told.'**
  String get potsExhaustedAskDetail;

  /// No description provided for @potsExhaustedPause.
  ///
  /// In en, this message translates to:
  /// **'Pause all pots'**
  String get potsExhaustedPause;

  /// No description provided for @potsExhaustedPauseDetail.
  ///
  /// In en, this message translates to:
  /// **'Messages and events wait until the limit starts over.'**
  String get potsExhaustedPauseDetail;

  /// No description provided for @potsRetention.
  ///
  /// In en, this message translates to:
  /// **'Activity kept'**
  String get potsRetention;

  /// No description provided for @potsRetentionDays.
  ///
  /// In en, this message translates to:
  /// **'{days, plural, =1{1 day} other{{days} days}}'**
  String potsRetentionDays(int days);

  /// No description provided for @potsRetentionUnit.
  ///
  /// In en, this message translates to:
  /// **'days'**
  String get potsRetentionUnit;

  /// No description provided for @potsRetentionNote.
  ///
  /// In en, this message translates to:
  /// **'1 to 3650 days. Older activity, and the names of deleted pots, are removed.'**
  String get potsRetentionNote;

  /// No description provided for @potsRetentionInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a number of days from 1 to 3650.'**
  String get potsRetentionInvalid;

  /// No description provided for @potsApiEquivalent.
  ///
  /// In en, this message translates to:
  /// **'Show API-equivalent price'**
  String get potsApiEquivalent;

  /// No description provided for @potsApiEquivalentDetail.
  ///
  /// In en, this message translates to:
  /// **'Subscription use counts toward money limits at API prices, marked as an estimate.'**
  String get potsApiEquivalentDetail;

  /// No description provided for @potsCapsNote.
  ///
  /// In en, this message translates to:
  /// **'Each pot also has its own limits; whichever is reached first applies.'**
  String get potsCapsNote;

  /// No description provided for @potsSettingsConflict.
  ///
  /// In en, this message translates to:
  /// **'The settings changed on another device and are read again. Your edit is kept; save again to use it.'**
  String get potsSettingsConflict;

  /// No description provided for @potsNone.
  ///
  /// In en, this message translates to:
  /// **'No pots yet.'**
  String get potsNone;

  /// No description provided for @potsThinkingAuto.
  ///
  /// In en, this message translates to:
  /// **'{level} (auto)'**
  String potsThinkingAuto(String level);

  /// No description provided for @potsArchived.
  ///
  /// In en, this message translates to:
  /// **'Archived'**
  String get potsArchived;

  /// No description provided for @potsArchivedOn.
  ///
  /// In en, this message translates to:
  /// **'Archived {date}'**
  String potsArchivedOn(String date);

  /// No description provided for @potsRestore.
  ///
  /// In en, this message translates to:
  /// **'Restore…'**
  String get potsRestore;

  /// No description provided for @potsRestoreTitle.
  ///
  /// In en, this message translates to:
  /// **'Restore {name}?'**
  String potsRestoreTitle(String name);

  /// No description provided for @potsRestoreBody.
  ///
  /// In en, this message translates to:
  /// **'{name} comes back paused, with its settings and conversation. Resume it from its profile.'**
  String potsRestoreBody(String name);

  /// No description provided for @potsRestoreConfirm.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get potsRestoreConfirm;

  /// No description provided for @potsRestoreConflict.
  ///
  /// In en, this message translates to:
  /// **'{name} changed elsewhere and was read again. Try again.'**
  String potsRestoreConflict(String name);

  /// No description provided for @meEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get meEdit;

  /// No description provided for @meOverview.
  ///
  /// In en, this message translates to:
  /// **'Overview'**
  String get meOverview;

  /// No description provided for @meStatTotal.
  ///
  /// In en, this message translates to:
  /// **'Tokens in total'**
  String get meStatTotal;

  /// No description provided for @meStatTopDay.
  ///
  /// In en, this message translates to:
  /// **'Most tokens in a day'**
  String get meStatTopDay;

  /// No description provided for @meStatSpent.
  ///
  /// In en, this message translates to:
  /// **'Spent this month'**
  String get meStatSpent;

  /// No description provided for @meStatRequests.
  ///
  /// In en, this message translates to:
  /// **'Requests this month'**
  String get meStatRequests;

  /// No description provided for @meStatLongestStreak.
  ///
  /// In en, this message translates to:
  /// **'Longest streak'**
  String get meStatLongestStreak;

  /// No description provided for @meStatStreak.
  ///
  /// In en, this message translates to:
  /// **'Current streak'**
  String get meStatStreak;

  /// No description provided for @meDays.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 day} other{{count} days}}'**
  String meDays(int count);

  /// No description provided for @meStatsNote.
  ///
  /// In en, this message translates to:
  /// **'Includes you and all pots; costs follow each provider\'s prices.'**
  String get meStatsNote;

  /// No description provided for @meEstimate.
  ///
  /// In en, this message translates to:
  /// **'Subscription use this month at API prices: about {amount}. This is an estimate, not money spent.'**
  String meEstimate(String amount);

  /// No description provided for @meActivity.
  ///
  /// In en, this message translates to:
  /// **'Token activity'**
  String get meActivity;

  /// No description provided for @meDaily.
  ///
  /// In en, this message translates to:
  /// **'Each day'**
  String get meDaily;

  /// No description provided for @meWeekly.
  ///
  /// In en, this message translates to:
  /// **'Each week'**
  String get meWeekly;

  /// No description provided for @meCumulative.
  ///
  /// In en, this message translates to:
  /// **'Running total'**
  String get meCumulative;

  /// No description provided for @meTabDay.
  ///
  /// In en, this message translates to:
  /// **'Day'**
  String get meTabDay;

  /// No description provided for @meTabWeek.
  ///
  /// In en, this message translates to:
  /// **'Week'**
  String get meTabWeek;

  /// No description provided for @meTabTotal.
  ///
  /// In en, this message translates to:
  /// **'Total'**
  String get meTabTotal;

  /// No description provided for @meLess.
  ///
  /// In en, this message translates to:
  /// **'Less'**
  String get meLess;

  /// No description provided for @meMore.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get meMore;

  /// No description provided for @meHeatmapLabel.
  ///
  /// In en, this message translates to:
  /// **'Tokens per day, last {weeks} weeks'**
  String meHeatmapLabel(int weeks);

  /// No description provided for @meWeeksLabel.
  ///
  /// In en, this message translates to:
  /// **'Tokens per week, last 12 weeks'**
  String get meWeeksLabel;

  /// No description provided for @meTotalLabel.
  ///
  /// In en, this message translates to:
  /// **'Running total of tokens'**
  String get meTotalLabel;

  /// No description provided for @meTwelveWeeksAgo.
  ///
  /// In en, this message translates to:
  /// **'12 weeks ago'**
  String get meTwelveWeeksAgo;

  /// No description provided for @meThisWeek.
  ///
  /// In en, this message translates to:
  /// **'This week {value}'**
  String meThisWeek(String value);

  /// No description provided for @meNow.
  ///
  /// In en, this message translates to:
  /// **'Now {value}'**
  String meNow(String value);

  /// No description provided for @meDayTip.
  ///
  /// In en, this message translates to:
  /// **'{date} · {tokens} tokens'**
  String meDayTip(String date, String tokens);

  /// No description provided for @meDayTipNone.
  ///
  /// In en, this message translates to:
  /// **'{date} · no use'**
  String meDayTipNone(String date);

  /// No description provided for @meByWho.
  ///
  /// In en, this message translates to:
  /// **'Who used how much this month'**
  String get meByWho;

  /// No description provided for @meByModel.
  ///
  /// In en, this message translates to:
  /// **'Models used this month'**
  String get meByModel;

  /// No description provided for @meYou.
  ///
  /// In en, this message translates to:
  /// **'{name} (you)'**
  String meYou(String name);

  /// No description provided for @meDeletedPot.
  ///
  /// In en, this message translates to:
  /// **'Deleted pot'**
  String get meDeletedPot;

  /// No description provided for @meNothingThisMonth.
  ///
  /// In en, this message translates to:
  /// **'Nothing used this month yet.'**
  String get meNothingThisMonth;

  /// No description provided for @meOnlyYou.
  ///
  /// In en, this message translates to:
  /// **'Only you can see this.'**
  String get meOnlyYou;

  /// No description provided for @meDrawerMonth.
  ///
  /// In en, this message translates to:
  /// **'This month {amount}'**
  String meDrawerMonth(String amount);

  /// No description provided for @meDrawerStreak.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1-day streak} other{{count}-day streak}}'**
  String meDrawerStreak(int count);

  /// No description provided for @meOpen.
  ///
  /// In en, this message translates to:
  /// **'You and usage'**
  String get meOpen;

  /// No description provided for @meEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit profile'**
  String get meEditTitle;

  /// No description provided for @meName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get meName;

  /// No description provided for @meNameHint.
  ///
  /// In en, this message translates to:
  /// **'Your name'**
  String get meNameHint;

  /// No description provided for @meNameNote.
  ///
  /// In en, this message translates to:
  /// **'Pots call you by this name; groups and Activity show it too.'**
  String get meNameNote;

  /// No description provided for @meNameInvalid.
  ///
  /// In en, this message translates to:
  /// **'A name is 1 to 60 characters.'**
  String get meNameInvalid;

  /// No description provided for @meConflict.
  ///
  /// In en, this message translates to:
  /// **'Your profile changed on another device and is read again. Your edit is kept; save again to use it.'**
  String get meConflict;

  /// No description provided for @activitySubtitle.
  ///
  /// In en, this message translates to:
  /// **'What pots are doing'**
  String get activitySubtitle;

  /// No description provided for @activityFilterKind.
  ///
  /// In en, this message translates to:
  /// **'Filter by type'**
  String get activityFilterKind;

  /// No description provided for @activityFilterPots.
  ///
  /// In en, this message translates to:
  /// **'Filter by pot'**
  String get activityFilterPots;

  /// No description provided for @activityAllKinds.
  ///
  /// In en, this message translates to:
  /// **'All types'**
  String get activityAllKinds;

  /// No description provided for @activitySeePov.
  ///
  /// In en, this message translates to:
  /// **'See {name}\'s point of view'**
  String activitySeePov(String name);

  /// No description provided for @activitySeePovDetail.
  ///
  /// In en, this message translates to:
  /// **'Browse its record through the chat list it sees · read only'**
  String get activitySeePovDetail;

  /// No description provided for @activityFootnote.
  ///
  /// In en, this message translates to:
  /// **'Messages between pots, instructions sent to work and files read are all recorded here; there is no channel you can\'t see.'**
  String get activityFootnote;

  /// No description provided for @activityEmptyFilter.
  ///
  /// In en, this message translates to:
  /// **'Nothing matches this filter.'**
  String get activityEmptyFilter;

  /// No description provided for @activityNoticed.
  ///
  /// In en, this message translates to:
  /// **'Noticed'**
  String get activityNoticed;

  /// No description provided for @activityMarkRead.
  ///
  /// In en, this message translates to:
  /// **'Mark read'**
  String get activityMarkRead;

  /// No description provided for @activityNoticeOpen.
  ///
  /// In en, this message translates to:
  /// **'New'**
  String get activityNoticeOpen;

  /// No description provided for @activityNoticeSeen.
  ///
  /// In en, this message translates to:
  /// **'Seen'**
  String get activityNoticeSeen;

  /// No description provided for @activityNoticedMerged.
  ///
  /// In en, this message translates to:
  /// **'{count} pots'**
  String activityNoticedMerged(int count);

  /// No description provided for @activityConditionRunFinished.
  ///
  /// In en, this message translates to:
  /// **'A work finished its run'**
  String get activityConditionRunFinished;

  /// No description provided for @activityConditionWaitingInput.
  ///
  /// In en, this message translates to:
  /// **'A work is waiting for you'**
  String get activityConditionWaitingInput;

  /// No description provided for @activityConditionStartingSoon.
  ///
  /// In en, this message translates to:
  /// **'Starting soon'**
  String get activityConditionStartingSoon;

  /// No description provided for @activityConditionRunFailed.
  ///
  /// In en, this message translates to:
  /// **'A work\'s run failed'**
  String get activityConditionRunFailed;

  /// No description provided for @povTitle.
  ///
  /// In en, this message translates to:
  /// **'{name}\'s point of view'**
  String povTitle(String name);

  /// No description provided for @povSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Read only · the chat list it sees'**
  String get povSubtitle;

  /// No description provided for @povNote.
  ///
  /// In en, this message translates to:
  /// **'This is what {name} sees, including the messages it sends into work. You can\'t send messages as it here.'**
  String povNote(String name);

  /// No description provided for @povThreadNote.
  ///
  /// In en, this message translates to:
  /// **'As {name} · on the right is what it sent'**
  String povThreadNote(String name);

  /// No description provided for @povWorks.
  ///
  /// In en, this message translates to:
  /// **'Works I coordinate'**
  String get povWorks;

  /// No description provided for @povSent.
  ///
  /// In en, this message translates to:
  /// **'Messages it sent'**
  String get povSent;

  /// No description provided for @povShowOlder.
  ///
  /// In en, this message translates to:
  /// **'Show older'**
  String get povShowOlder;

  /// No description provided for @povNoThreads.
  ///
  /// In en, this message translates to:
  /// **'It is in no conversation yet.'**
  String get povNoThreads;

  /// No description provided for @povYou.
  ///
  /// In en, this message translates to:
  /// **'You (user)'**
  String get povYou;

  /// No description provided for @povAuthorMe.
  ///
  /// In en, this message translates to:
  /// **'Me'**
  String get povAuthorMe;

  /// No description provided for @povMe.
  ///
  /// In en, this message translates to:
  /// **'Me ({name})'**
  String povMe(String name);

  /// No description provided for @povWorkLabel.
  ///
  /// In en, this message translates to:
  /// **'Work'**
  String get povWorkLabel;

  /// No description provided for @povReadOnly.
  ///
  /// In en, this message translates to:
  /// **'Read only: {name}\'s record'**
  String povReadOnly(String name);

  /// No description provided for @povGoToWork.
  ///
  /// In en, this message translates to:
  /// **'Go to work'**
  String get povGoToWork;

  /// No description provided for @povBackToActivity.
  ///
  /// In en, this message translates to:
  /// **'Back to activity'**
  String get povBackToActivity;

  /// No description provided for @povDmSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Message · you can see every message between pots'**
  String get povDmSubtitle;

  /// No description provided for @povDirectSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Its conversation with you'**
  String get povDirectSubtitle;

  /// No description provided for @povNoInstructions.
  ///
  /// In en, this message translates to:
  /// **'It has sent no instructions into this work yet.'**
  String get povNoInstructions;

  /// No description provided for @povDelivered.
  ///
  /// In en, this message translates to:
  /// **'Delivered'**
  String get povDelivered;

  /// No description provided for @povRefused.
  ///
  /// In en, this message translates to:
  /// **'Refused'**
  String get povRefused;

  /// No description provided for @povUncertain.
  ///
  /// In en, this message translates to:
  /// **'Not confirmed'**
  String get povUncertain;

  /// No description provided for @pairScan.
  ///
  /// In en, this message translates to:
  /// **'Scan QR code'**
  String get pairScan;

  /// No description provided for @pairScanFailed.
  ///
  /// In en, this message translates to:
  /// **'The scanner could not be opened. Try again, or paste the link.'**
  String get pairScanFailed;

  /// No description provided for @pairScanDownloading.
  ///
  /// In en, this message translates to:
  /// **'The scanner is still being installed. Try again in a moment.'**
  String get pairScanDownloading;

  /// No description provided for @pairScanUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This device cannot scan QR codes. Paste the link instead.'**
  String get pairScanUnsupported;

  /// No description provided for @pairNotACode.
  ///
  /// In en, this message translates to:
  /// **'This QR code is not a pairing link.'**
  String get pairNotACode;

  /// No description provided for @pairNotACodeV2.
  ///
  /// In en, this message translates to:
  /// **'This QR code is not a pairing link or a Gateway address.'**
  String get pairNotACodeV2;

  /// No description provided for @pairLinkOpened.
  ///
  /// In en, this message translates to:
  /// **'A pairing link for {gateway} was opened. Tap Pair to use it.'**
  String pairLinkOpened(String gateway);

  /// No description provided for @pairExpired.
  ///
  /// In en, this message translates to:
  /// **'Pairing expired; your settings are kept.'**
  String get pairExpired;

  /// No description provided for @pairV2Title.
  ///
  /// In en, this message translates to:
  /// **'Pair with a browser'**
  String get pairV2Title;

  /// No description provided for @pairV2Body.
  ///
  /// In en, this message translates to:
  /// **'Give the Gateway address, typed or from a QR code. You approve this device in a browser that is signed in to the Gateway.'**
  String get pairV2Body;

  /// No description provided for @pairV2AddressLabel.
  ///
  /// In en, this message translates to:
  /// **'Gateway address'**
  String get pairV2AddressLabel;

  /// No description provided for @pairV2DefaultName.
  ///
  /// In en, this message translates to:
  /// **'Android phone'**
  String get pairV2DefaultName;

  /// No description provided for @pairV2Start.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get pairV2Start;

  /// No description provided for @pairV2Creating.
  ///
  /// In en, this message translates to:
  /// **'Asking the Gateway…'**
  String get pairV2Creating;

  /// No description provided for @pairV2NotAnAddress.
  ///
  /// In en, this message translates to:
  /// **'This is not a Gateway address, such as https://pirc.example.'**
  String get pairV2NotAnAddress;

  /// No description provided for @pairV2BadName.
  ///
  /// In en, this message translates to:
  /// **'Give a device name of 1 to 100 characters.'**
  String get pairV2BadName;

  /// No description provided for @pairV2Device.
  ///
  /// In en, this message translates to:
  /// **'This device: {name}'**
  String pairV2Device(String name);

  /// No description provided for @pairV2OpenInBrowser.
  ///
  /// In en, this message translates to:
  /// **'Open in a browser to approve'**
  String get pairV2OpenInBrowser;

  /// No description provided for @pairV2OpenBrowser.
  ///
  /// In en, this message translates to:
  /// **'Open the browser'**
  String get pairV2OpenBrowser;

  /// No description provided for @pairV2BrowserFailed.
  ///
  /// In en, this message translates to:
  /// **'The browser could not be opened. Open this address yourself:'**
  String get pairV2BrowserFailed;

  /// No description provided for @pairV2Expires.
  ///
  /// In en, this message translates to:
  /// **'The request ends at {time}.'**
  String pairV2Expires(String time);

  /// No description provided for @pairV2Waiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the approval in the browser…'**
  String get pairV2Waiting;

  /// No description provided for @pairV2Approved.
  ///
  /// In en, this message translates to:
  /// **'Approved. Type the 6-digit code that the browser shows.'**
  String get pairV2Approved;

  /// No description provided for @pairV2CodeLabel.
  ///
  /// In en, this message translates to:
  /// **'6-digit code'**
  String get pairV2CodeLabel;

  /// No description provided for @pairV2Claim.
  ///
  /// In en, this message translates to:
  /// **'Pair'**
  String get pairV2Claim;

  /// No description provided for @pairV2Claiming.
  ///
  /// In en, this message translates to:
  /// **'Checking…'**
  String get pairV2Claiming;

  /// No description provided for @pairV2WrongCode.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Wrong code. 1 try left.} other{Wrong code. {count} tries left.}}'**
  String pairV2WrongCode(int count);

  /// No description provided for @pairV2TooManyCodes.
  ///
  /// In en, this message translates to:
  /// **'Too many wrong codes ended this request. Start again to make a new one.'**
  String get pairV2TooManyCodes;

  /// No description provided for @pairV2Denied.
  ///
  /// In en, this message translates to:
  /// **'The request was denied in the browser. Start again to make a new one.'**
  String get pairV2Denied;

  /// No description provided for @pairV2Expired.
  ///
  /// In en, this message translates to:
  /// **'The request expired. Start again to make a new one.'**
  String get pairV2Expired;

  /// No description provided for @pairV2TooManyRequests.
  ///
  /// In en, this message translates to:
  /// **'Too many pairing requests are open on the Gateway. Try again in a few minutes.'**
  String get pairV2TooManyRequests;

  /// No description provided for @pairV2TooManyPhones.
  ///
  /// In en, this message translates to:
  /// **'This account already has 10 paired phones. Remove one in a browser, then send the code again.'**
  String get pairV2TooManyPhones;

  /// No description provided for @pairV2Failed.
  ///
  /// In en, this message translates to:
  /// **'Pairing failed. Start again.'**
  String get pairV2Failed;

  /// No description provided for @pairV2StartAgain.
  ///
  /// In en, this message translates to:
  /// **'Start again'**
  String get pairV2StartAgain;

  /// No description provided for @pairV2Paired.
  ///
  /// In en, this message translates to:
  /// **'Paired. Connecting…'**
  String get pairV2Paired;

  /// No description provided for @pairApprovalTitle.
  ///
  /// In en, this message translates to:
  /// **'Pair {device}?'**
  String pairApprovalTitle(String device);

  /// No description provided for @pairApprovalPlatform.
  ///
  /// In en, this message translates to:
  /// **'Platform: {platform}'**
  String pairApprovalPlatform(String platform);

  /// No description provided for @pairApprovalNote.
  ///
  /// In en, this message translates to:
  /// **'Approve only a device you are pairing now. Once paired, it can do everything you can on this Gateway.'**
  String get pairApprovalNote;

  /// No description provided for @pairApprovalCodeTitle.
  ///
  /// In en, this message translates to:
  /// **'Type this code in the app'**
  String get pairApprovalCodeTitle;

  /// No description provided for @pairApprovalCodeNote.
  ///
  /// In en, this message translates to:
  /// **'The code works until {time}. Do not share it.'**
  String pairApprovalCodeNote(String time);

  /// No description provided for @pairApprovalDenied.
  ///
  /// In en, this message translates to:
  /// **'Denied. The device was not paired.'**
  String get pairApprovalDenied;

  /// No description provided for @pairApprovalDecided.
  ///
  /// In en, this message translates to:
  /// **'This request was already decided.'**
  String get pairApprovalDecided;

  /// No description provided for @pairApprovalExpired.
  ///
  /// In en, this message translates to:
  /// **'This request expired. Start again in the app.'**
  String get pairApprovalExpired;

  /// No description provided for @pairingEndsWarning.
  ///
  /// In en, this message translates to:
  /// **'Pairing ends on {date}. Open pirc on this phone before then, or pair again.'**
  String pairingEndsWarning(String date);

  /// No description provided for @pairLinkScanned.
  ///
  /// In en, this message translates to:
  /// **'A pairing link for {gateway} was scanned. Tap Pair to use it.'**
  String pairLinkScanned(String gateway);

  /// No description provided for @filePickerFailed.
  ///
  /// In en, this message translates to:
  /// **'The file picker could not open.'**
  String get filePickerFailed;

  /// No description provided for @filesTooLarge.
  ///
  /// In en, this message translates to:
  /// **'Not added, too large: {names}.'**
  String filesTooLarge(String names);

  /// No description provided for @filesUnreadable.
  ///
  /// In en, this message translates to:
  /// **'Not added, could not be read: {names}.'**
  String filesUnreadable(String names);

  /// No description provided for @filesTooMany.
  ///
  /// In en, this message translates to:
  /// **'Not added, more than 16 files or 64 MiB at once: {names}.'**
  String filesTooMany(String names);

  /// No description provided for @pictureNotRead.
  ///
  /// In en, this message translates to:
  /// **'This picture could not be read.'**
  String get pictureNotRead;

  /// No description provided for @pictureTooLarge.
  ///
  /// In en, this message translates to:
  /// **'This picture is too large.'**
  String get pictureTooLarge;

  /// No description provided for @shareFailed.
  ///
  /// In en, this message translates to:
  /// **'This could not be shared.'**
  String get shareFailed;

  /// No description provided for @messageMediaTap.
  ///
  /// In en, this message translates to:
  /// **'Tap to load the media'**
  String get messageMediaTap;

  /// No description provided for @messageMediaFrom.
  ///
  /// In en, this message translates to:
  /// **'From {host}'**
  String messageMediaFrom(String host);

  /// No description provided for @messageMediaFailed.
  ///
  /// In en, this message translates to:
  /// **'The media could not be loaded.'**
  String get messageMediaFailed;

  /// No description provided for @messageMediaUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This media cannot be played here.'**
  String get messageMediaUnsupported;
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
