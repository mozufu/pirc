# 0.5.0 交付驗證

日期：2026-10-02。依據：使用者要求完成介面後再交測、Claude Design C handoff、原 Kotlin App 的 API。

## 介面覆蓋

| 區域 | 本輪狀態 |
|---|---|
| 首次權限、配對與 QR | 既有引導與 release R8 掃描修正保留，錯誤使用共用提示 |
| 首頁、聊天／工作側欄、模型／思考 | 實際 createSession、模型接口；長按命名／釘選／完成；草稿保存 |
| 對話、工具與問題 | 工具步驟群組、問題確認／選取／輸入／editor、到期計時、控制權與結果不明 |
| 手機與平板 | 600／840 斷點、窗格標題、右欄返回、草稿／檔案路徑／閱讀版本保留、兩倍字級 |
| 檔案／Git | 路徑導覽、實際變更標記、最近工具讀取路徑、內容／Markdown、diff／提交歷史 |
| 終端 | 真正 native WebSocket + xterm；唯讀、接管、字級、Ctrl／Alt、額外按鍵、複製／貼上／清除／關閉 |
| Tasks／記憶／瀏覽器 | 背景指令及停止、隊友／任務／訊息、記憶觀察與來源、瀏覽器交接／分頁／錄影／操作截圖／空白與錯誤狀態 |
| 活動、排程與記憶提案 | 待處理快照、部分來源失敗不遮蔽其他項目；原有新增／編輯／執行／略過及審閱接口 |
| 設定與通知 | 持久類別偏好、外觀、鎖屏公開版本、勿擾、工作空間靜音、UnifiedPush 註冊與目標 |
| 原生跨 App 浮窗 | 問題／錯過排程、確認中／可回答／已處理／過期／離線／被其他裝置控制／結果不明；選擇後才送出 |
| 成果 | 原訊息承載版本化 artifact；Markdown／code／table／image，未知類型 fallback；複製／分享／來源；新版明確切換、不覆寫完成版本 |
| 設計 skill | `.pirc/skills/pirc-design`，實際 pirc skill loader 可發現，官方 quick_validate 通過 |

## 已執行的驗證

- Flutter analyze：無問題。
- Flutter 行為回歸：62 個。包括全部工作面板在 390／600／768／1024 寬、深／淺色、2 倍字體；檔案切換／關閉／重開／旋轉；通知預選與控制權；成果 immutable version／fallback／閱讀位置。
- Android 原生：46 個，原 App API、認證、控制權、排程、timeline 契約及安全讀取恢復、勿擾邊界。
- Flutter 視覺渲染：21 頁 × 深淺色 × 手機／平板 = 84 張。使用 Android NotoSansCJK 字體；檢查主要頁面、通知、閱讀、終端及不同表面。
- Android 36 模擬器 + 原 Android fake gateway：配對、snapshot／stream、送訊息、新建對話、檔案／Git、背景再連線、草稿、真 WebSocket 終端、原生偏好保存。
- Android 原生浮窗：代理原 fake gateway 產生 ready／handled／expired／offline／controlled／missed schedule 狀態，逐一截取實際跨 App 畫面。最後以 adb 真實點選選項和送出，HTTP 伺服器記錄 **1 次 answer**。單純查看其他狀態未送出答案。
- Release：R8 scanner registrar 保留規則檢查，APK 身分、版本與簽章檢查。

本輪驗證發現並修正：大字體標題溢位、關閉面板丟掉檔案路徑、浮窗切換外觀未換底色、無 interaction ID 通知未找到最新問題、過時預選未清除。測試工具本身的雙側欄 finder 歧義與缺字也已修正。

## 證據位置

- `build/ui-review/*-{390,1024}.png`：手機／平板渲染。
- `build/validation/0.5/`：回歸、整合、原生浮窗、release 日誌與截圖。
- `dev/review-gateway.ts`：僅監聽 127.0.0.1 的本機浮窗情境代理；不進 APK。
- `integration_test/overlay_review_test.dart`：限定 `PIRC_LOCAL_SMOKE=true`，供外部 adb 截圖／點選；不進 release 入口。

## 既有接口的資料邊界

這輪完成 mobile 可呈現與可操作的介面，未修改或部署使用者的 gateway。

- 「最近動態」為此手機接收的通知；舊 gateway 沒有全域活動歷史及處理者姓名／時間時，只顯示已處理結果。
- 完成／進度通知來自已連線對話，離開 App 停止觀察後不假造後續進度；後端既有 UnifiedPush 類別照常接收。舊 API 不提供 browser 點擊座標，因此顯示真實 action／操作紀錄，不捏造滑鼠指標。
- 舊訊息保持原本閱讀模式。Agent 需按專案 skill 的 `pirc-artifact` 格式提供版本化成果；原訊息紀錄未包含的版本無法還原。
- 推播 distributor、真實 gateway／代理、OEM 背景限制及相機 QR 實際識別沒有在使用者測試機上驗證。這與模擬器通過分開記錄。
- 此為 Android arm64 release 測試 APK，沿用之前的測試簽章；iOS 和商店發佈不在此輪。

## 最終 APK

- 檔案：`build/app/outputs/flutter-apk/pirc-mobile-0.5.0-release.apk`
- 版本：0.5.0（5）；Android 10 以上、arm64；21,801,969 bytes。
- SHA-256：`e101ff80ec20e8504524b359ddce67251f7222450127a1695fbb6ccbc9dd7d54`
- 最終 release 安裝與首次引導通過；掃描入口在模擬器回報掃描元件未備妥，顯示已套用設計的中文提示，沒有重現先前 Java 空值錯誤。這不等於相機 QR 辨識已驗證。
