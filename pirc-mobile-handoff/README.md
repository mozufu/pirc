# pirc 行動版設計交付（方向 C）

2026-09-30 · 依據 pirc commit `c4b7dd3`

已確認第一版範圍（1A／2A／3A）：**Android 手機＋平板、快速回應浮窗必備、成果新版由使用者手動切換**。Flutter／Android 驗證版已建立於 `apps/mobile`，使用本機測試資料，已建置 APK；接下來先做真機驗收，再移植完整介面。

| 檔案 | 內容 | 給誰 |
|---|---|---|
| `design-spec.md` | 已定決定、畫面地圖、版型與返回規則、輸入與鍵盤、通知流程、成果容器、工作面板、狀態涵蓋、既有功能入口對照、後端需求、未決事項、Flutter 實作提示 | Flutter 工程、後端 |
| `tokens.json` | 語意 design tokens（light／dark／terminal、字級、圓角、間距、陰影、尺寸、版型門檻、動畫） | Flutter 主題（ThemeExtension）、web 同步 |
| `components.md` | 元件清單與變體、狀態、對應 tokens | Flutter 工程 |
| `design-rules.md` | App 介面規則與 agent 內容呈現規則 | 後續 `pirc-design` skill |
| `flutter-validation.md` | 已確認範圍、第一階段驗收流程、本機環境檢查與尚未驗證事項 | Flutter／Android 工程 |
| `prototype/` | 原型原始碼（網頁模擬，僅供對照數值；不能編譯成 App） | 參考 |

可互動原型在 Design 畫布「C · 網頁風格（目前方向）」頁；第一輪 A／B 方向留在另一頁。

目前交付的 `prototype/*.dc.html` 引用 `support.js`，但資料夾與 ZIP 均未包含該檔。本機尚未驗證原型互動；實作依據為規格、tokens 與元件文件。原始 ZIP 保留不修改，後續確認以此目錄中的文件為準。

放進 repo 時注意：`.pirc/` 目前整個被 `.gitignore` 忽略。若 skill 放在 `.pirc/skills/pirc-design/`，需要調整追蹤規則；或把正式來源放在 `skills/pirc-design/` 再同步。
