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
  String get chatOnline => '已連線';

  @override
  String get chatOffline => '離線';

  @override
  String get chatNewTooltip => '新增 pots 或群組';

  @override
  String get searchChat => '搜尋 pots、群組與訊息';

  @override
  String get chatFilterUnread => '未讀';

  @override
  String get chatFilterPots => 'pots';

  @override
  String get chatFilterGroups => '群組';

  @override
  String get chatEmptyFilter => '這裡沒有對話。';

  @override
  String get chatNoMessages => '還沒有訊息';

  @override
  String get chatAuthorYou => '你';

  @override
  String chatPreviewBy(String name, String message) {
    return '$name：$message';
  }

  @override
  String groupMemberCount(int count) {
    return '$count 人';
  }

  @override
  String get potPaused => '已暫停';

  @override
  String get potWorking => '工作中';

  @override
  String get potUnavailable => '無法工作';

  @override
  String get chatNewPot => '新增 pots';

  @override
  String get chatNewGroup => '建立群組';

  @override
  String get newSheetTitle => '新增';

  @override
  String get newSheetNote => '新對話（工作）在「工作」分頁右上';

  @override
  String get newPotDetail => '設定名字、頭像、個性和負責的事';

  @override
  String get newGroupDetail => '拉幾個 pots 一起討論，指定一位主持';

  @override
  String get newGroupNeedsTwo => '先建立至少兩個 pots';

  @override
  String approvalSheetTitle(String pot, String model) {
    return '$pot想用 $model';
  }

  @override
  String get approvalRowWork => '工作';

  @override
  String get approvalRowModel => '模型';

  @override
  String get approvalRowWhy => '為什麼';

  @override
  String get approvalRowBudget => '額度';

  @override
  String get approvalNotStarted => '還沒開始';

  @override
  String approvalEstimate(String cost, String pot, String left) {
    return '預估 $cost · $pot本月還剩 $left';
  }

  @override
  String approvalEstimateNoLimit(String cost) {
    return '預估 $cost · 沒有金額上限';
  }

  @override
  String approvalNote(String model, String pot) {
    return '你把 $model 設成「先問你」。允許只對這一次有效；想不再被問，到$pot的設定改成「直接用」。';
  }

  @override
  String get deny => '拒絕';

  @override
  String get denyWithReason => '拒絕並說明原因';

  @override
  String get allowOnce => '允許這一次';

  @override
  String denyReasonHint(String pot) {
    return '告訴$pot為什麼，例如「先用 Sonnet 再比對一次，把不一致的地方列給我」';
  }

  @override
  String get denyAndSend => '拒絕並送出原因';

  @override
  String get answered => '已回覆';

  @override
  String get answeredAllowedOnce => '已允許這一次';

  @override
  String get answeredUsed => '已允許這一次（已使用）';

  @override
  String get answeredDenied => '已拒絕';

  @override
  String answeredDeniedWithReason(String reason) {
    return '已拒絕：$reason';
  }

  @override
  String budgetSheetTitle(String pot) {
    return '$pot想要更多額度';
  }

  @override
  String get budgetRowAsk => '申請';

  @override
  String budgetMoreMoney(String amount) {
    return '本月多 $amount';
  }

  @override
  String budgetMoreTokens(String tokens) {
    return '今天多 $tokens token';
  }

  @override
  String budgetLeftMoney(String amount) {
    return '本月還剩 $amount';
  }

  @override
  String budgetLeftTokens(String tokens) {
    return '今天還剩 $tokens token';
  }

  @override
  String budgetNote(String pot) {
    return '核准只會提高$pot這一期的上限。';
  }

  @override
  String get approve => '核准';

  @override
  String get approveOtherAmount => '核准其他數量';

  @override
  String get approveThisAmount => '核准這個數量';

  @override
  String get budgetAmountMoneyHint => '金額（美元）';

  @override
  String get budgetAmountTokensHint => 'token 數';

  @override
  String get answeredApproved => '已核准';

  @override
  String answeredApprovedAmount(String amount) {
    return '已核准 $amount';
  }

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
  String controlledByName(String name) {
    return '由 $name 控制中';
  }

  @override
  String continuedOn(String name) {
    return '已改由 $name 繼續';
  }

  @override
  String takeoverConfirm(String name) {
    return '$name 剛剛在這裡工作。仍要送出嗎？';
  }

  @override
  String get anotherDevice => '另一台裝置';

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
  String get thinkingXhigh => '超高';

  @override
  String get thinkingMax => '最高';

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
  String answeredOn(String name, String time) {
    return '由 $name 於 $time 回答';
  }

  @override
  String answeredOnName(String name) {
    return '由 $name 回答';
  }

  @override
  String get questionAnswered => '已回答';

  @override
  String get questionWithdrawn => '已撤回';

  @override
  String get questionStale => '工作階段重新啟動時結束';

  @override
  String questionEnded(String title) {
    return '$title · 已結束';
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

  @override
  String get resultGenerating => '生成中…';

  @override
  String get resultFailed => '失敗';

  @override
  String get resultReadSoFar => '閱讀已產生內容';

  @override
  String get resultOpen => '開啟';

  @override
  String get copy => '複製';

  @override
  String get copied => '已複製';

  @override
  String get share => '分享';

  @override
  String get close => '關閉';

  @override
  String get resultMissing => '這個成果已不在對話中。';

  @override
  String get resultVersions => '版本';

  @override
  String resultNewer(int version) {
    return 'v$version 已完成。';
  }

  @override
  String resultSwitch(int version) {
    return '切換到 v$version';
  }

  @override
  String resultFailedShowingLast(int version) {
    return 'v$version 生成失敗，顯示最後可用的版本。';
  }

  @override
  String get resultNoColumns => '這個表格沒有欄位。';

  @override
  String get resultUnsupported => '這種成果以摘要顯示。';

  @override
  String get accessNeeded => '需要核准';

  @override
  String get accessOpenInBrowser => '在已登入的瀏覽器開啟這個網址並核准：';

  @override
  String accessRequestExpires(String time) {
    return '請求在 $time 過期。';
  }

  @override
  String get accessDenied => '請求被拒絕。';

  @override
  String get accessExpired => '請求或存取權已過期。';

  @override
  String get accessAsk => '請求存取';

  @override
  String get settingsDevices => '裝置';

  @override
  String get accessDevicesReason => '列出和移除已配對的裝置，需要先在瀏覽器短暫核准。';

  @override
  String deviceLastUsed(String time) {
    return '上次使用 $time';
  }

  @override
  String get deviceRevoke => '移除';

  @override
  String get deviceRevokeNeedsAccess => '移除裝置需要移除裝置的存取權。';

  @override
  String get devicePair => '配對新裝置';

  @override
  String get accessPairReason => '配對新裝置需要先在瀏覽器短暫核准。';

  @override
  String deviceRevokeTitle(String name) {
    return '移除 $name？';
  }

  @override
  String get deviceRevokeBody => '重新配對前，它無法再連到這個 Gateway。';

  @override
  String devicePaired(String name) {
    return '$name 已就緒';
  }

  @override
  String get devicePairOnce => '這個連結和條碼只顯示一次。在新裝置開啟連結或掃描條碼。';

  @override
  String deviceExpires(String time) {
    return '新裝置在 $time 前可用，除非更新。';
  }

  @override
  String get done => '完成';

  @override
  String get deviceName => '裝置名稱';

  @override
  String get devicePairAction => '配對';

  @override
  String get capabilityProviders => '變更模型供應商與憑證';

  @override
  String get capabilityDevicesRead => '查看已配對的裝置';

  @override
  String get capabilityDevicesRevoke => '移除已配對的裝置';

  @override
  String get capabilityDevicesPair => '配對可以使用這個 Gateway 的新裝置';

  @override
  String approvalTitle(String device) {
    return '$device 請求存取';
  }

  @override
  String approvalPairingLifetime(int idle, int max) {
    return '每台新裝置閒置 $idle 天後失效，最長 $max 天。';
  }

  @override
  String get approvalGrantLifetime => '存取權維持 15 分鐘，只在那台裝置有效。';

  @override
  String get approvalApproved => '已核准，請回到 App。';

  @override
  String get approvalDenied => '已拒絕。';

  @override
  String get approvalNotPending => '這個請求已不在等待中。';

  @override
  String get approvalDeny => '拒絕';

  @override
  String get approvalApprove => '核准';

  @override
  String get approvalMissing => '這個請求不存在或已過期。';

  @override
  String get panelsTitle => '面板';

  @override
  String get panelMore => '更多';

  @override
  String get panelFiles => '檔案';

  @override
  String get panelGit => 'Git';

  @override
  String get panelTerminal => '終端';

  @override
  String get panelTasks => 'Tasks';

  @override
  String get panelBrowser => '瀏覽器';

  @override
  String get panelContext => 'Context';

  @override
  String get panelCheckpoints => '檢查點';

  @override
  String get panelOffline => '離線中，連上 Gateway 後才會載入這個面板。';

  @override
  String get panelHostOffline => '主機離線。';

  @override
  String get panelFailed => '無法載入這個面板。';

  @override
  String get panelReadOnly => '唯讀：另一台裝置控制著這個工作。';

  @override
  String get panelsOpen => '面板';

  @override
  String get filesRoot => '根目錄';

  @override
  String get refresh => '重新整理';

  @override
  String get filesEmpty => '這個資料夾是空的。';

  @override
  String get filesImageTooLarge => '圖片太大，無法顯示。';

  @override
  String get filesBinary => '這不是文字檔。';

  @override
  String get panelTruncated => '只顯示前面一部分。';

  @override
  String get gitNoDiff => '沒有變更。';

  @override
  String get gitChanges => '變更';

  @override
  String get gitHistory => '歷史';

  @override
  String get gitNoCommits => '還沒有提交。';

  @override
  String get gitClean => '沒有變更。';

  @override
  String get gitNotRepo => '這個資料夾不是 Git 倉庫。';

  @override
  String get gitDetached => '沒有分支';

  @override
  String gitAheadBehind(String upstream, int ahead, int behind) {
    return '$upstream · 領先 $ahead · 落後 $behind';
  }

  @override
  String get tasksEmpty => '沒有背景任務或隊友。';

  @override
  String get tasksBackground => '背景任務';

  @override
  String get tasksTeam => '隊友';

  @override
  String get tasksStop => '停止';

  @override
  String get tasksNoOutput => '還沒有輸出。';

  @override
  String get contextEmpty => '先送出訊息才能查看 context。';

  @override
  String contextUsage(int used, int window) {
    return '約 $used / $window tokens';
  }

  @override
  String contextTokens(int count) {
    return '約 $count tokens';
  }

  @override
  String contextTools(int count) {
    return '$count 個工具';
  }

  @override
  String get terminalStarting => '啟動中…';

  @override
  String get terminalNew => '新終端';

  @override
  String get terminalsEmpty => '沒有終端。';

  @override
  String terminalExited(String code) {
    return '已結束（$code）';
  }

  @override
  String get terminalClose => '關閉終端';

  @override
  String get terminalReadOnly => '唯讀：取得控制權才能輸入。';

  @override
  String get browserUnavailable => '這台主機沒有瀏覽器。';

  @override
  String get browserEmpty => '這個工作沒有開啟瀏覽器。';

  @override
  String get browserReturn => '交還控制';

  @override
  String get browserTake => '取得控制';

  @override
  String get browserStopRecording => '停止錄影';

  @override
  String get browserRecord => '錄影';

  @override
  String get browserAgentWaiting => 'agent 在等你。';

  @override
  String get browserNoFrame => '等待頁面…';

  @override
  String get browserType => '輸入後按 Enter';

  @override
  String get checkpointsEmpty => '還沒有檢查點。';

  @override
  String get checkpointsOff => '這個專案沒有開啟檢查點。';

  @override
  String checkpointsFiles(int count, String coverage) {
    return '$count 個檔案 · $coverage';
  }

  @override
  String get checkpointsPreview => '預覽';

  @override
  String checkpointsPreviewBody(int bytes, int excluded) {
    return '複製 $bytes bytes · 略過 $excluded 個';
  }

  @override
  String checkpointsJob(String state) {
    return '復原：$state';
  }

  @override
  String get checkpointsPreviewAction => '預覽';

  @override
  String get checkpointsRecover => '復原';

  @override
  String get checkpointsContinue => '在新對話繼續';

  @override
  String get settingsGeneral => '一般';

  @override
  String get textSize => '文字大小';

  @override
  String get textSmall => '小';

  @override
  String get textDefault => '預設';

  @override
  String get textLarge => '大';

  @override
  String get textLarger => '更大';

  @override
  String get startTab => '打開 App 時';

  @override
  String get settingsThisDevice => '這台裝置';

  @override
  String get thisDeviceWebHint => '留空則由 Gateway 依瀏覽器命名。';

  @override
  String get thisDeviceNameRule => '名稱需為 1 至 60 個字元。';

  @override
  String get thisDeviceSaved => '已儲存裝置名稱。';

  @override
  String get settingsAccount => '帳號與這台裝置';

  @override
  String get accountName => '帳號';

  @override
  String get accountGateway => 'Gateway';

  @override
  String get unpair => '取消配對這台裝置…';

  @override
  String get unpairTitle => '取消配對這台裝置？';

  @override
  String get unpairBody => '這台裝置的權杖和草稿會被移除。重新配對需要新的連結。';

  @override
  String get unpairConfirm => '取消配對';

  @override
  String get settingsAbout => '關於';

  @override
  String get aboutApp => 'App 版本';

  @override
  String get aboutGateway => 'Gateway 版本';

  @override
  String get aboutLicences => '授權';

  @override
  String get settingsAi => 'AI';

  @override
  String get settingsProviders => '模型供應商與預設模型';

  @override
  String get settingsMemory => '記憶';

  @override
  String get settingsModes => '模式';

  @override
  String get settingsNotificationsAndAccess => '通知與權限';

  @override
  String get settingsNotifications => '通知';

  @override
  String get settingsCalendar => '行事曆與 agent 權限';

  @override
  String get accessProvidersReason => '變更模型供應商需要先在瀏覽器短暫核准。';

  @override
  String get providersDefaultModel => '預設模型';

  @override
  String get providersList => '供應商';

  @override
  String providersRow(String api, int count) {
    return '$api · $count 個模型';
  }

  @override
  String get providersReplaceKey => '更換 API key';

  @override
  String get providersRemove => '移除';

  @override
  String get providersAdd => '新增供應商';

  @override
  String get providersAccounts => '帳號';

  @override
  String get providersConnected => '已登入';

  @override
  String get providersNotConnected => '未登入';

  @override
  String get providersSignOut => '登出';

  @override
  String get providersSignIn => '登入';

  @override
  String get providersApiKey => 'API key';

  @override
  String get providersPreset => '供應商';

  @override
  String get providersId => '在這個 Gateway 的名稱';

  @override
  String providersModelsFound(int count) {
    return '找到 $count 個模型';
  }

  @override
  String get providersFindModels => '尋找模型';

  @override
  String providersSignInTo(String name) {
    return '登入 $name';
  }

  @override
  String get providersConsent => '我同意這個供應商透過 pirc 使用的條款。';

  @override
  String get providersOpenAddress => '開啟這個網址並登入：';

  @override
  String get providersSignedIn => '已登入。';

  @override
  String get memoryRestore => '還原';

  @override
  String get memoryForget => '忘記';

  @override
  String get memoryProposals => '等你回答';

  @override
  String get memoryReject => '拒絕';

  @override
  String get memoryApprove => '核准';

  @override
  String get memoryAboutYou => '關於你';

  @override
  String get memoryNone => '還沒有。';

  @override
  String get memoryNotes => '筆記';

  @override
  String get memoryRemoved => '已移除';

  @override
  String get pushTargets => '通知送到哪裡';

  @override
  String get pushNone => '還沒有裝置接收通知。';

  @override
  String get pushFailing => '傳送失敗';

  @override
  String get pushSendTest => '送出測試通知';

  @override
  String pushSent(int count) {
    return '已送到 $count 個目標。';
  }

  @override
  String get calendarAllowRead => 'agent 可以讀取行事曆';

  @override
  String get calendarAllowPropose => 'agent 可以提議變更';

  @override
  String get calendarAllowProposeNote => '每個變更都會在對話中等你回答。';

  @override
  String get modesNoWarnings => 'Gateway 目前不回報模式檔案和警告，請看它的記錄。';

  @override
  String get transitionTitle => '切換主機中';

  @override
  String get transitionCancelled => '已取消切換，工作留在原處。';

  @override
  String get transitionStopping => '停止原主機上的工作';

  @override
  String get transitionRevoking => '確認已撤銷原本的權限';

  @override
  String get transitionPreparing => '準備新主機';

  @override
  String get transitionSwitched => '已切換';

  @override
  String get transitionSourceOffline => '原主機離線。原主機確認前，新主機上不會開始任何事。';

  @override
  String get transitionNeedsAck => '有些權限無法證明已撤銷，請檢查後再繼續。';

  @override
  String get transitionNeedsAuthority => '切換的授權已過期，請更新後繼續。';

  @override
  String get transitionUncertain => '不確定上一步是否送達，正在等主機。';

  @override
  String get transitionPlanChanged => '計畫已變更，請重新預覽。';

  @override
  String get transitionAcknowledge => '仍然繼續';

  @override
  String get transitionReauthorize => '更新授權';

  @override
  String get transitionCancel => '取消切換';

  @override
  String get composerTransitioning => '切換主機中，草稿已保留。';

  @override
  String get envFolders => '資料夾與權限';

  @override
  String get envRead => '唯讀';

  @override
  String get envWrite => '讀寫';

  @override
  String get envDeny => '不可存取';

  @override
  String get envRevoke => '移除';

  @override
  String get envAddFolder => '加入資料夾';

  @override
  String get envFolderPath => '主機上的資料夾路徑';

  @override
  String get envSwitch => '切換主機…';

  @override
  String get envSwitchTo => '切換到';

  @override
  String envPreviewTitle(String target) {
    return '切換到 $target？';
  }

  @override
  String get envPreviewStops => '原主機上執行中的工作、終端和瀏覽器會停止。';

  @override
  String get envPreviewStays => '對話、任務和草稿會保留。檔案不會複製。';

  @override
  String get envConfirm => '切換';

  @override
  String get envBlockedCrossNode => '還不能移到另一台主機。';

  @override
  String get envBlockedPendingWork => '這裡還有工作在執行。';

  @override
  String get envBlockedNode => '主機離線或不支援。';

  @override
  String get envBlockedUnchanged => '這就是目前的環境。';

  @override
  String get envBlockedResource => '目標缺少資料夾或資源。';

  @override
  String get scopeOccurrence => '只有這一次';

  @override
  String get scopeFollowing => '這次和之後';

  @override
  String get scopeSeries => '整個系列';

  @override
  String get eventNew => '新事件';

  @override
  String get eventEdit => '編輯';

  @override
  String get eventTitle => '標題';

  @override
  String get eventAllDay => '整天';

  @override
  String get eventStart => '開始（YYYY-MM-DD）';

  @override
  String get eventTime => '時間（HH:mm）';

  @override
  String get eventEnd => '結束（YYYY-MM-DD）';

  @override
  String get eventRepeat => '重複';

  @override
  String get repeatNone => '不重複';

  @override
  String get repeatDaily => '每天';

  @override
  String get repeatWeekly => '每週';

  @override
  String get repeatMonthly => '每月';

  @override
  String get repeatYearly => '每年';

  @override
  String get eventLocation => '地點';

  @override
  String get eventNotes => '備註';

  @override
  String get taskNew => '新 agent 任務';

  @override
  String get taskEdit => '編輯任務';

  @override
  String get taskPrompt => 'agent 要做的事';

  @override
  String get taskPickTarget => '選擇專案';

  @override
  String get taskRepeats => '重複';

  @override
  String get taskCron => '時間（cron）';

  @override
  String get taskCronHelp => '分 時 日 月 星期，例如 0 9 * * 1-5';

  @override
  String get taskAt => '時間';

  @override
  String get calendarNew => '新增';

  @override
  String get calendarPrevious => '上一段';

  @override
  String get calendarNext => '下一段';

  @override
  String get viewMonth => '月';

  @override
  String get viewWeek => '週';

  @override
  String get viewDay => '日';

  @override
  String get viewList => '清單';

  @override
  String get calendarToday => '今天';

  @override
  String get taskMissed => '已錯過';

  @override
  String get taskMark => 'agent 任務';

  @override
  String get taskPlanned => '預定';

  @override
  String get taskDone => '完成';

  @override
  String get calendarItemGone => '這個項目已不在顯示的範圍內。';

  @override
  String get eventDeleteTitle => '刪除這個事件？';

  @override
  String get eventRepeats => '重複';

  @override
  String get taskAllowRun => '現在執行';

  @override
  String get taskDismiss => '略過';

  @override
  String get taskTargetGone => '已暫停：它的專案已不存在。請編輯並選擇新的專案。';

  @override
  String get taskPaused => '已暫停';

  @override
  String get taskRunNow => '立即執行';

  @override
  String get taskResume => '繼續';

  @override
  String get taskPause => '暫停';

  @override
  String get legendEvent => '個人事件';

  @override
  String calendarDayCount(String day, int count) {
    return '$day · $count 項';
  }

  @override
  String get projectRemove => '移除專案…';

  @override
  String projectRemoveTitle(String name) {
    return '移除 $name？';
  }

  @override
  String get projectRemoveBody =>
      '它會從列表中移除，agent 任務會暫停。資料夾、檔案和紀錄都留在主機上；再次加入同一個資料夾即可恢復。';

  @override
  String get projectRemoveConfirm => '移除';

  @override
  String get projectRemoveOffline => '主機離線。請連上主機讓它確認專案已閒置，再試一次。';

  @override
  String get projectConversations => '對話';

  @override
  String get projectResources => '資源';

  @override
  String get projectRules => '規則';

  @override
  String get capMemorySearch => '搜尋記憶';

  @override
  String get capRemoteRecall => '引用其他對話';

  @override
  String get capSchedules => '建立 agent 任務';

  @override
  String get capWebSearch => '搜尋網路';

  @override
  String get projectConfigChanged => '專案設定已變更，信任前請重新檢查。';

  @override
  String get projectConfigInvalid => '專案設定無效。';

  @override
  String get projectConfigEmpty => '這個專案沒有需要信任的設定。';

  @override
  String get projectTrusted => '已信任：會執行它的 hooks 與設定。';

  @override
  String get projectNotTrusted => '未信任：不會執行它的 hooks 與設定。';

  @override
  String get projectUntrust => '取消信任';

  @override
  String get projectTrust => '信任';

  @override
  String projectCreated(String name) {
    return '已加入 $name。';
  }

  @override
  String get projectNew => '新專案';

  @override
  String get projectHost => '主機';

  @override
  String get projectName => '名稱';

  @override
  String get projectPath => '主機上的資料夾';

  @override
  String get projectCreate => '加入';

  @override
  String get browserRecordings => '錄影';

  @override
  String get browserRecordingLoad => '載入';

  @override
  String get browserRecordingFailed => '無法載入錄影。';

  @override
  String get browserRecordingOpen => '用其他 App 開啟';

  @override
  String browserRecordingSize(String megabytes) {
    return '$megabytes MB';
  }

  @override
  String get imageLabel => '圖片';

  @override
  String get imageUnreadable => '無法顯示這張圖片。';

  @override
  String get statusCompleted => '已完成';

  @override
  String get statusStopped => '已停止';

  @override
  String get statusTimedOut => '逾時';

  @override
  String get statusPending => '等待中';

  @override
  String get statusInProgress => '進行中';

  @override
  String get jobPreparing => '準備中';

  @override
  String get jobReady => '已就緒';

  @override
  String get jobOpened => '已開啟';

  @override
  String get jobStale => '已過期';

  @override
  String get jobInterrupted => '已中斷';

  @override
  String get operationRecorded => '已記錄';

  @override
  String get resultKindMarkdown => '文件';

  @override
  String get resultKindCode => '程式碼';

  @override
  String get resultKindTable => '表格';

  @override
  String get timeZone => '時區';

  @override
  String timeZoneDevice(String offset) {
    return '跟隨這台裝置（UTC$offset）';
  }

  @override
  String timeZoneUtc(String offset) {
    return 'UTC$offset';
  }

  @override
  String get timeZoneNote => '行事曆以這個時區顯示時間，並以它建立活動與工作。';

  @override
  String get newPotTitle => '新增 pots';

  @override
  String newPotStep(int step, String title) {
    return '$step / 4 · $title';
  }

  @override
  String get newPotStepLook => '外觀與個性';

  @override
  String get newPotStepWork => '工作內容';

  @override
  String get newPotStepReach => '能做什麼';

  @override
  String get newPotStepModels => '模型';

  @override
  String get newPotNext => '下一步';

  @override
  String newPotCreate(String name) {
    return '建立$name';
  }

  @override
  String get newPotCreatePlain => '建立';

  @override
  String get potThisPot => '它';

  @override
  String get potAvatarColors => '頭像顏色';

  @override
  String potAvatarColor(int n) {
    return '顏色 $n';
  }

  @override
  String get potAvatarUpload => '上傳圖片';

  @override
  String get potAvatarNote => '頭像預設用名字的第一個字';

  @override
  String get potAvatarChoose => '換一張圖片';

  @override
  String get potAvatarRemove => '移除圖片';

  @override
  String get potAvatarUploading => '正在上傳圖片…';

  @override
  String get potGroupBasic => '基本';

  @override
  String get potName => '名字';

  @override
  String get potNameHint => '怎麼稱呼它';

  @override
  String get potGroupPersonality => '個性（soul）';

  @override
  String get potTemplateRigorous => '嚴謹';

  @override
  String get potTemplateConcise => '簡潔';

  @override
  String get potTemplateFriendly => '友善';

  @override
  String get potTemplateCustom => '自訂';

  @override
  String get potTemplateRigorousText => '精確細心，回答前先查證，不確定時直說，寧可正確也不求快。';

  @override
  String get potTemplateConciseText => '簡短直接，用最少的字回答，不寒暄。';

  @override
  String get potTemplateFriendlyText => '溫暖、鼓勵人，用平常的話說明，確認你對下一步沒有疑問。';

  @override
  String get potPersonalityHint => '它怎麼說話';

  @override
  String get potPersonalityNote => '個性只影響說話方式，不會給它任何權限。';

  @override
  String get potGroupPreview => '說話預覽';

  @override
  String get potPreviewRigorous =>
      '查到了：iPad 浮動鍵盤時 viewInsets 會回報 0。來源：Flutter MediaQuery 文件。';

  @override
  String get potPreviewConcise => '浮動鍵盤：viewInsets 是 0。';

  @override
  String get potPreviewFriendly =>
      '好消息，找到了！浮動鍵盤時 viewInsets 會是 0。要我帶你看文件裡的位置嗎？';

  @override
  String get potPreviewCustom => '這是我查到的浮動鍵盤與 viewInsets 的資料。';

  @override
  String get potPreviewNote => '預覽，不是真的回覆';

  @override
  String get potGroupIntro => '簡介';

  @override
  String get potIntroHint => '一句話說明它做什麼';

  @override
  String get potIntroNote => '顯示在聊天列表和 @ 選單，讓你和其他 pots 知道該找誰。';

  @override
  String get potGroupDescription => '工作說明';

  @override
  String get potDescriptionHint => '它該怎麼做事';

  @override
  String get potDescriptionNote => '告訴它怎麼做事。和個性一樣，寫在這裡不會給它權限。';

  @override
  String get potGroupResponsibilities => '負責的事';

  @override
  String get potAddResponsibility => '新增負責的事';

  @override
  String get potResponsibilityNew => '新增負責的事';

  @override
  String get potResponsibilityEdit => '負責的事';

  @override
  String get potResponsibilityTitle => '標題';

  @override
  String get potResponsibilityDetail => '細節（可不填）';

  @override
  String get potMoveUp => '上移';

  @override
  String get potMoveDown => '下移';

  @override
  String get potRemove => '移除';

  @override
  String potTooLong(int max) {
    return '最多 $max 個字';
  }

  @override
  String get potNameMissing => '請輸入名字';

  @override
  String get potGroupReach => '能做到哪裡';

  @override
  String get potReachAnswer => '只回答你';

  @override
  String get potReachAnswerDetail => '不主動觀察，也不能開始工作';

  @override
  String get potReachObserve => '觀察並提出建議';

  @override
  String get potReachObserveDetail => '只看你允許的範圍；建議要你決定才會做';

  @override
  String get potReachWork => '可以開始工作';

  @override
  String potReachWorkDetail(String name) {
    return '在預設位置開工作；每個工作標示 From $name，並花額度';
  }

  @override
  String get potGroupObserve => '能看什麼';

  @override
  String get potObserveCalendar => '行事曆';

  @override
  String get potObserveCalendarDetail => '行事曆上的活動';

  @override
  String get potObserveSchedules => '排程';

  @override
  String get potObserveSchedulesDetail => '排程的執行與結果';

  @override
  String get potObserveWorkspace => '專案';

  @override
  String get potObserveProject => '聊天專案';

  @override
  String get potObserveSession => '工作';

  @override
  String get potObserveWorkspaces => '專案';

  @override
  String get potObserveProjects => '聊天專案';

  @override
  String get potObserveSessions => '工作';

  @override
  String get potObserveAdd => '新增專案或工作';

  @override
  String get potObserveNothing => '沒有其他可新增的項目。';

  @override
  String get potObserveOff => '只回答你時，它不觀察任何東西。選「觀察並提出建議」才能讓它看更多。';

  @override
  String get potGroupDmSend => '私訊其他 pots';

  @override
  String get potGroupDmReceive => '接收其他 pots 的私訊';

  @override
  String get potDmAll => '所有 pots';

  @override
  String get potDmSelected => '選擇的';

  @override
  String get potDmOff => '關閉';

  @override
  String get potDmNoPots => '還沒有其他 pots。';

  @override
  String potDmNote(String name) {
    return '私訊都記在動態，你都看得到。關閉後，$name和其他 pots 只能在群組裡說話。';
  }

  @override
  String potDmOffNote(String name) {
    return '$name不會和其他 pots 私訊；群組裡的對話不受影響。';
  }

  @override
  String get potGroupWork => '開工';

  @override
  String get potWorkLocationAdd => '新增開工位置';

  @override
  String get potWorkLocationsNone => '沒有可新增的專案。';

  @override
  String get potAccessRead => '唯讀';

  @override
  String get potAccessWrite => '可讀寫';

  @override
  String potAccessLabel(String access) {
    return '權限：$access';
  }

  @override
  String potRemoveNamed(String name) {
    return '移除$name';
  }

  @override
  String get potMaxWorks => '同時進行的工作';

  @override
  String potMaxWorksValue(int count) {
    return '最多 $count 個';
  }

  @override
  String get potFewer => '減少';

  @override
  String get potMore => '增加';

  @override
  String potWorkNote(String name) {
    return '它開的每個工作都標示「From $name」，你隨時可以接管。';
  }

  @override
  String get potGroupBudget => '額度';

  @override
  String get potBudgetMoney => '每月金額';

  @override
  String get potBudgetTokens => '每天 token';

  @override
  String get potBudgetDollars => 'US\$';

  @override
  String get potBudgetTokenUnit => 'tokens';

  @override
  String get potBudgetInvalid => '請輸入大於 0 的數字';

  @override
  String get potBudgetNote =>
      '它自己和它開的工作都算在裡面；用完就停止開新工作並通知你。token 上限一定有效：訂閱的用量只有在開啟「顯示 API 等值價格」時才算進金額。';

  @override
  String get potGroupReview => '自主檢視';

  @override
  String get potReviewOff => '關閉';

  @override
  String get potReviewDay => '1 天';

  @override
  String get potReviewTwoDays => '2 天';

  @override
  String get potReviewWeek => '1 週';

  @override
  String get potReviewNote => '多久自己回顧一次負責的事和工作。';

  @override
  String potReachNote(String name) {
    return '建立後都能在$name的設定裡改。權限改小時立即生效，進行中的工作會依新權限重新檢查。';
  }

  @override
  String potGroupOwnModels(String name) {
    return '$name自己用的模型';
  }

  @override
  String get potMainModel => '主模型';

  @override
  String potFallback(int n) {
    return '備援 $n';
  }

  @override
  String get potAddFallback => '新增備援';

  @override
  String get potRemoveFallback => '移除這個備援';

  @override
  String get potModelsNote =>
      '主模型不能用（額度用完、服務中斷、主機離線）時依序改用備援；切換會記在動態，主模型恢復後自動換回。';

  @override
  String get potNoModels => 'Gateway 還沒有提供模型。';

  @override
  String get potModelsLoading => '正在載入模型…';

  @override
  String get potPickModel => '選擇模型';

  @override
  String get potGroupThinking => '思考程度';

  @override
  String get potThinkingNone => '這個模型沒有思考程度';

  @override
  String get potThinkingAuto => '依情況自己調整';

  @override
  String get potThinkingAutoDetail => '平常用上面選的程度，需要時自己調高或調低';

  @override
  String potThinkingAutoOn(String level) {
    return '平常用「$level」。它覺得需要時會自己調高或調低，不會問你；每次調整都記在動態並寫出原因。';
  }

  @override
  String potThinkingAutoOff(String level) {
    return '一直用「$level」，不會自己改。';
  }

  @override
  String get potGroupWorkModels => '開工作時可以用的模型';

  @override
  String get potModeDirect => '直接用';

  @override
  String get potModeAsk => '先問你';

  @override
  String potModeLabel(String mode) {
    return '使用方式：$mode';
  }

  @override
  String potWorkModelsNote(String name) {
    return '要用更強的模型時，$name會開一個工作、選好模型，再跟它對話；那個工作標示 From $name。設成「先問你」的模型，開工作前會等你核准。';
  }

  @override
  String potWorkModelsOff(String reach, String name) {
    return '上一步選了「$reach」，$name不能開工作，也就不能用其他模型。要讓它用更強的模型，回上一步改成「可以開始工作」。';
  }

  @override
  String get potHeaderAnswer => '只回答你';

  @override
  String get potHeaderObserve => '觀察中';

  @override
  String get potHeaderWork => '可以開工作';

  @override
  String potBudgetMonthUsed(String used, String limit) {
    return '本月 $used / $limit';
  }

  @override
  String potBudgetDayUsed(String used, String limit) {
    return '今天 $used / $limit tokens';
  }

  @override
  String potProfileOf(String name) {
    return '$name的資料';
  }

  @override
  String threadDayToday(String time) {
    return '今天 $time';
  }

  @override
  String threadDayYesterday(String time) {
    return '昨天 $time';
  }

  @override
  String threadComposerHint(String name) {
    return '傳訊息給$name…';
  }

  @override
  String threadReadOnlyDeleted(String name) {
    return '$name已刪除，這段對話只能閱讀。';
  }

  @override
  String threadReadOnlyArchived(String name) {
    return '$name已封存，這段對話只能閱讀。';
  }

  @override
  String threadRefused(String name, String reason) {
    return '沒有叫醒$name：$reason';
  }

  @override
  String get threadFailed => '無法載入這段對話。';

  @override
  String get cardReview => '查看';

  @override
  String get cardFailed => '無法載入這一項。';

  @override
  String cardUnknown(String kind) {
    return '這個版本的 App 無法顯示這一項（$kind）。';
  }

  @override
  String cardWorkCoordinatedBy(String name) {
    return '由$name協調';
  }

  @override
  String get cardWorkTakenOver => '你已接手';

  @override
  String get cardWorkMissing => '這個工作已不存在';

  @override
  String cardHandoverTitle(String pot) {
    return '$pot提議交接';
  }

  @override
  String cardHandoverTo(String to) {
    return '交給$to';
  }

  @override
  String get cardHandoverApplied => '已確認交接';

  @override
  String get cardHandoverRejected => '已拒絕交接';

  @override
  String get cardLoopTitle => '已暫停連鎖';

  @override
  String cardLoopBody(String pot, int wakes, int messages) {
    return '由$pot開始。上次有進展後，叫醒了 $wakes 次、傳了 $messages 則訊息。';
  }

  @override
  String cardLoopLastProgress(String time) {
    return '上次進展 $time';
  }

  @override
  String get cardLoopResume => '繼續';

  @override
  String get cardLoopStop => '停止連鎖';

  @override
  String get cardLoopPause => '暫停相關的 pots';

  @override
  String get cardLoopStopConfirm => '要停止這個連鎖嗎？等待中的訊息會丟棄，之後不能再繼續。';

  @override
  String get cardLoopResumed => '已繼續';

  @override
  String get cardLoopStopped => '已停止連鎖';

  @override
  String get cardLoopPotsPaused => '相關的 pots 已暫停';

  @override
  String get potActionMessage => '訊息';

  @override
  String get potActionPause => '暫停';

  @override
  String get potActionResume => '恢復';

  @override
  String get potActionHandOver => '交接';

  @override
  String get potActionActivity => '動態';

  @override
  String potHostsGroups(int count) {
    return '主持 $count 個群組';
  }

  @override
  String get potPausedBannerTitle => '已暫停。';

  @override
  String get potPausedBannerText => '新的訊息與事件會等到恢復後再送達，也不開新工作。';

  @override
  String get potProfileNoResponsibilities => '還沒有負責的事。';

  @override
  String get potProfileMayDo => '能做什麼';

  @override
  String get potProfileObserveNothing => '還沒有';

  @override
  String get potProfileWorkPlaces => '在哪裡開工';

  @override
  String get potProfileNoPlaces => '還沒有';

  @override
  String potProfilePlace(String name, String access) {
    return '$name（$access）';
  }

  @override
  String potProfileMoneyMonth(String amount) {
    return '每月 $amount';
  }

  @override
  String potProfileTokensDay(String count) {
    return '每天 $count tokens';
  }

  @override
  String potProfileReviewDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '每 $count 天',
      one: '每天',
    );
    return '$_temp0';
  }

  @override
  String get potProfileReviewWeekly => '每週';

  @override
  String get potListSeparator => '、';

  @override
  String get potProfileActivity => '最近動態';

  @override
  String get potProfileSeeAll => '查看全部';

  @override
  String get potProfileNoActivity => '還沒有動態。';

  @override
  String get potProfileMemory => '記憶';

  @override
  String get potProfileForget => '忘記';

  @override
  String get potProfileNoMemory => '還沒有筆記。';

  @override
  String potProfileMemoryNote(String name, String used, String budget) {
    return '$name自己記下的筆記，只有它會讀。已用 $used / $budget 字。';
  }

  @override
  String get activityToYou => '你';

  @override
  String potPauseTitle(String name) {
    return '暫停$name？';
  }

  @override
  String get potPauseWhile => '暫停期間';

  @override
  String get potPauseNoDelivery => '不會收到新的訊息或事件';

  @override
  String get potPauseNoDeliveryDetail => '它們會等著，恢復後再送達';

  @override
  String get potPauseWait => '自主檢視與提醒先等著';

  @override
  String get potPauseNoWork => '不開新工作';

  @override
  String get potPauseGoesOn => '照常';

  @override
  String get potPauseWorks => '已經開的工作會繼續';

  @override
  String get potPauseWorksDetail => '各自照工作的控制進行；要停請到那個工作按停止';

  @override
  String get potPauseThreads => '它的對話照樣可以看';

  @override
  String get potPauseNothingMoves => '不移交任何東西';

  @override
  String get potPauseNothingMovesDetail => '負責的事、權限與記憶都保留；不想保留請改用交接或封存';

  @override
  String potSettingsTitle(String name) {
    return '$name的設定';
  }

  @override
  String get potSettingsSubtitle => '每一段分開儲存';

  @override
  String get potSettingsSave => '儲存';

  @override
  String get potSettingsSaved => '已儲存';

  @override
  String potSettingsConflict(String name) {
    return '$name在別處改過了，已重新讀取。你的修改還在，再儲存一次即可套用。';
  }

  @override
  String get potSettingsOther => '其他';

  @override
  String get potSettingsPause => '暫停…';

  @override
  String get potSettingsResume => '恢復';

  @override
  String get potSettingsHandOver => '交接…';

  @override
  String get potSettingsRetire => '封存或刪除…';

  @override
  String get activityKindDm => '私訊';

  @override
  String get activityKindGroupMessage => '群組';

  @override
  String get activityKindAssign => '交辦';

  @override
  String get activityKindWorkOpened => '開工';

  @override
  String get activityKindWorkInstruction => '送出指示';

  @override
  String get activityKindFileRead => '讀取';

  @override
  String get activityKindThinkingAdjust => '自動調整';

  @override
  String get activityKindFallback => '備援';

  @override
  String get activityKindAwaitingConfirm => '等你確認';

  @override
  String get activityKindAwaitingApproval => '等你核准';

  @override
  String get activityKindApprovalAnswered => '已核准';

  @override
  String get activityKindForwardedToUser => '轉給你';

  @override
  String get activityKindBudgetRequest => '申請額度';

  @override
  String get activityKindBudgetExhausted => '額度用完';

  @override
  String get activityKindLoopGuard => '已暫停連鎖';

  @override
  String get activityKindHandoverProposed => '提議交接';

  @override
  String get activityKindReview => '自主檢視';

  @override
  String get activityKindReminderSet => '提醒';

  @override
  String get activityKindAutonomyChanged => '自主設定';

  @override
  String get activityKindStatus => '狀態';

  @override
  String get potProfileArchived => '已封存';

  @override
  String get handoverKindResponsibility => '負責';

  @override
  String get handoverKindReminder => '追蹤';

  @override
  String get handoverKindWork => '工作';

  @override
  String get handoverKindGroupHost => '主持';

  @override
  String get handoverToLabel => '交給';

  @override
  String get handoverMeAvatar => '我';

  @override
  String get handoverNoOne => '不交接';

  @override
  String get handoverFitOk => '權限足夠';

  @override
  String get handoverFitOkYou => '由你直接管理，等同接管';

  @override
  String handoverNeedsReach(String reach, String name) {
    return '需要：和$name一樣「$reach」';
  }

  @override
  String handoverWillDo(String text) {
    return '會做：$text';
  }

  @override
  String get handoverNeedsNothing => '需要：不用其他權限';

  @override
  String get handoverReminderDoes => '會做：在設定的時間提醒';

  @override
  String get handoverNeedsWork => '需要：可以在這個工作的位置開工作';

  @override
  String handoverWorkDoes(String name) {
    return '會做：協調這個工作；紀錄仍標示 From $name';
  }

  @override
  String get handoverNeedsMember => '需要：是這個群組的成員';

  @override
  String get handoverHostDoes => '會做：沒有 @ 時接話，並決定交給誰';

  @override
  String handoverGroupPots(int count) {
    return '$count 位 pots';
  }

  @override
  String handoverAdjust(String name) {
    return '調整$name的權限…';
  }

  @override
  String get handoverCheckLabel => '交接這一項';

  @override
  String get handoverTitle => '交接';

  @override
  String handoverRoute(String from, String to) {
    return '$from → $to';
  }

  @override
  String get handoverWho => '交給誰';

  @override
  String get handoverItems => '要交接的事';

  @override
  String handoverNote(String name) {
    return '交接後$name不再負責這些事，之後可以再交接回來。兩邊的對話和動態都會記一筆。pots 自己提出的交接也要你確認。';
  }

  @override
  String handoverProposedTitle(String name) {
    return '$name提議交接。';
  }

  @override
  String handoverProposedText(String items, String to) {
    return '它想把$items交給$to，你確認後才生效。';
  }

  @override
  String handoverQuoted(String text) {
    return '「$text」';
  }

  @override
  String get handoverNext => '下一步';

  @override
  String handoverConfirm(int count, String name) {
    return '交接 $count 項給$name';
  }

  @override
  String get handoverReject => '拒絕';

  @override
  String handoverNothingFits(String name) {
    return '這些事都不能交給$name；請拒絕或重新選擇。';
  }

  @override
  String get handoverApplied => '已交接。';

  @override
  String get handoverRejected => '已拒絕，沒有交接任何事。';

  @override
  String handoverTokensLeft(String tokens) {
    return '今天剩 $tokens tokens';
  }

  @override
  String get handoverYouSub => '工作交給你；其他事會停止';

  @override
  String handoverEmpty(String name) {
    return '$name目前沒有可以交接的事。';
  }

  @override
  String retireTitle(String name) {
    return '移除$name';
  }

  @override
  String get retireSubtitle => '先決定事情交給誰';

  @override
  String get retireArchive => '封存';

  @override
  String get retireDelete => '刪除';

  @override
  String get retireArchiveNote => '封存：停止運作，保留個性與記憶，之後可以恢復。';

  @override
  String get retireDeleteNote => '刪除：移除個性、記憶與設定，無法復原。';

  @override
  String retireItems(int count) {
    return '可以交接 · $count';
  }

  @override
  String get retireItemsNote => '點一項看細節。交接只轉移事情，不轉移權限。';

  @override
  String get retireGiveAll => '全部交給…';

  @override
  String get retireStops => '會移除或失效';

  @override
  String get retireKept => '保留';

  @override
  String retireArchiveButton(String name) {
    return '交接並封存$name';
  }

  @override
  String retireDeleteButton(String name) {
    return '交接並刪除$name';
  }

  @override
  String retirePickTitle(String item) {
    return '$item交給誰？';
  }

  @override
  String get retirePickSub => '接手者只用自己的權限；不夠時會縮小範圍，不會自動加權限';

  @override
  String get retirePickAllTitle => '全部交給誰？';

  @override
  String get retirePickAllSub => '每一項都會改成同一位；之後還能個別調整';

  @override
  String get retirePickAllFits => '每一項權限都足夠';

  @override
  String retirePickAllMisfits(int count) {
    return '$count 項權限不足';
  }

  @override
  String retireDeleteTitle(String name) {
    return '刪除$name？';
  }

  @override
  String retireDeleteBody(String name) {
    return '它的個性、記憶與設定會永久移除，對話會保留為唯讀。輸入「$name」確認。';
  }

  @override
  String get retireDeleteField => 'pots 名稱';
}

/// The translations for Chinese, as used in Taiwan (`zh_TW`).
class AppLocalizationsZhTw extends AppLocalizationsZh {
  AppLocalizationsZhTw() : super('zh_TW');
}
