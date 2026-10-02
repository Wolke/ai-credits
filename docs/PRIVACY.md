# 資料與隱私

[回到首頁](../README.md)

AI Credits 是在 Mac 本機執行的工具，沒有自建後端、使用者註冊、廣告或使用情況遙測。

## 儲存位置

| 資料 | 位置 |
| --- | --- |
| 額度名稱、金額、日期、註記、花費快取與同步紀錄 | `~/Library/Application Support/AICredits/credits.json` |
| API Key、完整 Google Service Account JSON | macOS Keychain，服務名稱 `com.local.AICredits.credentials.v2` |
| Gemini 帳務表名 | App 的 UserDefaults |
| 本機簽署私鑰 | 使用者的登入鑰匙圈 |
| 公開簽署憑證、指紋與已簽署工具快取 | `~/Library/Application Support/AICredits/Signing` |
| 安裝腳本建立的舊 App 與資料備份 | `~/Library/Application Support/AICredits/Backups` |

帳務 JSON 不是另外加密的保險箱，同一使用者可直接讀取；請使用合適的 macOS 帳戶與磁碟保護。不要將它或備份資料夾加入公開 Git。

## 網路連線

依啟用的平台，App 直接連線：

- `api.openai.com`：組織花費。
- `api.anthropic.com`：組織花費。
- `api.elevenlabs.io`：使用者方案與 credits。
- `oauth2.googleapis.com`：Google OAuth token。
- `bigquery.googleapis.com`：Google Cloud 帳務查詢。

金鑰、Google 簽署 assertion 或 access token 會透過 HTTPS 傳給對應供應商，用來完成使用者啟用的查詢。Lovable 與 Notion 不會發出 API 請求。App 不會替你進行文字／語音生成或購買額度；BigQuery 查詢仍可能依 Google Cloud 計費。

## 同步紀錄

最近 120 筆事件存在本機，包含平台、請求路徑、HTTP 狀態、時間與錯誤摘要。不記錄請求標頭、本文、查詢參數或金鑰；錯誤文字中的已知憑證會遮蔽。紀錄及截圖仍可能包含帳務金額、專案名稱或供應商回傳的資訊，分享前需自行檢查。

## 金鑰存取與更新

`AICreditsKeychain` 只接受相同簽署身分的 App 呼叫；App 也會驗證工具簽署。金鑰經程序間管線傳遞，不放進命令列或環境變數。背景讀取停用 Keychain 互動，需要授權時回報錯誤，讓使用者從 App 手動測試。

安裝器會沿用本機簽署身分與工具快取。工具原始碼或身分變更時，系統仍可能再次要求授權。這是減少更新時重複提示的機制，不是 macOS 安全機制的替代品。

若曾使用自行修改的版本或不同 Keychain 服務名稱，完整移除前也請在「鑰匙圈存取」檢查相應項目。[移除說明](INSTALL.md)

## 回報問題

一般問題可開 [Issue](https://github.com/Wolke/ai-credits/issues)。憑證外洩或可被利用的安全問題請走[私下回報流程](../SECURITY.md)，不要把真實金鑰、Service Account JSON 或完整帳務檔貼到 Issue。
