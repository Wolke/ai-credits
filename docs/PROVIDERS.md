# 平台設定與餘額計算

[回到首頁](../README.md)

## 先選對餘額模式

OpenAI、Claude、Gemini 的帳務來源提供的是**期間花費**。原始贈送額度、取得日與到期日需自行填寫；畫面上「預估剩餘」是 App 的計算結果。

| 你知道的數字 | 建議模式 | 第一次同步 |
| --- | --- | --- |
| 完整原始額度，且能涵蓋查詢期間所有花費 | 勾選「以原始額度自動計算餘額」 | 從原始額度扣掉期間累計花費 |
| 官方目前剩餘額度，歷史發放或折抵不完整 | 手動基準模式 | 保留輸入餘額，建立花費基準；之後只扣新增花費 |

如果首次同步顯示「本次扣除 0」，請確認是否使用手動基準模式。這不代表 API 沒有呼叫；請同時看 HTTP 次數與最近成功時間。

每個平台目前只保存一組金鑰／組織帳務來源。可以建立多筆贈送額度，但不能替每筆設定不同組織的金鑰。金額與花費必須是相同幣別；App 不提供外匯換算。

### OpenAI：有效原始額度合計模式

所有有效 OpenAI 額度都啟用原始額度模式時，計算方式為：

```text
預估有效剩餘 = max(0, 目前有效原始額度總額 − 對應期間 API 累計花費)
花費期間 = 最早有效額度的取得日 → 本次查詢時間
```

有效額度是已發放、未封存、未到期的額度。剩餘已為零但尚未到期的紀錄仍參與原始總額；未來額度不參與。多筆期間重疊的花費只扣一次，各筆顯示值依到期順序分攤。

例如兩筆有效原始額度為 1,000 與 500 USD，期間花費為 260 USD，合計剩餘為 1,240 USD。若另有一筆已過期額度，它不加入總額，也不替上述歷史花費抵扣。

**這是一套本機估算規則，不是官方 credit 發放或扣款明細。** 如果該期間的歷史花費曾由已過期額度抵付，本規則仍會從目前有效總額扣掉這段花費，可能低於官方餘額。這種情況適合依官方目前餘額使用手動基準模式。

編輯原始數字或重新啟動時，可用符合期間的已儲存花費重算；重複同步不會重複扣款。最早有效額度到期、封存或日期改變，導致起算日不同時，必須重新查詢花費，畫面會標示「上次餘額（待重算）」。

### Claude／Gemini：單筆原始額度模式

同平台、同幣別必須只有一筆符合條件的完整額度，取得日需與花費查詢起點一致：

```text
預估剩餘 = max(0, 原始額度 − API 累計花費)
```

例如原始 1,000 USD、期間花費 260 USD，預估剩餘為 740 USD。若有多筆不同期間額度，或原始額度並未涵蓋全部花費，請使用手動基準模式。App 遇到無法計算的條件會保留餘額並顯示原因。

### 手動基準模式

先依官方帳務頁填入「目前剩餘」。首次同步只建立累計花費基準；之後依到期順序扣除同幣別的新花費，不扣到已過期額度。API 下修累計花費時保留先前的較高扣款基準，避免之後重複扣除；手動模式不會因此退還已扣數字。

更換金鑰、帳務來源或 Gemini 表名會重建花費基準。重新設定來源時，請同步核對自己填入的目前餘額。資料延遲、退款、跨幣別、多個帳戶、折扣與官方 credit 抵付規則都可能影響估算準確度。

## OpenAI

1. 使用有組織管理權限的帳戶，依官方文件建立 **Admin API Key**。
2. App「新增額度」填入該組織的額度、取得日及到期日，選擇餘額模式。
3. 在「設定 → OpenAI」貼上 Admin API Key 並測試。

App 使用 `GET /v1/organization/costs`，讀取完整分頁與日別花費。一般專案推論用的 API Key 不等同 Admin Key。這裡查的是組織 API 帳務，不是 ChatGPT 訂閱訊息配額。[官方 Costs API](https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage/methods/costs)

## Claude

1. 在 Claude Console 所屬 API 組織建立 **Admin API Key**。
2. 新增額度，再到「設定 → Claude」貼上並測試。

App 使用 `GET /v1/organizations/cost_report` 並讀取完整分頁。請用支援此 Admin API 的組織憑證；一般 workspace 金鑰不適用。Claude 網頁訂閱及 Enterprise Analytics 是不同來源，這個 App 沒有接入它們。[官方 Usage and Cost API](https://platform.claude.com/docs/en/manage-claude/usage-cost-api)

## ElevenLabs

1. 到 ElevenLabs 的 Developers → API Keys 建立金鑰。
2. 開啟 **User → Read（`user_read`）**，不需要 Text to Speech、Voices 或寫入權限。
3. 到「設定 → ElevenLabs credits／USD」貼上金鑰，按「儲存並測試 ElevenLabs」。

成功後會自動建立方案額度：

```text
剩餘 credits = max(0, character_limit − character_count)
重設時間 = next_character_count_reset_unix（API 若有提供）
```

重設時間是方案週期資訊。API 未提供時會明確顯示未知，不猜測到期日。用完的自動方案仍會顯示，方便查看重設狀態；手動新增的 ElevenLabs 額度獨立保留。刪除／封存自動方案後，下次同步會再建立；若要停止，請清除金鑰。

需要 USD 顯示時，在「美元換算」填入自己的「基準 credits」及「對應 USD」：

```text
預估 USD = 剩餘 credits × 基準 USD ÷ 基準 credits
```

例如自行設定 100,000 credits 對應 20 USD，剩餘 65,000 credits 時顯示約 13 USD。**這只是示範比例，不是 ElevenLabs 官方價格，也不是 API 回報的美元餘額。** Grant 等方案應依自己的贈送條件填寫；沒有比例時只顯示 credits。方案價格改變需自行修改；更換或清除金鑰會清除比例。

遇到 `missing_permissions` 或 `user_read`，回到金鑰設定開啟 User → Read；若設定了 IP 白名單，也需允許目前網路。

官方文件：[Subscription API](https://elevenlabs.io/docs/api-reference/user/subscription/get)、[API Keys](https://elevenlabs.io/docs/overview/administration/workspaces/api-keys)、[Pay As You Go](https://elevenlabs.io/docs/overview/administration/pay-as-you-go)。

## Gemini／Google Cloud

這個整合使用 **Google Cloud Billing Export + BigQuery**，不能直接貼 Gemini 推論 API Key 取得餘額。

1. 啟用 Google Cloud Billing 的 **Standard usage cost** BigQuery export，等待資料匯入。
2. 建立 Service Account：在執行查詢的專案授予 `BigQuery Job User`；在帳務 export dataset 授予 `BigQuery Data Viewer`。
3. 使用 Google Cloud 產生的 Service Account JSON key。App 只接受官方 OAuth token endpoint。
4. 在 App 設定完整表名，例如 `my-project.billing.gcp_billing_export_v1_EXAMPLE`，並匯入 JSON。
5. 新增對應幣別的額度、取得日及到期日，測試同步。

App 以 JSON 的 `project_id` 執行查詢，篩選服務名稱包含 Gemini／Generative Language 或 SKU 名稱包含 Gemini 的資料，累計 `cost`。這是 **gross cost**，未套用 export 中的 credits 折抵、折扣與稅項；也不是 Google 官方贈送額度餘額。請使用單一幣別、符合自己追蹤範圍的帳務表；目前沒有逐 project 篩選介面。

BigQuery export 可能延遲，也可能缺少啟用 export 前的歷史資料。BigQuery 儲存及查詢可能產生 Google Cloud 費用，依自己的帳戶方案計算。

官方說明：[設定 Billing Export](https://cloud.google.com/billing/docs/how-to/export-data-bigquery-setup)、[BigQuery IAM 權限](https://docs.cloud.google.com/bigquery/docs/access-control)。

## Lovable／Notion

目前為手動紀錄，不會呼叫 API，也不會自動讀取網頁。可填寫平台使用的 USD、credits 或其他單位，使用後自行更新剩餘量。手動管理不需要 API Key。

## 同步、錯誤與紀錄

- OpenAI、Claude、ElevenLabs 每 15 分鐘同步；Gemini 每 6 小時查詢。Mac 喚醒、開啟選單或設定時會檢查是否需要更新，也能手動立即同步。
- HTTP 次數包含分頁、重試與 Google 取得 token 的請求；缺少金鑰或 Keychain 授權時可能是 0 次。
- 網路中斷、408、429、5xx 最多嘗試 3 次；無效金鑰或權限問題會直接回報。
- HTTP 200 但解析失敗仍顯示失敗。最近嘗試與最近成功分開保存，失敗不會假裝更新成功。
- 最近 120 筆紀錄保存在本機；包含平台、API 路徑、HTTP 狀態及錯誤摘要。提供 Issue 前請再檢查是否有私人帳務資訊。
