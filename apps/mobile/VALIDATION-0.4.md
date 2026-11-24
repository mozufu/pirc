# 0.4.0 修正與驗證紀錄

日期：2026-10-01。設計來源為 `pirc-mobile-handoff/prototype` 與 `components.md`、`tokens.json`，未改動使用者的交付稿。

## 兩個可重現的執行問題

### Release 掃描器初始化崩潰

1. 在乾淨 Android 36 arm64 Google APIs 模擬器安裝交付的 0.3 release。
2. 略過首次權限，按「掃描 QR code」。logcat 重現 `java.lang.NullPointerException: Attempt to invoke virtual method 'java.lang.Class java.lang.Object.getClass()' on a null object reference`。
3. 0.3 R8 usage 報告列出 `CommonComponentRegistrar`、`VisionCommonRegistrar` 無參數建構子遭移除；這些類別由 manifest metadata 經反射實例化。
4. 在 release 引入 `proguard-rules.pro`，明確保留 registrar 建構子。相同模擬器的修正版通過初始化，收到 ML Kit 200（掃描模組正在下載），沒有先前 NPE。
5. 可用掃描模組／相機的實體裝置尚未連接，不能將「初始化修正」等同「QR 已實際辨識」。

### 閒置連線上的讀取失敗

Android 整合測試期間看到實際 `Http1ExchangeCodec.readResponseHeaders` IOException。Flutter 客戶端原本全域關掉 OkHttp 重試，與原 App 的讀取恢復行為不同。

新增 `ReadRecovery`，只對 GET／HEAD 的 EOF／socket 斷線恢復一次，排除取消與 WebSocket upgrade。POST／PATCH／DELETE 不重播。MockWebServer 在讀完請求後中斷連線的測試驗證：GET 收到第二次回應；修改操作僅抵達伺服器一次；連續 GET 失敗最多兩次請求。

## 已執行

| 檢查 | 結果／範圍 |
| --- | --- |
| Flutter 靜態分析 | 通過 |
| Flutter 單元／widget 回歸 | 42 個通過；包含掃描成功／取消、錯誤提示、模型內部分頁、閱讀位置、鍵盤與大字 |
| Android 原生回歸 | 44 個通過；含原 App API／reducer／控制權測試，以及新增斷線恢復測試 |
| Android 整合流程 | 真實 MethodChannel、HTTP、WebSocket；配對、列表、串流、送出回覆、Git、檔案、終端建立／連線／關閉、草稿保存、前後台連線、首頁建立並送出皆通過 |
| 視覺渲染 | 10 種畫面各明／暗色，共 20 張；配對、權限、表單、錯誤、首頁、對話、設定、面板、模型、問題卡 |
| Release 掃描回歸 | 以舊版與修正版 APK 比較，舊版 NPE 可重現，修正版通過初始化 |

Android 整合測試使用**原 App 已有的本機 fake gateway**。它驗證橋接與實際傳輸，不等同使用者部署的完整 gateway／agent 驗收，也沒有模擬假成功混入交付 App。

## 重新執行

```sh
# 在儲存庫根目錄啟動原 App 的本機測試 gateway
bun apps/android/dev/fake-gateway.ts

# 在 apps/mobile，僅對隔離模擬器執行
flutter test integration_test/gateway_smoke_test.dart -d emulator-5554 --dart-define=PIRC_LOCAL_SMOKE=true
flutter test
flutter analyze
flutter test tool/capture_ui_test.dart --dart-define=PIRC_REVIEW_FONT=/path/to/CJK-font.ttf

# release 必須允許 Flutter 重建 release 外掛註冊；整合測試後避免 --no-pub
flutter build apk --release --target-platform android-arm64
python3 tool/check_release.py
```

`tool/render_design_reference.cjs` 是所附 x-dc 原型的靜態渲染適配器，保留原 CSS 與 SVG，不是重新畫的參考稿。用 `PIRC_PLAYWRIGHT_MODULE` 指定 Playwright 模組、`PIRC_CHROME_PATH` 指定 Chrome，可生成 `build/design-reference`。Flutter 圖位於 `build/ui-review`。靜態視覺檢查不代表逐像素相同，也不驗證 API。

## 仍需要實體環境確認

- 測試機的 Google Play 掃描模組下載與真實 QR 辨識。
- 使用者 HTTPS gateway、模型端、完整排程／記憶／瀏覽器工作流。
- UnifiedPush distributor、真實背景推播、鎖屏與 OEM 背景限制、跨 App 浮窗。
- 所有實際業務狀態的逐頁視覺驗收；本輪已修正明確落差，但不宣稱已達完整原 App 功能驗收或所有設計稿逐像素一致。

既有能力邊界仍保留：閱讀版本是本次 App 工作階段的訊息快照；正式 artifact 渲染／版本協定是後續工作，沒有虛構伺服器能力。

## 最終交付檔案

- `build/app/outputs/flutter-apk/pirc-mobile-0.4.0-release.apk`
- versionCode 4；arm64-v8a；minSdk 29／targetSdk 36；不可偵錯。
- 21,194,449 bytes。SHA-256：`29dfb5eeed8a3f02532950ef0d61974e009625e56da8aa7d3558428d4b67d9e0`。
- 與 0.3 的測試簽章相同，可覆蓋安裝。
- 最終 APK 已在隔離模擬器乾淨安裝，走過首次引導、略過權限、配對頁、掃描入口；未出現 0.3 的 NPE，提示依原型樣式顯示。
- 最終畫面與 log 存於 `build/validation/release-0.4-scan.png`、`release-0.4-scan.log`。
