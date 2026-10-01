# AI Credits

原生 macOS 14+ 選單列 App，追蹤 OpenAI、Claude、Gemini、ElevenLabs、Lovable 與 Notion 的剩餘額度、到期日及方案重設時間。

## 開發與封裝

需要 Xcode / Command Line Tools 與 Swift 6：

```bash
swift test
./Scripts/setup-signing.sh # 這台 Mac 首次封裝時執行一次
./Scripts/build-app.sh
open "dist/AI Credits.app"
```

封裝腳本會產生 `dist/AI Credits.app`；結束舊版 App 後，將完整新版拖到「應用程式」即可日常使用。可用 Xcode 開啟 `Package.swift`。1.6.3 起使用固定的本機簽署憑證及持續重用的鑰匙圈工具；不會默默退回臨時簽署。這個簽署方式供本機使用，公開發佈應改用 Apple Developer ID 與 notarization。

### 更新後的鑰匙圈授權

- 初次升級到 1.6.3 時，原有金鑰仍保留在登入鑰匙圈。背景同步需要授權時會顯示錯誤；按「立即測試」才會讓 macOS 顯示授權視窗。請允許 `AICreditsKeychain` 存取該平台金鑰，選「永遠允許」記住授權。原有每筆金鑰可能各需授權一次。
- 金鑰工具只接受同一簽署憑證下的 AI Credits 呼叫，App 也會驗證工具簽署；金鑰透過私人管線傳送，不放入命令參數、環境變數或紀錄。背景讀取在工具程序內關閉 Keychain 互動，不影響主程式或其他 App。
- 儲存金鑰前只做不彈窗的舊值比較；儲存成功後，立即測試會使用剛輸入的值一次（最多 60 秒），後續同步仍重新讀取 Keychain。清除金鑰會一併清除待測試值。
- 本機簽署私鑰只存於登入鑰匙圈，限定 `/usr/bin/codesign` 使用。公開憑證、指紋及簽署完成的工具保存在 `~/Library/Application Support/AICredits/Signing`，不進 Git。請保留這個目錄；普通 App 更新會複製完全相同的工具，不會重新產生其身分。工具程式碼需要更新或此目錄被移除時，macOS 可能再次要求授權。
- 僅固定自簽憑證還不夠：macOS 的 file-based Keychain 也會比對執行檔的 partition。因此保留工具的原始簽署位元組，並啟用 hardened runtime。

可執行 `./Scripts/verify-signing.sh` 驗證兩個不同的已簽署 App 測試程式能沿用同一工具，在禁止授權 UI 的情況下寫入／讀取測試項目；未受信任的呼叫者必須遭拒。測試只使用 `SigningProbe` 帳號並於結束時清除，不存取 API 金鑰。

## 同步方式

| 平台 | 設定 | 同步內容 |
| --- | --- | --- |
| OpenAI | Admin API Key | 組織累計 API 花費，換算為手動額度的剩餘量 |
| Claude | Admin API Key | 組織累計 API 花費，換算為手動額度的剩餘量 |
| Gemini | Google Service Account JSON、Billing Export 表名 | Google Cloud 帳務中的 Gemini gross cost |
| ElevenLabs | 具有使用者讀取權限的 API Key | 方案總 credits、已使用量、剩餘量及下次重設時間 |
| Lovable、Notion | 不需金鑰 | 手動更新 |

App 啟動即同步；OpenAI、Claude、ElevenLabs 每 15 分鐘更新，Gemini 每 6 小時查詢一次。Mac 喚醒或開啟選單／設定時，也會檢查是否需要更新。按「立即同步」可略過更新間隔。網路中斷、429 或伺服器暫時錯誤最多嘗試 3 次；無效金鑰／權限錯誤會顯示原因。

### OpenAI／Claude／Gemini 的額度與到期日

這裡使用的帳務 API 回傳「花費」，並非贈送 credits 的餘額與到期日。請先新增額度、幣別及到期日。單筆完整額度可開啟「以原始額度自動計算餘額」，每次同步都用原始額度減去取得日起的 API 累計花費；例如 5,000 − 4,428 = 572 USD。平台帳務可能有延遲，畫面上的剩餘量為估算值。

1.6.2 起，額度卡片標示「預估剩餘」，同步結果分開顯示 API 累計花費、花費期間、本次實際扣除與帳面剩餘。新花費不會再扣到已過期的額度。

1.6.4 起，原始額度自動計算會持續生效：啟動時先以已儲存的花費重算，成功同步後套用最新花費，編輯原始額度也立即重算。主畫面會列出計算式，重複刷新不會重複扣款；API 下修花費時也會修正餘額，花費超過原始額度則剩餘為 0。這需要平台同幣別只有一筆額度、取得日等於花費查詢起點，且原始額度涵蓋全部花費。修改取得日後需重新同步；多筆額度或期間不符時會顯示計算錯誤並保留餘額。

既有手動餘額可在「設定／API 狀態 → 校正餘額並啟用自動計算」預覽。例如原始 5,000 USD、API 累計 4,425.81 USD，會校正為約 574.19 USD，並持續自動計算。若原始數字本身是已扣除花費的餘額，或有多筆不同期間的贈送額度，請使用手動餘額模式，依官方帳務頁輸入目前餘額。手動模式首次同步保留輸入的餘額，之後按到期日順序扣除同幣別的新增花費。

OpenAI／Claude 會讀取全部分頁。原始額度自動計算從取得日查詢；手動模式的查詢起點會持久保存，不因額度用完或刪除而改變。手動模式更換帳號金鑰或 Gemini 表名後會重新建立基準，且平台下修累計花費時保留先前較高的扣款基準，避免之後重複扣款。

金鑰只代表 API 組織帳務，不代表 ChatGPT／Claude 聊天訂閱的訊息配額。到期天數依自行設定的日期計算，每分鐘更新畫面，不依賴 API 成功與否。

### ElevenLabs credits

1. 在 ElevenLabs 建立可讀取使用者資料的 API Key，在 Developers → API Keys 的權限中將 User 設為 Read（`user_read`）；不需要 Text to Speech、Voices 或寫入權限。
2. 到 App「設定 → ElevenLabs credits」貼上金鑰，按「儲存並測試 ElevenLabs」。
3. App 自動建立方案額度；之後更新同一筆紀錄，跨期時套用新的總額度、剩餘量與重設時間。

剩餘 credits = `max(0, character_limit - character_count)`。重設時間取自 `next_character_count_reset_unix`，是方案重設時間；若 API 沒提供就顯示「未提供重設時間」。用完的方案仍會顯示，方便查看重設狀態。方案額度由 API 管理；手動新增的 ElevenLabs 額度保持獨立。刪除或封存自動方案後，下次同步會重新建立；清除金鑰可停止同步，並保留最後一次紀錄。

### Gemini Google Cloud Billing

1. 在 Google Cloud Billing 啟用 Standard usage cost 的 BigQuery export。
2. 建立 Service Account，授予執行專案 `BigQuery Job User`，並在 export dataset 授予 `BigQuery Data Viewer`。
3. 建立並下載該 Service Account 的 JSON key。
4. 在 AI Credits 設定頁輸入完整表名（`project.dataset.gcp_billing_export_v1_...`）並匯入 JSON。

App 每 6 小時查詢 Gemini／Generative Language API 的 gross cost，依到期日優先扣除同幣別額度。BigQuery export 資料可能延遲。

## 怎麼確認有沒有呼叫 API

使用 **1.6.1 或更新版本**，點選選單列 App → **查看紀錄**（也可從設定或管理視窗開啟「API 狀態與紀錄」）：

- 各平台分別顯示尚未測試、未設定、同步中、成功或失敗。
- 「最近嘗試」與「最近成功」分開記錄；失敗不會更新成功時間。
- 「本次已發起 N 次 HTTP 請求」會計入分頁、重試及 Gemini 的 Google 登入。缺少金鑰、Keychain 無法讀取或設定不完整時會顯示沒有發起請求。
- 每次請求會記錄時間、平台、API 路徑、HTTP 回應碼與重試；HTTP 200 但資料解析失敗仍標示失敗。
- 最近 120 筆紀錄保存在本機，重啟後仍可查看。紀錄不包含請求標頭、本文、查詢參數或金鑰；伺服器錯誤中的憑證會遮蔽。
- ElevenLabs 回傳 `missing_permissions`／`user_read` 時，會直接提示開啟 **User → Read**。若有 IP 白名單，請確認目前網路的 IP 已被允許。
- Lovable、Notion 會明確標示手動管理，不會呼叫 API。

請確認選單上的版本號。專案 `dist` 中的新版不會自動替換 `/Applications/AI Credits.app`；退出舊版，將新版拖到「應用程式」替換後重新開啟。

## 本機資料與排錯

一般資料儲存在 `~/Library/Application Support/AICredits/credits.json`；API Key 與 Service Account JSON 僅存於 macOS Keychain，不寫入專案或 Git。

- 設定頁會分別顯示平台的連線狀態、錯誤原因與成功時間；每筆額度顯示最後更新時間。同步失敗會保留既有數字。
- 若 Keychain 無法讀取，App 會提示解鎖登入鑰匙圈並按「立即同步」授權；背景同步不彈出授權視窗。
- OpenAI／Claude 需使用 Admin API Key。401／403 請確認金鑰與權限；503 為伺服器回應，重試後仍失敗時可稍後再同步。
- 所有測試使用模擬 HTTP 回應與記憶體金鑰，不使用真實 API Key，不呼叫正式帳務服務。

官方 API 文件：[OpenAI 帳務 API](https://platform.openai.com/docs/api-reference/usage/costs)、[Claude Cost Report](https://platform.claude.com/docs/en/api/http/beta/organization/cost_report/retrieve)、[ElevenLabs Subscription](https://elevenlabs.io/docs/api-reference/user/subscription/get)。
