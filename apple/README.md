# TapSay for iOS / iPadOS / macOS（原生 Swift 版）

和 Python 版同樣的流程（錄音 → STT → LLM 整理 → 輸入到游標位置），改用 SwiftUI 重寫，
同一份程式碼跑在 iPhone、iPad、Mac 上。**任何 OpenAI 相容的服務都能用**：
Endpoint、API Key、Model 都自己填，STT 和 LLM 可以用不同家。

| 平台 | 怎麼用 |
|---|---|
| macOS | Menu bar 常駐。按全域快捷鍵（預設 `⌃⌥Space`）開始說話、再按一次送出，結果自動貼到游標位置 |
| iPhone / iPad | 安裝 **TapSay 鍵盤**，在任何 App 的輸入框點麥克風說話；也可以直接在 TapSay App 裡錄，結果會複製到剪貼簿 |

## 自由選擇服務

設定畫面的「套用常見服務…」可一鍵填入，填完照樣能改：

| 服務 | Endpoint | STT | LLM |
|---|---|---|---|
| OpenAI | `https://api.openai.com/v1` | ✓ | ✓ |
| Groq | `https://api.groq.com/openai/v1` | ✓（Whisper，很快） | ✓ |
| Google Gemini | `https://generativelanguage.googleapis.com/v1beta/openai` | | ✓ |
| OpenRouter | `https://openrouter.ai/api/v1` | | ✓ |
| Ollama（本機） | `http://localhost:11434/v1` | | ✓ |
| LiteLLM proxy | `http://localhost:4000/v1` | ✓ | ✓ |
| 其他 | 任何提供 `/audio/transcriptions`、`/chat/completions` 的服務 | | |

- 「測試連線 / 取得模型」會打 `GET {endpoint}/models`，成功就能從下拉選單挑模型；不支援的話直接手打 Model 名稱。
- 「用 LLM 整理文字」可以關掉，只做語音辨識，速度最快。
- LLM 和 STT 是同一家時，打開「沿用 STT 的 API Key」就不用填兩次。
- API Key 存在系統 Keychain，不會寫進設定檔。
- 公司網路有 MITM proxy 時，可以貼上公司 CA 憑證（PEM）。這是加進系統信任清單，不會取代原本的清單。最後手段才是關閉 TLS 驗證。

## iOS 鍵盤怎麼運作

iOS **不允許第三方鍵盤使用麥克風**，所以 TapSay 跟 Typeless、Wispr Flow 用的是同一種做法：

```
鍵盤點麥克風 ──(工作階段沒開)──▶ 打開 TapSay App，開麥克風並開始錄音
     │                              │  使用者點左上角「◀ 返回」回到原本的 App
     │                              ▼
     └──(工作階段已開)── start/stop ──▶ TapSay 在背景錄音 → STT → LLM
                                        │
鍵盤插入文字 ◀── App Group 共享資料 ◀──┘
```

- 工作階段開著時，畫面上方會有橘色麥克風指示燈。閒置超過設定時間（預設 5 分鐘）就自動關閉。
- 鍵盤要開「**允許完整取用**」才讀得到 App 傳來的文字。鍵盤本身不連網、也不碰 API Key。
- 結果也會同時複製到剪貼簿，所以插入失敗時可以自己貼上。

第一次設定：

1. 打開 TapSay → 設定：填 STT／LLM 的 Endpoint、API Key、Model
2. iOS 設定 → 一般 → 鍵盤 → 鍵盤 → 新增鍵盤 → **TapSay**
3. 點 TapSay → 開啟「允許完整取用」
4. 在任何輸入框長按 🌐 切換到 TapSay，點麥克風

## 建置

需要 Xcode 16 以上，並用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 產生專案檔（專案檔不進版控）：

```bash
brew install xcodegen
cd apple
xcodegen generate
open TapSay.xcodeproj
```

**簽章設定只要改 `Signing.xcconfig`**：

| 設定 | 說明 |
|---|---|
| `DEVELOPMENT_TEAM` | 你的 Team ID（Xcode → Settings → Accounts） |
| `TAPSAY_BUNDLE_ID` | Bundle ID 在 Apple 是全域唯一的，請換成自己的，例如 `com.yourname.tapsay` |
| `TAPSAY_APP_GROUP` | `group.` 開頭，iOS App 與鍵盤共享資料用 |

- **macOS**：選 `TapSay-macOS` scheme 直接 Run。不簽章也能跑（ad-hoc）。
- **iOS / iPadOS**：選 `TapSay-iOS` scheme、接上裝置 Run。鍵盤需要 **App Groups** 能力，
  免費的 Apple ID（Personal Team）可能無法使用 App Groups，那樣主 App 可以用，鍵盤會讀不到結果。
  要穩定使用鍵盤，建議加入 Apple Developer Program（US$99/年），也才能用 TestFlight 裝到自己的裝置上。

GitHub Actions（`.github/workflows/apple.yml`）在 `apple/` 有變動時會在 macOS runner 上
跑單元測試、編譯兩個平台，並附上 ad-hoc 簽章的 `TapSay-Swift-macOS.zip`。

## macOS 版和 Python 版的差異

| | Python 版 | Swift 版 |
|---|---|---|
| 全域快捷鍵 | pynput，需要「輔助使用」權限 | Carbon `RegisterEventHotKey`，**不需要權限**，按鍵也不會漏給前景程式 |
| 自動貼上 | 需要「輔助使用」 | 一樣需要（模擬 ⌘V），沒權限時結果仍在剪貼簿 |
| 連擊快捷鍵 `double:<ctrl>` | ✓ | 尚未支援 |
| 大小 | 約 48 MB | 幾 MB |
| Windows | ✓ | ✗（Windows 請繼續用 Python 版） |

## 專案結構

```
apple/
├── project.yml                 XcodeGen 專案定義（三個 target）
├── Signing.xcconfig            Team、Bundle ID、App Group
├── Packages/TapSayKit/         三個平台共用的核心（含單元測試）
│   ├── Settings.swift          設定（JSON，存在 App Group 的 UserDefaults）與服務預設
│   ├── Keychain.swift          API Key
│   ├── APIClient.swift         OpenAI 相容 API、multipart、自訂 CA／關閉 TLS 驗證
│   ├── AudioRecorder.swift     AVAudioEngine → 16 kHz mono WAV（只存在記憶體）
│   ├── Pipeline.swift          STT → LLM
│   └── SessionBridge.swift     iOS App ↔ 鍵盤（Darwin notification + App Group）
├── Shared/SettingsView.swift   共用設定畫面
├── macOS/                      Menu bar App、快捷鍵、自動貼上
├── iOS/                        主 App、背景錄音工作階段
└── Keyboard/                   鍵盤擴充
```

## 已知限制

- 這個 Linux 開發環境沒有 Xcode，目前只確認了 CI 上能編譯、單元測試通過。
  麥克風、鍵盤、背景錄音這些部分**還沒在實機上驗證**。
- 鍵盤自動打開 TapSay 用的是沿 responder chain 呼叫 `openURL` 的做法（同類 App 都這樣做），
  不是公開 API，未來的 iOS 版本可能失效。失效時鍵盤會提示改成手動打開 App。
- iOS 沒辦法在 App 回到背景之後才開始錄音，所以必須先在前景開好工作階段。這是系統限制。
