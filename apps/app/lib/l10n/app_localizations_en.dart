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
}
