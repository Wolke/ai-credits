# 開發與驗證

[回到首頁](../README.md)

## 工具與架構

Swift 6、SwiftUI、AppKit、macOS 14+。使用 Swift Package Manager，沒有外部套件依賴。可以在 Xcode 開啟 `Package.swift`。

```text
Sources/AICreditsApp/
  Models/       額度、平台合計、同步狀態與 USD 估值
  Services/     API、花費分攤、持久化、Keychain 與通知
  Views/        選單列、管理、設定及同步紀錄
Tests/          模擬 HTTP 與記憶體憑證的單元測試
Scripts/        建置、本機簽署、安裝及簽署整合測試
Resources/      App 圖示與 Info.plist
docs/           使用者與開發文件
```

## 測試與建置

```bash
swift test
swift build -c release
```

單元測試使用模擬 HTTP 回應與記憶體憑證，不讀取真實 API Key、不呼叫正式帳務服務。涵蓋花費分頁、原始額度／手動基準計算、到期邊界、同步失敗、持久化、權限錯誤與 ElevenLabs 換算。Gemini 的私鑰解析測試會在記憶體使用臨時產生的測試 key。

GitHub Actions 會在 macOS 執行測試、release 編譯、腳本語法與文件連結檢查，不需要真實憑證。CI 不會建立正式可分發的 App 安裝包。

## 封裝 App

```bash
./Scripts/setup-signing.sh
./Scripts/build-app.sh
open "dist/AI Credits.app"
```

封裝腳本會製作圖示、release 執行檔與 App bundle，然後用固定的本機憑證簽署。日常安裝／更新請使用 `./Scripts/install.sh`，不要同時執行 `dist` 與已安裝的兩份 App。

`setup-signing.sh` 建立的私鑰只存於登入鑰匙圈，限 `codesign` 使用。若有已存指紋卻找不到原私鑰，腳本會停止，避免默默換身分。`sign-app.sh` 依工具原始碼與憑證指紋快取已簽署的 `AICreditsKeychain`，普通 App 更新沿用完全相同的工具位元組。

## Keychain 整合驗證

```bash
./Scripts/verify-signing.sh
```

這是手動執行的本機整合測試，需要已有簽署身分；可能觸發 macOS 簽署授權。它驗證兩個已簽署測試 App 可沿用相同工具，以及未受信任的呼叫者遭拒。只操作 `SigningProbe` 測試帳號並清除測試項目，不讀取使用者 API 金鑰。

## 更新公開展示圖

```bash
./Scripts/render-demo.sh
```

以 App 原有 SwiftUI 選單與虛構 fixture 離線渲染 `docs/images/menu-preview.png`。示範程序使用暫存檔與空憑證儲存，不讀取使用者帳務或 Keychain，也不開啟正式 App。圖中比例不代表官方價格。

分享主圖沿用既有 App 圖示與上述示範畫面，以 AppKit 排版，不需要額外圖像套件：

```bash
./Scripts/render-share-images.sh
```

輸出 `docs/images/facebook-cover.png`（1200 × 630）與 `docs/images/social-preview.png`（1280 × 640）。兩張 PNG 均小於 1 MB。更新示範畫面後重新執行即可；連結預覽的設定方式見 [Facebook 分享文案](FACEBOOK_POST.md)。

## 發佈

在 `Resources/Info.plist` 更新顯示版本與 build number，補上 `CHANGELOG.md`，通過測試後再建立 GitHub release。不要上傳個人的 `dist`、簽署身分、帳務檔或 API 憑證。

目前文件中的安裝方式是使用者在自己的 Mac 編譯。本機簽署產物不應宣稱是已經 Apple 公證的公開安裝包；若未來提供下載，需另外實作 Developer ID 簽署、公證、目標架構及最低系統版本驗證。
