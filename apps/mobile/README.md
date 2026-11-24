# pirc Flutter Android release 測試版 0.5.0

依 `pirc-mobile-handoff` 的 Claude Design C 製作 Android 手機／平板原生介面，連接既有 gateway 與 node。新版預設使用真實接口。離線驗證工具僅在開發時用 `--dart-define=PIRC_DEMO=true` 顯示，交付 APK 不提供測試資料入口。

## 安裝與配對

- APK：`build/app/outputs/flutter-apk/pirc-mobile-0.5.0-release.apk`（arm64）。
- Android 10／API 29 起；名稱「pirc」，application ID `dev.pirc.mobile.preview`。可直接覆蓋上一個驗證版，與原 Kotlin App 並存。
- 在既有 pirc 網頁的裝置設定產生配對 QR／`pirc://pair` 連結，用新版 App 掃描或貼上。QR 掃描使用 Google Play services；無 GMS 的裝置可貼上連結。
- 沿用原 App 的配對限制：HTTPS；debug 只額外允許 localhost、127.0.0.1、10.0.2.2 的 HTTP。實機以可連到 gateway 的 HTTPS 網址配對。
- 配對後從側欄選取／新增工作或聊天。需要線上的 node、工作空間及已設定的模型。
- 設定中分別開啟通知、顯示在其他 App 上層的權限。真正背景推播沿用原 App 的 UnifiedPush 3，需要安裝相容 distributor；在「推播設定」註冊並發送測試通知。

## 0.5.0：補齊行動介面與可操作狀態

- 設定：完整通知類別、原生持久偏好、鎖定畫面、勿擾、工作空間靜音、推送目標與深／淺／系統外觀。
- 通知／浮窗：最多三個預選答案進 App 重新確認；問題與錯過排程浮窗、已處理、過期、離線、無控制權及結果不明；沿用原生 API 和防重送規則。
- 手機／平板：各窗格獨立標題、右欄返回、切換分頁與尺寸保留檔案位置、成果版本與草稿；大字體標題保留單行。側欄長按支援命名／釘選／完成。
- 工作面板：数量徽章、檔案路徑導覽／變更標記／最近檔案、Git 差異、Tasks 空狀態、記憶來源、瀏覽器交接／錄影／操作截圖；PTY 全螢幕支援字級、Ctrl／Alt、符號、複製、貼上、清除與關閉。
- 成果：`pirc-artifact` 訊息容器支援 Markdown／code／table／image、摘要 fallback、來源、複製／分享、明確重試與版本選擇。版本沿用原訊息持久化，普通 Markdown 對話仍可使用。
- 專案 skill：[pirc-design](../../.pirc/skills/pirc-design/SKILL.md)，由 pirc 的既有 `.pirc/skills` 掃描器發現；格式與範例見 [成果協定](../../.pirc/skills/pirc-design/references/artifacts.md)。

完成與未覆蓋的環境條件逐項列在 [0.5 驗證紀錄](VALIDATION-0.5.md)，不以模擬器測試宣稱已驗證使用者部署。

## 0.4.0：修復安裝版錯誤並重新對照設計

本輪由使用者回報 QR 掃描崩潰、介面與原型差距而重做驗證。0.3 的單元測試通過不能證明安裝版達到原 App 的可用程度。

- 在 Android 36 模擬器安裝原 0.3 release，重現與截圖相同的 `getClass()` NullPointerException。R8 移除了 ML Kit 反射載入 registrar 的無參數建構子；新增精確保留規則。修正後 release 已通過初始化，模擬器回報正常的掃描模組下載狀態。QR 實際辨識仍需有相機／GMS 的測試機確認。
- QR 成功後直接配對，與原 App 相同；取消不配對。掃描重入、同步／非同步失敗均處理，例外堆疊不直接放進介面。
- 原先全域停用 HTTP 重試會讓已被伺服器關閉的閒置連線造成列表讀取錯誤。增加僅 GET／HEAD 的 socket／EOF 恢復，最多一次；修改操作維持不重送。
- 首頁補回 π、最近對話、待處理提示、底部輸入與模型選擇；可直接建立對話並送出。建立後遇到連線問題會保留草稿。
- 對話補副標、狀態入口、內嵌問題選項、長內容閱讀卡；進度列預設收合。手機工作面板使用獨立導航列、六個分頁與內嵌 Git 差異。
- 模型面板在同一路由內切换模型／思考子頁；選擇成功回首頁。設定使用 grouped 背景、原型表面色；終端套用 terminal tokens；提示依原型 toast 的顏色、圓角和位置。
- 共用 Surface 改為 Material，避免背景遮住 ListTile 點擊回饋。

詳細證據與驗證邊界見 [驗證紀錄](VALIDATION-0.4.md)。

## 0.3.0：稿外畫面與首次權限引導

0.3 當時的範圍依使用者澄清：檢查設計稿沒有繪製的支援畫面是否延續既有風格；已有原型的對話、工作面板、終端與設定版型不另做改版。

- 配對頁：沿用 16 邊距、24 標題與 16 正文；輸入欄位改用既有柔和底色與 12 圓角。
- 排程編輯：原型未畫完整表單，統一欄位底色／圓角及垂直間距。樣式僅限編輯表單，不更改共用主題。
- 通用載入／錯誤頁：補上骨架列、一致字級、說明與重試入口，長錯誤可捲動。
- Android 桌面圖示改為原 App 的 pirc 圖示；啟動畫面與後續背景使用設計稿的明暗色票，Android 12+ 系統 splash 亦一致。
- 新增權限引導：首次安裝或由 0.2 升級後顯示一次。通知與浮窗分別說明用途、顯示真實狀態並由使用者主動開啟；允許拒絕或稍後設定。
- Android 13+ 先使用通知 runtime 權限視窗；永久拒絕、App 通知關閉或單獨通知類別關閉時導向相應系統設定。返回 App 後重新查詢；開過設定頁不等於已授權。
- 引導完成才保存版本標記；拒絕不阻止配對。之後從「設定 → 權限與快速回應」重新查看。未要求相機、通訊錄、廣泛儲存空間或電池最佳化豁免。
- 通知權限和 UnifiedPush 註冊分開說明。取得權限不代表背景推播已可用。
- 交付採 release／AOT 模式，隱藏測試入口；沿用本機測試簽章以覆蓋安裝，並非商店正式簽章。release 僅接受 HTTPS gateway。

渲染檢查：配對、權限、排程表單、錯誤頁各明／暗色，共 8 張。可執行 `flutter test tool/capture_ui_test.dart --dart-define=PIRC_REVIEW_FONT=/path/to/CJK-font.ttf`，輸出在 `build/ui-review/`；字型路徑僅供本機檢視，不會打包進 App。

2026-10-01 驗證：靜態分析通過；39 個 Flutter 測試、41 個 Android 原生測試全部通過；8 個明暗色畫面渲染檢查通過。交付 APK 為 0.3.0（versionCode 3）、arm64、不可偵錯，21,258,349 bytes；已核對與 0.2.0 簽章相同，可覆蓋安裝。

實機目前未連線。自動測試使用模擬系統結果／原生分流規則；Android 系統權限視窗、OEM 背景限制、真實 gateway／推播尚須安裝 APK 驗收。

## 已接入的功能

| 區域 | 測試版內容 |
|---|---|
| 對話 | 聊天／工作切換、工作空間篩選、搜尋、新增、命名、釘選、完成標記 |
| Agent | snapshot + WebSocket 串流、重連、Markdown／表格／程式碼、圖片與工具輸出、附件上傳、停止、引導／排隊、模型／思考強度、目標 widget |
| 控制與回答 | 原 App 的控制 lease／heartbeat；確認、單選、多選、文字、編輯器問題；回答前再次查詢 epoch／狀態／到期時間 |
| 快速回應 | 真實 Android 跨 App 浮窗；確認／最多三個選項的單選；其餘問題回完整對話；鎖屏回通知 |
| 工作面板 | 檔案與文字預覽、Git 暫存／工作目錄 diff、提交紀錄、背景任務輸出與停止、Teammates／任務板、觀察記憶 |
| 終端 | 原生認證 WebSocket 接 PTY、ANSI／游標與終端控制序列、輸入／調整尺寸、額外按鍵、選取複製／貼上、重連 |
| 瀏覽器 | 即時畫面、接管／歸還、網址／分頁、點擊／捲動／文字／Enter、記錄、工具卡錄影開系統播放器 |
| 排程 | 新增／編輯、一次性／cron／IANA 時區、模型與通知偏好、暫停／啟用、立即執行、錯過執行與略過、刪除 |
| 記憶與動態 | 記憶提案刷新後核准／拒絕、依到期時間排列待答問題、待處理排程、此裝置收到的通知紀錄 |
| 成果閱讀 | 保留目前版本；內容完成更新後提示手動切換；每版捲動位置與草稿在旋轉、分割畫面、關閉／重開面板時保留 |

介面採交付的 tokens、Lucide 線條圖示、系統明暗色與字體、抽屜側欄、圓角輸入框。600 以下單欄；600 起支援側欄／右面板；840 起右面板開啟時對話維持 480 寬。

## 接口與程式結構

Flutter 的 `lib/live/` 實作介面與呈現狀態。`lib/main.dart` 是正式測試入口，`lib/demo.dart` 是舊驗證切片。

Gradle 的 `syncPircCore` 在 build 目錄產生來源，**直接編譯原 App 的 `apps/android/app/src/main/java/dev/pirc/android/core/` 與 `push/PushRegistration.kt`**，沒有另寫一份 HTTP／串流還原協定。此 mobile 目錄需要與原 Android 專案一起存在。

- `GatewayRuntime.kt`：PircApi、EventStream、snapshot／reducer、控制權、提交、防重送、PTY／browser sockets。
- `GatewayBridge.kt`：method／event channel、QR、Android 文件挑選與 8 MiB 附件上限、推播設定、原生影片播放器。
- `GatewayOverlayService.kt`／`GatewayNotifications.kt`：真實接口的浮窗、通知、UnifiedPush 入口。
- token 只在 Android Keystore 儲存與原生請求層使用，不回傳 Dart；沿用原 App 不跟隨 HTTP redirect 的規則，停用備份與裝置資料搬移。
- 不確定是否送達的 command／answer 在 POST 前建立持久標記。程序被回收後也不會自動重送；command 可在使用者刷新、檢查並明確確認後解除操作限制，解除本身不送出命令。答案結果不明時只可查狀態。
- 排程與記憶提案使用它們自己的接口，不要求對話控制權。

## 開發與測試

環境：Flutter 3.44.4／Dart 3.12.2、JDK 17+、Android SDK 36。

```sh
cd apps/mobile
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64
cd android
./gradlew :app:testDebugUnitTest
```

建置預設沿用同一 repo 的原 App 核心、契約測試及根目錄 `fixtures/timeline`。單獨暫存建置可設定 `PIRC_ANDROID_SOURCE`、`PIRC_ANDROID_TEST_SOURCE`、`PIRC_FIXTURES` 指向對應絕對路徑。

0.2.0 歷史紀錄（2026-09-30）：`flutter analyze` 無問題，**28 個 Flutter 測試、34 個 Android 原生測試全部通過**，在專案預設路徑成功建置 arm64 APK。APK 已核對 application ID `dev.pirc.mobile.preview`、versionName `0.2.0`、versionCode `2`、minSdk `29`、targetSdk `36`；檔案 95,506,635 bytes。

目前自動驗證範圍：

- Flutter 控制器：晚到事件不跨對話、草稿獨立保存、唯讀／離線禁止提交、結果不明不重送、切換對話不清錯草稿。
- 新介面：390／507／600／768／840／1024 寬度、兩倍字體、鍵盤與長 widget；成果手動版本及閱讀位置；已答問題不可再送；一次性排程保留時區時間與模型。
- 原生：原 App 的認證與 redirect、pairing、control、schedule 與 timeline golden 契約；新版 channel JSON 型別；問題 epoch、到期、取消與選項限制；保留舊浮窗規則測試。

## 實機驗收順序

1. 配對 → 開既有對話 → 新增對話 → 發訊息、收串流、切換 App 再返回；草稿保持。
2. 桌面持有控制權時手機應唯讀；手機明確接管後再測附件、模型、停止、引導與排隊。
3. 讓 agent 問確認／單選／多選／輸入問題；先在桌面回答再開手機，舊問題不得重送。再測跨 App 浮窗與通知入口。
4. 檔案、兩種 Git diff、終端輸入、browser 接管／捲動與錄影播放；旋轉及平板分割畫面。
5. 新增測試排程、手動執行一次、開執行對話；審閱記憶提案、註冊 UnifiedPush、發送測試通知。
6. 斷網、恢復、鎖屏、程序回收、推播到達；確認過期問題與結果不明不會自動提交。

## 此版本的邊界

- 使用者已回報 0.1.0 本機驗證版實機測試通過；0.2.0 的真實 gateway／實機推播與廠商背景限制仍需以上流程驗收。自動測試使用契約 fixtures／假 gateway，沒有宣稱已在你的真實帳號端到端通過。
- 浮窗目前由使用者在 App 或通知內明確開啟；**推播到達後自動開浮窗未實作**。
- 成果使用新定義的 `pirc-artifact` 訊息格式；已發布版本由原有訊息歷史還原。一般 Markdown 的閱讀快照、版本選擇與各版本捲動位置保留在本次 App 工作階段。HTML／JavaScript 僅提供摘要／網頁入口；其他客戶端需自行支援此格式。
- 最近動態為此裝置收到的通知，並非伺服器全域活動紀錄；不虛構其他裝置處理者或處理時間。
- 檔案面板目前預覽文字／Markdown、標示二進位檔；尚未提供任意檔案下載或編輯。模型帳號與裝置管理導回原網頁設定。
- iOS 不在已確認的 Android 首版範圍。此 APK 使用 release 模式與本機測試簽章。
- 工作完成／即時進度來自此手機已連線對話的事件；跨裝置全域完成推播、處理者姓名／時間與全域活動歷史仍需要 gateway 提供資料。通知設定內已標示此範圍。
