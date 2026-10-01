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

OpenAI／Claude 會讀取全部分頁；查詢起點會持久保存，不因某筆額度用完或刪除而改變。升級至 1.6.0 時會重新建立一次完整帳務基準，保留既有餘額，避免把舊版漏讀的歷史費用重複扣款。建議升級後將目前餘額與官方帳務頁對齊一次。更換帳號金鑰或 Gemini 表名，也會重新建立基準。平台下修累計花費時不自動退款；累計超過之前已計算的金額後才繼續扣款。

金鑰只代表 API 組織帳務，不代表 ChatGPT／Claude 聊天訂閱的訊息配額。到期天數依自行設定的日期計算，每分鐘更新畫面，不依賴 API 成功與否。

### ElevenLabs credits

1. 在 ElevenLabs 建立可讀取使用者資料的 API Key（限制權限時啟用 User: Read）。
2. 到 App「設定 → ElevenLabs credits」貼上金鑰，按「儲存並測試 ElevenLabs」。
3. App 自動建立方案額度；之後更新同一筆紀錄，跨期時套用新的總額度、剩餘量與重設時間。

剩餘 credits = `max(0, character_limit - character_count)`。重設時間取自 `next_character_count_reset_unix`，是方案重設時間；若 API 沒提供就顯示「未提供重設時間」。用完的方案仍會顯示，方便查看重設狀態。方案額度由 API 管理；手動新增的 ElevenLabs 額度保持獨立。刪除或封存自動方案後，下次同步會重新建立；清除金鑰可停止同步，並保留最後一次紀錄。

### Gemini Google Cloud Billing

1. 在 Google Cloud Billing 啟用 Standard usage cost 的 BigQuery export。
2. 建立 Service Account，授予執行專案 `BigQuery Job User`，並在 export dataset 授予 `BigQuery Data Viewer`。
3. 建立並下載該 Service Account 的 JSON key。
4. 在 AI Credits 設定頁輸入完整表名（`project.dataset.gcp_billing_export_v1_...`）並匯入 JSON。

App 每 6 小時查詢 Gemini／Generative Language API 的 gross cost，依到期日優先扣除同幣別額度。BigQuery export 資料可能延遲。

## 本機資料與排錯

一般資料儲存在 `~/Library/Application Support/AICredits/credits.json`；API Key 與 Service Account JSON 僅存於 macOS Keychain，不寫入專案或 Git。

- 設定頁會分別顯示平台的連線狀態、錯誤原因與成功時間；每筆額度顯示最後更新時間。同步失敗會保留既有數字。
- 若 Keychain 無法讀取，App 會提示解鎖登入鑰匙圈並按「立即同步」授權；背景同步不彈出授權視窗。
- OpenAI／Claude 需使用 Admin API Key。401／403 請確認金鑰與權限；503 為伺服器回應，重試後仍失敗時可稍後再同步。
- 所有測試使用模擬 HTTP 回應與記憶體金鑰，不使用真實 API Key，不呼叫正式帳務服務。

官方 API 文件：[OpenAI 帳務 API](https://platform.openai.com/docs/api-reference/usage/costs)、[Claude Cost Report](https://platform.claude.com/docs/en/api/http/beta/organization/cost_report/retrieve)、[ElevenLabs Subscription](https://elevenlabs.io/docs/api-reference/user/subscription/get)。
