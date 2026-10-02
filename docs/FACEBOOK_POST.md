# Facebook 分享文案

以下可直接複製貼上。建議配圖：[示範畫面](images/menu-preview.png)（虛構資料）。

---

AI 工具越用越多，送的 credits 到底還剩多少、哪一筆快到期，每次都要打開好幾個後台查。

所以我做了一個 Mac 選單列小工具：AI Credits，現在把它開源了 🎉

點一下選單列，就能看到各平台的餘額、額度明細和到期天數，也有到期通知提醒。

目前可以：
・讀取 OpenAI、Claude 的 API 花費，估算剩餘額度
・透過 Google Cloud 帳務資料追蹤 Gemini 花費
・查看 ElevenLabs 剩餘 credits 和重設時間，也能自訂比例換算 USD
・手動管理 Lovable、Notion 額度
・查看 API 是否真的有呼叫，失敗時有錯誤紀錄可以追

資料留在自己的 Mac，API 金鑰存在 macOS Keychain。免費、MIT 開源，歡迎修改，也歡迎提 Issue 或 PR。

先說明一下：OpenAI／Claude／Gemini 的原始額度和到期日需要自己設定，畫面是依 API 花費計算的預估餘額；不是直接抓到官方贈送額度，也不是 ChatGPT／Claude 聊天訂閱的訊息配額。

目前支援 macOS 14+，需要 Swift 6 工具鏈從原始碼安裝，GitHub 已附安裝步驟與安裝腳本。

專案與安裝說明：
https://github.com/Wolke/ai-credits

如果你也常在不同 AI 平台之間切換，歡迎試用，有想追蹤的平台或使用上的問題也可以留言分享。

#AI工具 #macOS #開源 #SwiftUI #AICredits
