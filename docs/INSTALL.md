# 安裝與更新

[回到首頁](../README.md)

## 系統需求

- 執行 App：macOS 14 或更新版本。
- 編譯 App：Swift 6 或更新版本，以及相容的 Xcode／Command Line Tools。
- Git（Apple Command Line Tools 也提供 Git）。

目前採用在自己 Mac 編譯、本機簽署的方式，尚未提供 Apple Developer ID 簽署與公證的安裝包。編譯產物對應這台 Mac 的架構，不是 universal 安裝包。最低執行版本不代表所有 macOS 14 小版本都能安裝 Swift 6 工具鏈，請依 [Apple 的 Xcode 相容表](https://developer.apple.com/xcode/system-requirements)選擇工具版本。

## 1. 安裝開發工具

在「終端機」執行：

```bash
xcode-select --install
```

完成系統安裝流程後，再確認：

```bash
swift --version
git --version
```

Swift 必須是 6 以上。若已安裝完整 Xcode，可先開啟一次完成必要元件安裝，再於 Xcode → Settings → Locations 選擇對應的 Command Line Tools。

## 2. 下載與安裝

```bash
git clone https://github.com/Wolke/ai-credits.git
cd ai-credits
./Scripts/install.sh
```

安裝腳本會：

1. 檢查 macOS、Swift 版本與目的地。
2. 建立或沿用這台 Mac 的本機程式碼簽署憑證。
3. 以 release 模式編譯，產生並驗證已簽署的 App。
4. 首次預設安裝到 `~/Applications/AI Credits.app`；若 `/Applications/AI Credits.app` 已存在則更新該位置。
5. 更新時先備份舊版 App 與現有 `credits.json`，保留 Keychain 金鑰，完成後開啟新版。

首次簽署時，macOS 可能要求允許 `codesign` 使用本機簽署私鑰。只有在系統視窗輸入自己的登入密碼；App 不會收集這個密碼。安裝不需要 Apple Developer 付費帳號，也不需要 `sudo`。

可指定安裝資料夾，或安裝後暫不開啟：

```bash
./Scripts/install.sh --destination "$HOME/Applications" --no-open
```

如果原本安裝在另一個位置，請更新原位置，避免同時保留多個版本。腳本只會替換 bundle ID 相符的 AI Credits，不會覆蓋同名的其他 App。

## 3. 開啟並設定

這是選單列 App，通常不會出現在 Dock。找到 macOS 右上角的信用卡圖示，點一下即可查看。

- 按「新增額度」輸入自己的額度與日期。
- 按「設定」輸入需要的 API 金鑰，再按對應平台「儲存並測試」。
- ElevenLabs 成功同步後自動建立方案額度，不需要另加一筆。
- 「查看紀錄」可確認 HTTP 次數、最近嘗試／成功時間及錯誤訊息。

請依[平台設定指南](PROVIDERS.md)選擇正確的金鑰權限與餘額模式。

## 更新

先點選選單中的「退出 AI Credits」，再回到當初下載的 `ai-credits` 資料夾：

```bash
git pull --ff-only
./Scripts/install.sh
```

若目的地的 App 仍在執行，腳本會請你退出後重試。若 `git pull` 提示本機修改衝突，請先保存自己的改動，不要直接刪掉它們。

安裝腳本會將備份放在 `~/Library/Application Support/AICredits/Backups/install-…`，並印出完整路徑。備份可能包含私人帳務，請留在自己的電腦。App 本身不會自動下載更新。

## 為什麼 macOS 要求密碼／Keychain 授權？

金鑰儲存在 macOS Keychain。首次使用、從舊的簽署方式升級，或金鑰工具／簽署身分變更時，macOS 可能要求對各平台金鑰授權。

在 App「設定」按「立即測試」，確認視窗要求的是 `AICreditsKeychain` 存取對應平台的金鑰，再依需要選擇「永遠允許」。背景同步會直接回報 Keychain 錯誤，不會反覆跳出密碼視窗。

一般更新會沿用固定憑證及同一份已簽署工具，減少重複授權。請保留：

```text
~/Library/Application Support/AICredits/Signing
```

私鑰位於登入鑰匙圈，Signing 資料夾保存公開憑證、指紋及工具快取。如果憑證或私鑰不見，安裝會停止並提示恢復原簽署身分，不會默默換新身分。這個做法不能保證 macOS 在所有系統／安全設定變更後都不再詢問。

## 常見問題

| 狀況 | 處理方式 |
| --- | --- |
| 開啟後沒有視窗 | 到右上角選單列找信用卡圖示；這是選單列 App。 |
| 安裝後仍顯示舊版本 | 完全退出舊版，再開啟安裝腳本印出的路徑；檢查是否有兩份 App。 |
| HTTP 請求次數是 0 | 尚未進入網路請求；檢查金鑰、Keychain 授權、Gemini 設定與完整錯誤原因。 |
| HTTP 401／403 | 檢查組織、金鑰種類與權限；ElevenLabs 需 User → Read。 |
| 成功但餘額和官方不同 | 比對原始額度／目前剩餘模式、起算日、是否有多筆額度與已過期額度，見[計算規則](PROVIDERS.md)。 |
| 缺少通知 | 在 macOS 系統設定允許 AI Credits 通知，並保持 App 執行。 |
| 簽署工具無法使用 | 確認登入鑰匙圈已解鎖、原本的本機簽署憑證與私鑰仍在。 |

若 macOS 封鎖開啟，先確認執行的是自己從可信原始碼編譯的 App，再查看系統設定 → 隱私權與安全性所列原因。請勿關閉整台 Mac 的 Gatekeeper 來排錯。

## 登入時自動開啟

App 尚無內建登入啟動開關。可在 macOS 系統設定的「登入項目」加入已安裝的 AI Credits。

## 移除或保留資料

1. 從選單退出 AI Credits，並從登入項目移除（若有加入）。
2. 把安裝位置的 `AI Credits.app` 移至垃圾桶。

移除 App 不會自動刪除額度、備份或金鑰，方便重新安裝。若要清除金鑰，可在移除 App 前從設定逐一清除；也可用「鑰匙圈存取」檢查並刪除服務名稱為 `com.local.AICredits.credentials.v2` 的項目。早期版本的 Keychain 項目若仍存在，也需自行檢查，見[隱私說明](PRIVACY.md)。

確定不再需要資料與本機簽署身分後，再自行移除 `~/Library/Application Support/AICredits`，並在「鑰匙圈存取」移除 `AI Credits Local Signing` 憑證及相應私鑰。清除前可保留自己的備份；刪除簽署資料會讓未來安裝需要重新授權。
