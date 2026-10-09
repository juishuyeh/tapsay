import Foundation

/// 錄好的音訊 → STT →（可選）LLM 整理 → 最終文字。
public enum Pipeline {
    public static func run(wav: Data, settings: AppSettings) async throws -> String {
        let client = APIClient(settings: settings)
        let sttKey = Keychain.get(.stt)
        let raw = try await client.transcribe(endpoint: settings.stt.endpoint, apiKey: sttKey,
                                              model: settings.stt.model, language: settings.language, audio: wav)
        guard settings.refineEnabled else { return raw }
        let llmKey = settings.llmSharesSTTKey ? sttKey : Keychain.get(.llm)
        return try await client.refine(endpoint: settings.llm.endpoint, apiKey: llmKey, model: settings.llm.model,
                                       prompt: settings.prompt, text: raw)
    }
}

/// 三個平台共用的狀態，對應 Python 版 menu bar 圖示的顏色。
public enum DictationState: String, Codable, Sendable {
    case idle, recording, processing, done, error
}
