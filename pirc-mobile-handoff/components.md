# pirc 行動版元件清單（方向 C）

每個元件列出：用途、變體、狀態、使用的 tokens。token 名稱見 `tokens.json`。原型 CSS 類別名稱放在括號內，方便對照畫布（`prototype/pirc-c.css`）。

區隔原則：**浮起＝陰影、成組＝底色、細線只給表格與列表分隔**。同一個元件不要同時用外框和陰影。

---

## 導航

### TopBar（c-top）
- 高 56；左側一個動作（☰、返回、✕），標題以螢幕置中，右側最多兩個動作。
- 標題：`title.bar`＋副標 `caption`，各一行省略。
- 變體：手機（置中）、平板窗格（靠左）、深色終端（`terminal.*`）。

### Drawer／Sidebar（c-drawer／c-side）
- 手機：覆蓋式，寬 318，`surface.sidebar`，只有陰影（`elevation.float` 向右）。平板：寬 280 內嵌，右側一條 `line.hairline`。
- 內容順序：品牌列（π、名稱、搜尋鍵、關閉）→ 聊天／工作切換 → 「新聊天／新工作」列 → 內容 → 底部排程、設定。
- 文字左緣統一 24。
- 「待你處理」列：黃點＋標題＋最急到期＋右側數字膠囊（`status.warningSoft`／`text.warning`），不用滿版色塊。

### ModeSwitch（c-mode）
- 兩段：聊天／工作；底 `fill.hover`，選中段 `surface.layer`＋細陰影；有待處理時「工作」右上 6px 黃點。

### FilterChips（c-filter／c-fchip）
- 高 32，全圓，底 `fill.hover`；選中改 `action.primary` 底、`action.onPrimary` 字。可橫向捲動。
- 用於 workspace 篩選、對話頂部狀態列（高 30）。

## 列表

### Row（c-row／c-drow）
- 最小高 52（側欄 48），左右內距 16（側欄 12）。
- 標題 `row`（400），副標 `secondary`。前置：狀態點、18 圖示或 32 方形圖示；後置：時間、數字、chevron、按鈕。
- 狀態：一般、按下（`fill.hover`）、選中（`fill.active`）、停用（50%）。

### InboxItem（c-inbox）
- 成組底色：頁面上 `surface.layer`，側欄內 `fill.hover`，面板內 `surface.subtle`。
- 內容：狀態點＋標題（500）＋到期（`text.warning`）；副標；動作列。
- 狀態：待處理、確認中（轉圈＋「確認最新狀態…」）、已允許、已略過、已由他處處理（顯示處理者）。

### GroupedList（c-group／c-grow）
- 設定式：`surface.grouped` 頁底上放 `surface.layer` 分組，圓角 16，無外框；分隔線從文字起點（16）開始。
- 分組標題 `label.section`，左緣 32。

### StateDot（state-dot）
- 7px；執行中（accent，脈動，減少動畫時不動）、等待（warning）、完成（success）、失敗（danger）、閒置（空心）。
- 一律搭配文字，不只靠顏色。

## 對話

### MessageUser（c-user）
- `surface.bubble`，圓角 20，最大寬 82%，靠右；`body.reading` 但行高 24。

### MessageAssistant（c-asst）
- 無容器，`body.reading`（16／28）；段落間距 10。底下一列訊息動作（複製、模型名），`caption`。

### RunCard（c-run）
- 工具步驟的收合卡：`surface.subtle` 底、圓角 12、無外框。
- 摘要列 44 高：chevron、「n 個工具步驟」、失敗數（✕＋文字）、相關檔名小膠囊。
- 展開：每步驟一列（✓／✕＋指令或標題），輸出以 `code.bg` 等寬字區塊呈現。
- 標題是規則式摘要，不假設有模型生成標題。

### QuestionCard（c-int）
- 浮起卡：`surface.layer`＋`elevation.card`，圓角 16。
- 頭部：32 圓形圖示（`accent.soft`／`accent.default`）、問題 `title.card`、說明。
- 選項（c-opt）：48 高，`fill.hover` 底，選中 `accent.soft`＋內框 1px accent；radio 標記。
- 底列：到期（時鐘＋`text.warning`）、取消、送出。
- 狀態：待答、送出中、已答（換成一行 ✓ 摘要）、過期（變淡並標示）、控制權不在此裝置（送出停用＋取得控制權）。
- 變體：select（單／複選）、confirm（是／否）、input、editor（等寬輸入區）。

### ComposerDock（c-dock）
- 輸入框上方的目標／todo／佇列區：`surface.subtle`，上方圓角 16，左右各內縮 20。
- 收合一列（狀態點、目標、進度 2/3）；展開列出步驟。鍵盤開啟時自動收合。

### Composer（c-composer）
- 浮起面板：`surface.input`＋`elevation.float`（輸入中 `floatFocus`），圓角 28，左右距螢幕 12。
- 輸入區最小 52；工具列 52：＋附件（無外框，按下才有底）、模型與思考按鈕（c-sel，全圓 `fill.hover`）、送出時機、停止、送出。
- 送出鍵：`action.primary`（墨色）；空白時 `surface.subtle` 底＋`text.faint`；執行中且空白時變停止（墨色方塊）。
- 變體：新對話、對話中、唯讀（控制權不在此裝置）、離線（上方顯示離線列）。

### ModelSheet
- 根畫面：GroupedList 兩列「模型」「思考強度」，右側顯示目前值。
- 子清單：返回＋標題；選項列，選中打勾；選完回根畫面。
- 模型不支援思考時，「思考強度」列停用並顯示「此模型不支援」。

## 成果

### ResultCard（c-res）
- 浮起卡：`surface.layer`＋`elevation.card`，圓角 16。
- 內容：類型小標（`accent.pressed`，12／600）＋版本、狀態文字、標題 `title.card`、一行摘要、來源數；動作：複製、分享、「開啟」（primary 小按鈕）。
- 狀態：生成中、完成、有新版本、失敗、不支援（見設計規格第 7 節）。返回時外框高亮 1 秒（2px accent）。

### ResultReader（c-reader）
- 全螢幕：左上 ✕，置中標題，右側複製、分享。
- 內容 `body.reader`，正文限寬 680；表格可橫向捲動；頂部「來自 … 第 n 則回覆」膠囊可回到原處。
- 版本提示（c-note）：`accent.soft` 底。

## 工作面板

### PanelTabs（c-ptabs／c-ptab）
- 六格（聊天四格）等寬，高 56，圖示 20＋文字 12；選中 `fill.hover` 底＋`text.primary`＋600。
- 數字徽章在圖示右上，`fill.hoverStrong` 底。

### GitView
- 分支列（`surface.subtle`）、變更列（狀態字母方塊 M／?、檔名等寬、+n −n）、diff 區塊（`code.bg`，新增列綠底、刪除列紅底）、最近提交。

### FileBrowser
- 路徑導覽（每段可點）；資料夾／檔案列；有變更的資料夾標 M。

### TerminalList
- 說明、新終端、終端列（名稱、`路徑 · 欄×列 · 狀態`）、已結束可移除。

### TerminalScreen（t-screen）
- 全螢幕 `terminal.bg`；頂部 52（返回、名稱＋路徑與欄×列、字級、更多）。
- 字元格 `mono.terminal`，最新一行貼底；游標用反白方塊。
- 額外按鍵列：`terminal.keys.bg` 底，按鍵 40×38、圓角 8；Ctrl 可鎖定（反白）。
- 狀態：執行中、已結束（底部顯示 exit code 與「關閉」）、無控制權（唯讀＋取得控制權）、斷線（頂部提示＋重新連線）。

### TasksView／MemoryView／BrowserView
- Tasks：背景工作區塊（`surface.subtle`，可停止）、teammates 列、任務板、訊息。
- 記憶：狀態膠囊、觀察列（附來源）、反思區塊（兩行截斷＋展開）。
- 瀏覽器：預覽框（網址列＋頁面截圖，標出 agent 游標）、接管／歸還按鈕、分頁數、錄影狀態、操作紀錄。
- 空狀態（c-empty）：置中標題＋一句說明，不放插圖。

## 待處理與通知

### ActivitySheet
- 底部面板：標題「待處理與動態」；「待你處理」區（依到期）；「最近動態」時間序列表（時間、狀態點、標題、副標）；底部說明「看過不等於處理完」。

### ConfirmSheet
- 從通知或卡片進入：來源說明列（`surface.subtle`，綠點＋「已重新確認…」）、內容、雙按鈕（次要＋primary）。
- 變體：回答問題（預選答案）、執行錯過的排程、已被處理（只有「好」）、無法確認（只有「重試」）。

### QuickReplyWindow（c-pop）
- App 繪製的底部浮窗：左右 10、圓角 26、`surface.layer`、較重陰影。
- 頭部：π、來源、開啟完整對話、關閉；內容：到期、問題、選項；雙按鈕；底部控制權說明。
- 狀態：確認中、可回答、已送出、已被處理。

### AndroidNotification（系統繪製，僅內容規格）
- 收合、展開（最多 3 選項）、錯過排程、即時進度、完成／失敗、已處理、過期、鎖定畫面公開版本。見通知元件板。

## 共用

- Button（c-btn）：44 高、全圓；變體 default（`fill.hover`）、primary（accent）、dark（`action.primary`）、ghost（`line.default` 內框）、danger（`status.dangerSoft`）、small（36）。
- IconButton（c-ib）：44 圓形，圖示 22、線寬 1.75。
- Switch（c-switch）：52×32；開啟 accent。
- Segmented（c-seg）：同 ModeSwitch 外觀。
- Toast（c-toast）：`text.primary` 底、`surface.page` 字，底部 120 上方。
- LoadingOverlay（c-loading）：整頁；「正在重新連線並取得最新狀態…」＋說明「確認之前不顯示可操作的按鈕」。
- ProposalTag（tag-new）：**只用於設計稿**，標示提案能力；實作時移除。
