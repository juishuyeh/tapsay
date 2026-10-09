import AVFoundation
import Observation
import SwiftUI
import TapSayKit
import UserNotifications

/// 狀態機：Hotkey → 錄音 → STT → LLM → 剪貼簿 → 自動貼上（與 Python 版相同流程）。
@MainActor
@Observable
final class MacController {
    private(set) var state: DictationState = .idle
    private(set) var lastMessage: String?
    private(set) var lastResult: String?

    @ObservationIgnored private var settings = SettingsStore.load()
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private let hotKey = HotKey()
    @ObservationIgnored private var resetTask: Task<Void, Never>?

    init() {
        registerHotKey()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    var statusLine: String {
        switch state {
        case .idle: "待命中（\(settings.hotkey.displayString)）"
        case .recording: "錄音中…再按一次送出"
        case .processing: "處理中…"
        case .done: "完成"
        case .error: "發生錯誤"
        }
    }

    func reloadSettings() {
        let old = settings.hotkey
        settings = SettingsStore.load()
        if settings.hotkey != old { registerHotKey() }
    }

    private func registerHotKey() {
        if !hotKey.register(settings.hotkey, action: { [weak self] in self?.toggle() }) {
            fail("快捷鍵 \(settings.hotkey.displayString) 無法註冊，可能已被其他程式占用")
        }
    }

    func toggle() {
        switch state {
        case .processing:
            return
        case .recording:
            finish()
        default:
            start()
        }
    }

    func cancel() {
        recorder.cancel()
        recorder.coolDown()
        set(.idle)
    }

    private func start() {
        resetTask?.cancel()
        settings = SettingsStore.load()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in if granted { self.start() } else { self.fail("沒有麥克風權限") } }
            }
            return
        default:
            fail("沒有麥克風權限：請到「系統設定 → 隱私權與安全性 → 麥克風」允許 TapSay")
            return
        }
        do {
            try recorder.begin()
            set(.recording)
        } catch {
            recorder.coolDown()
            fail(error.localizedDescription)
        }
    }

    private func finish() {
        let wav: Data
        do {
            wav = try recorder.end()
        } catch {
            recorder.coolDown()
            fail(error.localizedDescription)
            return
        }
        recorder.coolDown()  // 馬上關麥克風，menu bar 的橘色麥克風指示燈才會熄
        set(.processing)
        let settings = settings
        Task {
            do {
                let text = try await Pipeline.run(wav: wav, settings: settings)
                deliver(text)
            } catch {
                fail("處理失敗：\(error.localizedDescription)")
            }
        }
    }

    private func deliver(_ text: String) {
        lastResult = text
        Paster.copy(text)  // 保底：先寫剪貼簿，自動貼上失敗也不會遺失
        if settings.autoPaste {
            guard Paster.isTrusted else {
                fail("文字已複製到剪貼簿；自動貼上需要「輔助使用」權限")
                Paster.requestTrust()
                return
            }
            Paster.paste()
        }
        lastMessage = nil
        set(.done, resetAfter: 1.2)
    }

    private func fail(_ message: String) {
        lastMessage = message
        set(.error, resetAfter: 3)
        let content = UNMutableNotificationContent()
        content.title = "TapSay"
        content.body = message
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString,
                                                                     content: content, trigger: nil))
    }

    private func set(_ new: DictationState, resetAfter delay: Double? = nil) {
        resetTask?.cancel()
        state = new
        guard let delay else { return }
        resetTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            if !Task.isCancelled, state == new { state = .idle }
        }
    }
}
