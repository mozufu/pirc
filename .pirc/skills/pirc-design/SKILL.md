---
name: pirc-design
description: Design and implement pirc mobile interfaces and agent result presentations using the approved Claude Design C handoff. Use for mobile screens, panels, notifications, overlays, and structured result artifacts in this project.
---

# pirc 設計與成果呈現

## 設計依據

以專案根目錄 `pirc-mobile-handoff/design-spec.md`、`components.md`、`tokens.json` 和對應 `prototype/*C.dc.html` 為依據。已畫出的頁面沿用版型與狀態；稿外頁面使用同一套元件語言。原型是假資料，功能與欄位以原 Kotlin App、web 和 gateway 接口為準。

- 浮起表面使用陰影；成組內容使用底色；分隔線只用於列表、表格、欄位。避免陰影再加外框。
- Flutter 使用 `lib/theme.dart` 語意色與 `live/common.dart` 共用元件。原生浮窗讀取同一份 tokens，注意 `rgba()` 與深色主題。送出使用墨色，藍色表示選取、連結、執行中。
- UI 系統字體；正文 16/28、閱讀 16.5/29、列表 15/22、副文 13/18、卡片標題 17/24。圖示使用 Lucide 線條，操作觸控區至少 44–48。
- 維持抽屜、置中手機標題、底部圓角 composer；不新增底部分頁。600 以下單欄，600–839 側欄 280 或雙欄各半，840 起右欄開啟時對話 480，側欄收起。平板各窗格自己的標題與返回控制。
- 新頁面同時處理載入、空白、離線、失敗、過期、唯讀與重試。App 內提示使用 `showNotice`；Android 通知權限與系統通知外殼仍由 OS 管理。

## 互動約束

成果新版提示後由使用者切換，每版保留阅读位置。切換版型、面板與返回時保存草稿、檔案路徑、閱讀版本和展開狀態。使用者在讀舊訊息時，串流僅顯示新內容入口。

通知選項僅帶預選答案；先重新取得 snapshot，驗證問題、epoch、到期及控制權，使用者確認後才提交。選取、關閉、查看均不等於處理。結果不明保留不確定狀態，修改操作不自動重送。沒有來源資料時不要虛構處理者、時間、來源數或執行進度。

## Agent 成果

需要可閱讀與可更新的成果時，讀 [成果格式](references/artifacts.md)。透過既有 assistant 訊息輸出 `pirc-artifact` 區塊，沿用相同 id，以增加的 version 更新；已發布版本不可改写。一般短答維持 Markdown。此格式不要求新增後端 API，其他客戶端可看到原始文字。

## 驗證

依修改範圍執行 `apps/mobile` 的 analyze、相關互動測試、原生單元測試或 emulator 整合測試。可用 `tool/capture_ui_test.dart` 產生深淺色頁面截圖，與交付原型核對；中文字體使用 Android 字體，缺字的測試截圖不能作為視覺完成證據。涉及寬度時涵蓋手機、平板與 2 倍字體；通知／浮窗改動需查看實際 Android 畫面。區分假 gateway 驗證與真實部署驗收，不以測試數量宣稱整個產品完成。
