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

  @override
  String get pairTitle => '配對這台裝置';

  @override
  String get pairBody => '貼上 Gateway 網頁上顯示的配對連結。';

  @override
  String get pairLinkLabel => '配對連結';

  @override
  String get pairAction => '配對';

  @override
  String get pairChecking => '檢查中…';

  @override
  String get pairPaired => '已配對';

  @override
  String get pairNotALink => '這不是配對連結。';

  @override
  String get pairTokenRefused => 'Gateway 不接受這個連結，請重新產生一個。';

  @override
  String get pairAppTooOld => '這個 App 版本對 Gateway 來說太舊了，請更新 App。';

  @override
  String get pairUnreachable => '連不到 Gateway。';

  @override
  String get pairFailed => '配對失敗。';

  @override
  String get offlineBanner => '離線 · 顯示的可能不是最新狀態';

  @override
  String get reconnecting => '重新連線中…';

  @override
  String get loadingTitle => '正在重新連線並取得最新狀態…';

  @override
  String get loadingNote => '確認之前不顯示可操作的按鈕';

  @override
  String get upgradeTitle => '請更新 App';

  @override
  String get upgradeBody => '這個版本的 App 對你的 Gateway 來說太舊了，更新後才能繼續。';

  @override
  String get signedOutTitle => '請重新登入';

  @override
  String get signedOutBody => '登入已經結束，重新載入頁面再登入一次。';

  @override
  String get openDrawer => '開啟選單';

  @override
  String get closeDrawer => '關閉選單';

  @override
  String get gatewayConnected => 'Gateway 已連線';

  @override
  String get gatewayOffline => 'Gateway 離線';

  @override
  String get hosts => '主機';

  @override
  String get hostsFailed => '無法載入主機。';

  @override
  String get noHosts => '沒有連線中的主機。';

  @override
  String get hostIdle => '沒有執行中的工作';

  @override
  String hostRunning(int count) {
    return '$count 個工作執行中';
  }

  @override
  String get switchToLight => '切換成淺色';

  @override
  String get switchToDark => '切換成深色';

  @override
  String get workSubtitle => '依專案';

  @override
  String get searchWork => '搜尋工作與專案';

  @override
  String get filterAll => '全部';

  @override
  String get filterNeedsYou => '需要你';

  @override
  String get filterRunning => '執行中';

  @override
  String get filterMine => '我開的';

  @override
  String get filterPots => 'pots 開的';

  @override
  String get noteNeedsYou => '要你回答、核准或驗收的工作。已讀不等於已處理，處理完才會離開。';

  @override
  String get notePots => 'pots 開的工作由它協調；你可以回答、停止或接管。';

  @override
  String get noteMine => '只看你自己開的工作。';

  @override
  String groupCount(int count) {
    return '$count 個';
  }

  @override
  String get noProject => '沒有專案';

  @override
  String fromPot(String name) {
    return 'From $name';
  }

  @override
  String get fromYou => '你';

  @override
  String get stateWaiting => '等你回答';

  @override
  String get stateRunning => '執行中';

  @override
  String get stateQueued => '排隊中';

  @override
  String get stateStopping => '停止中…';

  @override
  String get stateIdle => '閒置';

  @override
  String get stateSettled => '已結束';

  @override
  String approvalWaiting(String model) {
    return '還沒開始 · 等你核准 $model';
  }

  @override
  String get needsYouPill => '待你';

  @override
  String get yesterday => '昨天';

  @override
  String get pinned => '已釘選';

  @override
  String get moreActions => '更多動作';

  @override
  String get actionRename => '重新命名';

  @override
  String get actionPin => '釘選';

  @override
  String get actionUnpin => '取消釘選';

  @override
  String get actionSettle => '結束';

  @override
  String get actionUnsettle => '重新開啟';

  @override
  String get actionDelete => '刪除…';

  @override
  String get deleteWorkTitle => '刪除這個工作？';

  @override
  String get deleteWorkBody => '對話會被刪除，無法復原。';

  @override
  String get delete => '刪除';

  @override
  String get cancel => '取消';

  @override
  String get save => '儲存';

  @override
  String actionFailed(String message) {
    return '沒有完成：$message';
  }

  @override
  String get emptyFilter => '這裡沒有工作。';

  @override
  String get listFailed => '無法載入列表。';

  @override
  String get retry => '重試';

  @override
  String get newConversation => '新對話';

  @override
  String get questionWaits => '有問題等你回答';

  @override
  String get newContent => '有新內容';

  @override
  String get turnFailed => '這一輪失敗了。';

  @override
  String get turnStopped => '已停止。';

  @override
  String toolSteps(int count) {
    return '$count 個工具步驟';
  }

  @override
  String toolFailures(int count) {
    return '$count 個失敗';
  }

  @override
  String get stepFailed => '失敗';

  @override
  String get stepDone => '完成';

  @override
  String get sessionDeleted => '這個工作已被刪除。';

  @override
  String get sessionFailed => '無法載入這個工作。';

  @override
  String get partialOutputLost => '重新連線時遺失了部分輸出。';

  @override
  String get controlledElsewhere => '由另一台裝置控制中';

  @override
  String get takeControl => '取得控制權';
}

/// The translations for Chinese, as used in Taiwan (`zh_TW`).
class AppLocalizationsZhTw extends AppLocalizationsZh {
  AppLocalizationsZhTw() : super('zh_TW');
}
