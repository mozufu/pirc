# pirc 成果訊息格式 v1

在 assistant 的普通 Markdown 訊息中放以下 fenced block。既有 gateway 會保存原訊息，因此歷史成果版本可由訊息紀錄還原，無須替換認證／串流 API。手機僅處理 assistant 的有效區塊；一般文字、壞掉的 JSON 或未完成的 fence 保留 Markdown。

````markdown
這是本輪結果。

```pirc-artifact
{"id":"nightly-report","version":1,"title":"Nightly 測試報告","type":"markdown","status":"complete","summary":"212 項通過，3 項需要修正","content":"## 結果\n\n登入流程需要調整。","sources":[{"title":"測試報告","url":"https://example.org/report"}]}
```
````

必填 `id`（非空字串）、`version`（正整數）、`title`（字串）。同一成果沿用 id；更新以新訊息／新區塊和更大的 version 發布。已完成版本不可覆寫。其他客戶端尚未實作此容器時可看到原始 Markdown/JSON，不能宣稱所有客戶端都有相同的渲染。

- `type: markdown`：`content` 為 Markdown。
- `type: code`：`content` 為程式碼，等寬顯示與複製，不執行。
- `type: table`：`columns` 為欄名陣列，`rows` 為二維陣列；`summary` 提供摘要。列比欄短時補空白，多出欄位不顯示。
- `type: image`：`content` 為 PNG／JPEG／WebP 的 data URI；支援縮放。大圖片應提供 `url`，由使用者在網頁開啟。
- 其他類型：顯示 `summary` 或 `content` 的 Markdown fallback；`url` 可提供 HTTP(S) 網頁入口。手機不執行 HTML／JavaScript。
- `status` 可為 `generating`、`complete`、`failed`，預設 complete。失敗可顯示最後內容並提供「請 agent 重試」，這會送出新 prompt，與本地切換版本分開。
- `sources` 可為 `{title,url}` 陣列。僅列真實引用，不編造來源數。
- 單區塊 JSON 上限 1 MiB。超過上限回退原文，避免大型內容解碼阻塞介面。

開啟成果後保持目前版本，提示有新版並等待明確切換。每版閱讀位置在本次 App 工作階段保留；訊息中已發布的版本跟隨原有伺服器歷史。清除歷史或後端未傳回舊訊息時，不會假造版本。
