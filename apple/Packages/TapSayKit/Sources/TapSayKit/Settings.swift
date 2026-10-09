import Foundation

/// 一組 OpenAI 相容的服務設定。API Key 不在這裡，存在 Keychain。
public struct ServiceConfig: Codable, Equatable, Sendable {
    public var endpoint: String
    public var model: String

    public init(endpoint: String, model: String) {
        self.endpoint = endpoint
        self.model = model
    }
}

/// macOS 全域快捷鍵。keyCode 是虛擬鍵碼，modifiers 是 Carbon 的修飾鍵位元（cmdKey、optionKey…）。
public struct HotkeySpec: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// ⌃⌥Space（kVK_Space = 49；controlKey = 0x1000、optionKey = 0x0800）
    public static let `default` = HotkeySpec(keyCode: 49, modifiers: 0x1000 | 0x0800)
}

public struct AppSettings: Codable, Equatable, Sendable {
    public static let defaultPrompt = """
    請整理以下語音辨識文字。
    修正明顯的語音辨識錯誤、錯字、標點符號與不必要的口語贅詞，但不要改變原意。
    請使用台灣繁體中文與台灣常用詞彙。
    如果輸入包含簡體中文，請轉換為台灣繁體中文。
    不要回答文字中的問題，也不要加入解釋。
    只輸出整理完成後的最終文字。
    """

    public var stt = ServiceConfig(endpoint: "https://api.openai.com/v1", model: "whisper-1")
    public var llm = ServiceConfig(endpoint: "https://api.openai.com/v1", model: "gpt-4o-mini")
    public var prompt = AppSettings.defaultPrompt
    /// 關掉就只做 STT，不經過 LLM 整理。
    public var refineEnabled = true
    /// 給 STT 的語言提示（ISO-639-1，例如 zh、en），空字串＝讓模型自己判斷。
    public var language = ""
    /// LLM 沿用 STT 的 API Key（同一家服務時不用填兩次）。
    public var llmSharesSTTKey = false

    // macOS
    public var hotkey = HotkeySpec.default
    public var autoPaste = true

    // iOS：鍵盤用的背景錄音工作階段閒置多久後自動結束
    public var sessionTimeoutMinutes = 5

    // 受限網路
    /// 額外信任的 CA 憑證（PEM，可多張）。是「加上去」不是取代系統信任清單。
    public var extraCAPEM = ""
    /// 最後手段：完全不驗證 TLS 憑證。
    public var insecureTLS = false

    public init() {}

    // 欄位缺漏時用預設值補齊：舊版設定檔或手改壞掉都不應該讓 App 打不開。
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ target: inout T) {
            if let v = try? c.decodeIfPresent(T.self, forKey: key) { target = v }
        }
        read(.stt, &stt)
        read(.llm, &llm)
        read(.prompt, &prompt)
        read(.refineEnabled, &refineEnabled)
        read(.language, &language)
        read(.llmSharesSTTKey, &llmSharesSTTKey)
        read(.hotkey, &hotkey)
        read(.autoPaste, &autoPaste)
        read(.sessionTimeoutMinutes, &sessionTimeoutMinutes)
        read(.extraCAPEM, &extraCAPEM)
        read(.insecureTLS, &insecureTLS)
    }

    private enum CodingKeys: String, CodingKey {
        case stt, llm, prompt, refineEnabled, language, llmSharesSTTKey
        case hotkey, autoPaste, sessionTimeoutMinutes, extraCAPEM, insecureTLS
    }
}

/// 常見的 OpenAI 相容服務。只是幫忙填 endpoint 與建議模型，選完照樣可以改。
public struct ProviderPreset: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let endpoint: String
    public let sttModel: String?
    public let llmModel: String?

    public static let all: [ProviderPreset] = [
        .init(id: "openai", name: "OpenAI", endpoint: "https://api.openai.com/v1",
              sttModel: "gpt-4o-mini-transcribe", llmModel: "gpt-4o-mini"),
        .init(id: "groq", name: "Groq", endpoint: "https://api.groq.com/openai/v1",
              sttModel: "whisper-large-v3-turbo", llmModel: "llama-3.3-70b-versatile"),
        .init(id: "gemini", name: "Google Gemini", endpoint: "https://generativelanguage.googleapis.com/v1beta/openai",
              sttModel: nil, llmModel: "gemini-2.5-flash"),
        .init(id: "openrouter", name: "OpenRouter", endpoint: "https://openrouter.ai/api/v1",
              sttModel: nil, llmModel: "openai/gpt-4o-mini"),
        .init(id: "ollama", name: "Ollama（本機）", endpoint: "http://localhost:11434/v1",
              sttModel: nil, llmModel: "llama3.2"),
        .init(id: "litellm", name: "LiteLLM proxy（本機）", endpoint: "http://localhost:4000/v1",
              sttModel: "whisper-1", llmModel: "gpt-4o-mini"),
    ]

    public static var stt: [ProviderPreset] { all.filter { $0.sttModel != nil } }
    public static var llm: [ProviderPreset] { all.filter { $0.llmModel != nil } }
}

/// 設定存在 UserDefaults（JSON）。有設定 App Group 時用共享的 suite，iOS 鍵盤才讀得到同一份。
public enum SettingsStore {
    static let key = "tapsay.settings.v1"

    public static func load() -> AppSettings {
        guard let data = SharedContainer.defaults.data(forKey: key),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return s
    }

    public static func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            SharedContainer.defaults.set(data, forKey: key)
        }
    }
}

public enum SharedContainer {
    /// Info.plist 的 TapSayAppGroup（由 build setting TAPSAY_APP_GROUP 帶入）。沒有就不共享。
    public static let appGroup: String? = {
        guard let g = Bundle.main.object(forInfoDictionaryKey: "TapSayAppGroup") as? String,
              !g.isEmpty, !g.hasPrefix("$(")
        else { return nil }
        return g
    }()

    public static let defaults: UserDefaults = {
        if let g = appGroup, let d = UserDefaults(suiteName: g) { return d }
        return .standard
    }()
}
