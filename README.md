# TapSay

按一下快捷鍵、說話、再按一下 —— 幾秒後整理好的台灣繁體中文直接出現在游標位置。

```
Hotkey → 錄音 → STT → LLM 整理 → 剪貼簿 → 自動貼上
```

常駐背景，只有一個 menu bar / tray 圖示，沒有主視窗。

> **iPhone / iPad / 原生 macOS 版**在 [`apple/`](apple/README.md)：SwiftUI 重寫，
> 一樣可以自由設定 Endpoint 與模型，iOS 上以「TapSay 鍵盤」在任何 App 裡輸入。
> 本頁說明的是 Python 版（macOS + Windows）。

## 下載

[**Releases**](../../releases/latest) 有打包好的版本，不需要裝 Python：

| 平台 | 檔案 | 第一次打開 |
|---|---|---|
| macOS (Apple Silicon) | `TapSay-macOS-arm64.zip` | 解壓縮 → 拖進「應用程式」→ 右鍵「打開」 |
| Windows (x64) | `TapSay-Windows-x64.zip` | 解壓縮 → 執行 `TapSay.exe` → SmartScreen 選「仍要執行」 |

兩邊都沒有付費簽章，所以第一次要手動放行一次，之後正常。macOS 還要到
「系統設定 → 隱私權與安全性」開**麥克風**與**輔助使用**給 TapSay。

## 從原始碼執行

需要 Python 3.14（`uv` 會自動處理）。

```bash
uv sync
uv run tapsay            # 常駐執行，出現 menu bar / tray 圖示
uv run tapsay --settings # 只開設定視窗
uv run tapsay --no-tray  # 不顯示圖示，只註冊快捷鍵（除錯用）
```

第一次執行請先開設定視窗填 STT / LLM 的 Endpoint、API Key、Model。

## 使用

1. 游標停在任何可輸入文字的地方
2. 按 `Ctrl+Alt+Space`（預設）→ menu bar 圖示變**紅色**，開始錄音
3. 說話
4. 再按一次 `Ctrl+Alt+Space` → 圖示變**黃色**，處理中
5. 圖示變**綠色**→ 文字已寫入剪貼簿並自動貼到游標位置

失敗時會跳一則系統通知，而且**文字一定已經在剪貼簿裡**，可以自己 `Cmd+V` / `Ctrl+V`。

圖示顏色：灰＝待命、紅＝錄音、黃＝處理中、綠＝完成、紅＝錯誤。

## 設定

Menu bar 圖示 →「設定…」，或 `uv run tapsay --settings`。

| 項目 | 說明 |
|---|---|
| 全域快捷鍵 | 組合鍵 `<ctrl>+<alt>+<space>`，或**連擊兩下** `double:<ctrl>` |
| STT Endpoint / Key / Model | OpenAI 相容的 `/audio/transcriptions` |
| LLM Endpoint / Key / Model | OpenAI 相容的 `/chat/completions` |
| LLM Prompt | 可自由編輯，預設是「整理成台灣繁體中文」 |
| 公司 CA 憑證 | 額外信任一份 PEM，見下方「受限網路」 |
| 關閉 TLS 憑證驗證 | 最後手段，見下方「受限網路」 |

**連擊快捷鍵**：`double:<ctrl>` 代表快速連按兩下 Ctrl（也可用 `cmd` / `alt` / `shift`）。
判定刻意保守，避免誤觸——兩次按下之間夾了別的鍵（像 Ctrl+C）不算，程式自己送出的按鍵
（例如自動貼上的 Ctrl+V）也不算，兩下之間最長 400 毫秒（要調就改 `config.toml` 的 `double_tap_ms`）。
連擊的好處是不會和任何既有快捷鍵衝突；代價是修飾鍵本身的原本功能不受影響，但如果你習慣
用單按 Ctrl 做輸入法切換之類的事，建議改用 `double:<alt>`。

API Key 欄位開啟時一律是空的，**留白代表沿用已儲存的金鑰**，只有真的輸入新值才會覆寫。
（設定視窗因此完全不讀 Keychain，才不會一點「設定」就先跳出要求鑰匙圈密碼的對話框。）

「測試連線 / 取得模型」會打 `GET {endpoint}/models`：成功就把模型填進下拉選單，
Endpoint 不支援模型清單時，Model 欄位照樣可以直接手動輸入。

### 受限網路（憑證驗證失敗）

公司的 MITM proxy、或內部 endpoint 用自簽憑證時，連線會失敗並顯示
「憑證驗證失敗：self-signed certificate …」。兩種解法，**優先用第一種**：

**1. 信任公司 CA（安全）**

設定視窗 →「公司 CA 憑證」→「瀏覽…」選一份 PEM 檔即可。這是**加上去**不是取代：
系統原有的信任清單照樣有效，公開網站的驗證不受影響，公司 CA 只是多被信任一張。
存檔時會先試載一次，路徑錯或檔案不是憑證會當場報錯。

憑證從哪來（IT 通常已經裝進系統）：

```bash
# macOS：列出系統鑰匙圈裡的憑證，再依名稱匯出
security find-certificate -a -Z /Library/Keychains/System.keychain | grep "alis"
security find-certificate -a -c "公司 CA 名稱" -p /Library/Keychains/System.keychain > ~/corp-ca.pem
```

```cmd
:: Windows：找到後匯出並轉成 PEM
certutil -store Root
certutil -store Root <序號> corp-ca.cer
certutil -encode corp-ca.cer corp-ca.pem
```

找不到就直接從 proxy 撈，並請 IT 核對指紋：

```bash
openssl s_client -showcerts -connect api.openai.com:443 </dev/null 2>/dev/null | \
  openssl x509 -outform PEM > ~/corp-ca.pem
openssl x509 -in ~/corp-ca.pem -noout -subject -issuer -fingerprint -sha256
```

對應 `config.toml` 的 `ca_bundle = "/path/to/corp-ca.pem"`；也可以用環境變數
`TAPSAY_CA_BUNDLE=/path/to/corp-ca.pem`（優先於設定檔）。要沿用系統原生機制的話，
`SSL_CERT_FILE` 一樣有效，但那是**取代**整份信任清單，得自己把系統的
`/private/etc/ssl/cert.pem` 跟公司 CA 串成一份。

**2. 關掉驗證（不安全，最後手段）**

CA 憑證真的拿不到時，設定視窗勾「關閉 TLS 憑證驗證」，或不改設定檔跑一次：

```bash
TAPSAY_INSECURE_SSL=1 uv run tapsay
```

等於接受任何憑證，連線內容（含語音、API Key）可被中間人看到。對應 `config.toml` 的
`insecure_ssl = true`；勾了會蓋過 CA 憑證設定，環境變數優先於設定檔。

Endpoint 填 base URL（例如 `https://api.openai.com/v1`），程式自己接 `/audio/transcriptions`、
`/chat/completions`、`/models`；填完整網址也可以。本機 LiteLLM proxy 就填 `http://localhost:4000/v1`。

**設定檔位置**

- macOS：`~/Library/Application Support/TapSay/config.toml`
- Windows：`%APPDATA%\TapSay\config.toml`

API Key **不寫進 config.toml**，存在 macOS Keychain / Windows 認證管理員（service 名稱 `tapsay`）。

## 系統權限

**macOS**（權限是掛在「啟動它的那個程式」上，所以固定用同一個終端機 / 同一種啟動方式）

- 系統設定 → 隱私權與安全性 → **麥克風**
- 系統設定 → 隱私權與安全性 → **輔助使用**（全域快捷鍵與自動貼上都需要）

權限是綁在「執行中的那個程式」上：用打包版就給 **TapSay.app**，用原始碼跑就給**你的終端機**。
注意從終端機用指令啟動 `.app` 時它會繼承終端機的權限，所以那樣測「看起來正常」不代表
使用者雙擊打開也正常——要驗請用 Finder 雙擊或 `open TapSay.app`。
- 第一次跳通知權限時允許（通知走 osascript）

**Windows**

- 不需要特別權限；防毒軟體偶爾會對鍵盤 hook 有意見
- 想避免黑色主控台視窗，用 `pythonw.exe -m tapsay` 啟動

## 技術選型

| 需求 | 選擇 | 理由 |
|---|---|---|
| 全域快捷鍵 + 自動貼上 | `pynput` | 一個套件同時解決兩件事，Win/mac 都支援；`GlobalHotKeys` 會忽略程式合成的按鍵，所以自動貼上的 Cmd+V 不會誤觸自己 |
| 錄音 | `sounddevice` | PortAudio 綁定，wheel 自帶二進位；用 `RawInputStream` 直接拿 int16 bytes，**不需要 numpy** |
| Tray / Menu Bar | `pystray` | 跨平台、純 Python；同時提供原生通知（macOS 走 osascript、Windows 走 balloon） |
| 剪貼簿 | `pyperclip` | 極小，Win/mac 原生實作，中文沒問題 |
| API Key | `keyring` | 直接接 macOS Keychain / Windows Credential Manager |
| HTTP | **標準函式庫 `urllib`** | 只需要一個 multipart 上傳和一個 JSON POST，實測 TLS 正常，不值得為此加 `requests` |
| 設定檔 | `tomllib`（讀，內建）+ `tomli-w`（寫） | 需求指定 TOML；tomli-w 沒有其他相依 |
| 設定 GUI | `tkinter` | Python 內建，設定畫面夠用 |
| 音訊暫存 | `io.BytesIO` + `wave`（內建） | 錄音只存在記憶體，送出後即消失，不落地 |

執行期相依只有 7 個直接套件（macOS 上 pynput 會帶 pyobjc）。

**兩個關鍵設計決定**

1. **設定視窗用獨立子行程開**（`python -m tapsay.ui`）。macOS 的 menu bar（NSApplication）和
   tkinter 都要求主執行緒，硬塞在同一個行程裡會打架；開子行程只花 0.3 秒，關掉後主程式重讀設定。
2. **剪貼簿是保底**。永遠先寫剪貼簿再送 Cmd+V，自動貼上失敗只是少了一步，結果不會遺失。

## 已在 macOS 實測通過

- 完整 E2E（錄音 → STT → LLM → 剪貼簿 → 自動貼進 TextEdit），處理約 4.6 秒（其中 LLM 佔大部分）
- STT 輸出簡體 `今天天气不错。那个，...` → LLM 整理成 `今天天氣不錯。我們等一下開會討論專案進度。`
- 錯誤路徑：連線被拒、HTTP 401/403、Model 沒設、沒錄到聲音 —— 都只跳通知並回到待命，不會讓程式掛掉
- Menu bar 圖示與狀態換色、設定視窗、設定檔 TOML round-trip

尚未在 Windows 上實機驗證（沒有 Windows 環境）；所有相依套件都有官方 Windows 支援。

## 打包成 .app / .exe

```bash
uv sync
uv run pyinstaller tapsay.spec --noconfirm
```

- macOS → `dist/TapSay.app`（實測 48 MB，建置約 10 秒，menu bar 圖示正常）
- Windows → `dist/TapSay/TapSay.exe`（`console=False`，不會有黑色主控台視窗）

`tapsay.spec` 裡兩個平台共用一份設定，重點只有三處：

- `LSUIElement: True` —— 只待在 menu bar，不佔 Dock
- `NSMicrophoneUsageDescription` —— **沒有這行 macOS 會直接不給麥克風**
- `hiddenimports` —— `pystray` 與 `keyring` 的後端是動態載入的，不寫會在執行期才炸

### 自己在本機打包時要簽章

憑證在 `~/.tapsay-signing/tapsay-signing.p12`，密碼存在 Keychain（service `tapsay-signing`）：

```bash
KC=~/Library/Keychains/login.keychain-db
security import ~/.tapsay-signing/tapsay-signing.p12 -k $KC \
  -P "$(security find-generic-password -s tapsay-signing -a p12 -w)" -T /usr/bin/codesign   # 只需做一次
codesign --force --deep --sign "TapSay Self Signed" dist/TapSay.app
codesign -d -r- dist/TapSay.app        # 確認 certificate root 的雜湊沒變
```

不簽也能跑，只是會退回 ad-hoc，系統權限就會跟舊版一樣每次重來。

> 之後若要重新產生憑證，`openssl pkcs12 -export` **一定要加 `-legacy`**。OpenSSL 3 預設用
> PBES2/AES-256，macOS 的 `security import` 讀不了，只會回一句誤導人的
> `MAC verification failed (wrong password?)`。

## 發佈到 GitHub Release

`.github/workflows/release.yml` 已經備好：推一個 tag 就自動在 macOS 與 Windows runner 上各打一包，
建立 Release 並附上兩個 zip。

```bash
git tag v0.1.0 && git push origin v0.1.0
```

macOS 的 zip 用 `ditto` 壓（`zip` 會破壞 .app 的簽章與符號連結）。

簽章需要兩個 repo secret，缺了就自動跳過簽章（fork 的 PR 也能建置）：

| Secret | 內容 |
|---|---|
| `MACOS_CERT_P12` | `base64 -i tapsay-signing.p12` 的輸出 |
| `MACOS_CERT_PASSWORD` | p12 的密碼 |

## 給下載的人：第一次打開

兩邊都是**沒有付費簽章**的程式，系統會擋一次：

- **macOS**：右鍵 →「打開」→「打開」，或 `xattr -dr com.apple.quarantine /Applications/TapSay.app`
- **Windows**：SmartScreen →「其他資訊」→「仍要執行」

**v0.1.4 起改用固定的自簽憑證簽章**，所以「輔助使用」與 Keychain 授權**只要給一次，之後更新都不會失效**
（macOS 依 designated requirement 辨識 app，綁憑證之後每版都一樣）。Gatekeeper 仍然會擋，
因為自簽憑證不等於公證；要連這個一起免掉就得走付費路線：

- macOS：Apple Developer Program（US$99/年）→ `codesign --sign "Developer ID Application: ..."` → `xcrun notarytool submit`
- Windows：買一張程式碼簽章憑證（OV 一年約 US$200 起，EV 才能立刻免除 SmartScreen）

## 打包版的兩個 macOS 注意事項

1. **權限是綁在簽章上的。** CI 用一張固定的自簽憑證簽章（憑證存在 GitHub secret），
   因此 designated requirement 每版都相同，授權給過一次就一直有效：

   ```
   designated => identifier "io.github.tapsay" and certificate root = H"15d5c2ad…"
   ```

   PyInstaller 預設的 ad-hoc 簽章則是綁 cdhash，每次打包都不一樣，那才是 v0.1.3 以前
   每次更新都要重新授權的原因。
2. 打包後 `sys.executable` 就是 TapSay 自己，不是 python，所以設定視窗改用
   `TapSay --settings` 開子行程（`tray.py:46`）；跑原始碼時仍走 `python -m tapsay.ui`。

## 專案結構

```
src/tapsay/
├── __init__.py   進入點與命令列參數
├── app.py        狀態機與主流程
├── recorder.py   麥克風 → WAV bytes
├── api.py        STT / LLM HTTP（urllib）
├── paste.py      剪貼簿與自動貼上
├── hotkey.py     全域快捷鍵
├── notify.py     系統通知
├── tray.py       menu bar / tray 圖示
├── ui.py         設定視窗（tkinter）
└── config.py     config.toml + keyring
```

## 疑難排解

**打包版點「設定」沒反應** —— v0.1.0 的 macOS 版有這個 bug（CI 用到不含 tkinter 的 Homebrew Python，
設定視窗一開就死在 `tk.Tk()`，而且 `console=False` 讓錯誤無處可見）。v0.1.1 已修：CI 改用 uv 自己的
CPython、打包時直接 `import tkinter` 驗證、產物再檢查一次 `_tkinter` 是否存在，子行程失敗也會跳通知。

**權限給了卻還是不生效？先確認 app 沒有被「搬移執行」（App Translocation）** ——
從瀏覽器下載的 zip 帶有隔離屬性，如果直接在「下載項目」裡雙擊解壓後的 TapSay.app，
macOS 會把它複製到 `/private/var/folders/…/AppTranslocation/…` 這種隨機唯讀路徑執行，
授權就綁不住。所以**一定要先把 TapSay.app 拖進「應用程式」資料夾再打開**，或先解除隔離：

```bash
xattr -dr com.apple.quarantine /Applications/TapSay.app
```

確認方法：`pgrep -fl TapSay`，路徑若出現 `AppTranslocation` 就是中了。

**快捷鍵沒反應（macOS）** —— pynput 在沒有「輔助使用」權限時**不會報錯**，只是永遠收不到按鍵。
v0.1.2 起 TapSay 啟動時會自己檢查，沒權限就跳通知並直接開啟設定頁，你勾選後它會自動恢復，
不必重開程式；menu bar 選單也多了一項「輔助使用權限…」可隨時叫出來。

**陷阱：清單裡的 TapSay 開關是開的，但權限其實是無效的** —— 這是 v0.1.3 以前的老問題
（ad-hoc 簽章每次改版都變，macOS 把新版當成另一個 app，於是那個亮著的開關對新版完全不算數）。
**v0.1.4 起改用固定憑證已經根治**，但從舊版升上來的這一次仍需要重給一次：

```bash
tccutil reset Accessibility io.github.tapsay
```

然後重新開啟 TapSay，照提示授權一次。也可以在設定清單裡選 TapSay 按「−」移除再重新加入。
想根治（每次更新都不用重來）就得用**固定的簽章身分**，見下方「簽章」。

**第一次錄音時跳出鑰匙圈密碼對話框** —— 正常。因為 ad-hoc 簽章的 TapSay 和當初寫入金鑰的程式
不是同一個身分，輸入登入密碼並按**「永遠允許」**一次即可。每次改版重新打包會再問一次。

## 已知限制

- 快捷鍵不會被攔截（不 suppress），按下時前景程式也會收到；請避開前景程式有作用的組合。
  macOS 的 `Cmd+Alt+Space` 是 Finder 搜尋，所以預設用 `Ctrl+Alt+Space`。
- 沒有歷史紀錄、不保存錄音、沒有 Prompt 範本管理 —— 這些是刻意不做的。
