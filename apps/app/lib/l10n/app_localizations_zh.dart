// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'pirc';

  @override
  String get tabChat => '聊天';

  @override
  String get tabWork => '工作';

  @override
  String get tabActivity => '動態';

  @override
  String get tabCalendar => '行事曆';

  @override
  String get settings => '設定';

  @override
  String get back => '返回';

  @override
  String get emptyChat => '還沒有 pot 或群組';

  @override
  String get emptyWork => '還沒有工作階段';

  @override
  String get emptyActivity => '還沒有動態';

  @override
  String get emptyCalendar => '沒有排程';

  @override
  String get nothingOpen => '選取項目以開啟';

  @override
  String openItem(String id) {
    return '項目 $id';
  }

  @override
  String get language => '語言';

  @override
  String get languageSystem => '跟隨系統';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageTraditionalChinese => '繁體中文';

  @override
  String get appearance => '外觀';

  @override
  String get appearanceSystem => '跟隨系統';

  @override
  String get appearanceLight => '淺色';

  @override
  String get appearanceDark => '深色';
}

/// The translations for Chinese, as used in Taiwan (`zh_TW`).
class AppLocalizationsZhTw extends AppLocalizationsZh {
  AppLocalizationsZhTw() : super('zh_TW');
}
