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

  @override
  String get dockGoal => '目標';

  @override
  String get dockTodo => '任務';

  @override
  String dockQueue(int count) {
    return '$count 則排隊中的訊息';
  }

  @override
  String get whenSteer => '插話';

  @override
  String get whenQueue => '排隊';

  @override
  String get thinkingOff => '關閉';

  @override
  String get thinkingMinimal => '最少';

  @override
  String get thinkingLow => '低';

  @override
  String get thinkingMedium => '中';

  @override
  String get thinkingHigh => '高';

  @override
  String get thinkingXhigh => '最高';

  @override
  String get thinkingDefault => '預設思考';

  @override
  String get modelRow => '模型';

  @override
  String get thinkingRow => '思考';

  @override
  String get modelDefault => '預設模型';

  @override
  String get thinkingUnsupported => '這個模型沒有思考強度';

  @override
  String get composerLocked => '接管後才能輸入一般訊息';

  @override
  String get composerReadOnly => '由另一台裝置控制中';

  @override
  String get composerOffline => '離線中，草稿會保留。';

  @override
  String get composerHint => '輸入訊息…';

  @override
  String get commandRejected => '工作拒絕了這則訊息。';

  @override
  String get staleEnvironment => '工作的環境已變更，草稿已保留。';

  @override
  String get attach => '附加檔案';

  @override
  String get stopWork => '停止這個工作';

  @override
  String get send => '送出';

  @override
  String get notSureArrived => '不確定是否送達';

  @override
  String get checkStatus => '確認狀態';

  @override
  String get pickWorkspace => '選擇專案';

  @override
  String get firstSending => '送出中…';

  @override
  String get firstRefused => '第一則訊息被拒絕。';

  @override
  String get sendAgain => '再送一次';

  @override
  String get firstNotSent => '沒有送出。';

  @override
  String get newConversationEmpty => '選擇專案並寫下第一則訊息。';

  @override
  String get noWorkspaces => '還沒有專案。';

  @override
  String hostOffline(String host) {
    return '$host · 離線';
  }

  @override
  String get workspaceHostOffline => '主機離線';

  @override
  String get workspaceUnavailable => '這個 Gateway 沒有它的模式';

  @override
  String handledElsewhere(String title) {
    return '$title · 已在另一台裝置處理';
  }

  @override
  String get questionExpired => '已過期';

  @override
  String expiresAt(String time) {
    return '$time 過期';
  }

  @override
  String get no => '否';

  @override
  String get yes => '是';

  @override
  String get questionSkipped => '已略過';

  @override
  String get skip => '略過';

  @override
  String get approvalReadOnly => '唯讀';

  @override
  String get approvalAuto => '自動';

  @override
  String get approvalFullAccess => '完全存取';

  @override
  String get approvalMode => '核准模式';

  @override
  String get approvalFullAccessWarning =>
      'agent 可以不經詢問執行任何指令、修改任何檔案。只在你信任的工作使用。';

  @override
  String get approvalFullAccessConfirm => '允許完全存取';

  @override
  String get notSentByYou => '不是你直接傳的訊息';

  @override
  String potCoordinates(String name) {
    return '由 $name 協調中。你可以回答問題或停止；要直接下指令請先接管。';
  }

  @override
  String get takeOver => '接管';

  @override
  String takenOver(String name) {
    return '$name 不會再對這個工作下指令。';
  }
}

/// The translations for Chinese, as used in Taiwan (`zh_TW`).
class AppLocalizationsZhTw extends AppLocalizationsZh {
  AppLocalizationsZhTw() : super('zh_TW');
}
