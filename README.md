# AI Credits

原生 macOS 14+ 選單列 App，追蹤 OpenAI、Claude、Gemini、ElevenLabs、Lovable 與 Notion 的剩餘額度、到期日及方案重設時間。

## 開發與封裝

需要 Xcode / Command Line Tools 與 Swift 6：

```bash
swift test
./Scripts/build-app.sh
open "dist/AI Credits.app"
```

封裝腳本會產生並臨時簽署 `dist/AI Credits.app`；結束舊版 App 後，將新版拖到「應用程式」即可日常使用。可用 Xcode 開啟 `Package.swift`。更新時請使用封裝腳本，維持相同的 App 識別碼與 Keychain 存取身分。

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

這裡使用的帳務 API 回傳「花費」，並非贈送 credits 的餘額與到期日。請先新增目前剩餘額度、幣別及到期日。首次成功同步保留輸入的餘額並建立花費基準；之後依新增花費、按到期日順序扣除同幣別額度。平台帳務可能有延遲，畫面上的剩餘量為估算值。

1.6.2 起，額度卡片標示「預估剩餘」，同步結果分開顯示 API 累計花費、花費期間、本次實際扣除與帳面剩餘。新花費不會再扣到已過期的額度。

若原始總額為 5,000 USD、API 累計花費為 4,425.81 USD，但帳面仍保留接近 5,000，代表歷史花費尚未對齊。當平台只有一筆同幣別額度、取得日等於花費查詢起點時，可在「設定／API 狀態 → 校正餘額」預覽，再按「以原始總額重算」，將剩餘量校正為約 574.19 USD。這只適用於原始總額涵蓋整段花費；若原始數字本身是已扣除花費的餘額，或有多筆不同期間的贈送額度，應在「管理全部」依官方帳務頁逐筆編輯。校正後保留已計入的花費基準，重複同步不會再次扣除相同花費。

OpenAI／Claude 會讀取全部分頁；查詢起點會持久保存，不因某筆額度用完或刪除而改變。升級至 1.6.0 時會重新建立一次完整帳務基準，保留既有餘額，避免把舊版漏讀的歷史費用重複扣款。建議升級後將目前餘額與官方帳務頁對齊一次。更換帳號金鑰或 Gemini 表名，也會重新建立基準。平台下修累計花費時不自動退款；累計超過之前已計算的金額後才繼續扣款。

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
