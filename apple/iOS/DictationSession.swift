import AVFoundation
import Observation
import TapSayKit
import UIKit

/// iOS 的錄音工作階段。
///
/// 鍵盤擴充不能用麥克風，所以由主 App 在前景先把麥克風打開（`startSession`），
/// 之後退到背景靠 audio background mode 繼續活著，聽鍵盤送來的 start/stop 指令。
/// 閒置超過設定時間就自動結束，麥克風關閉、App 被系統暫停。
@MainActor
@Observable
final class DictationSession {
    static let shared = DictationSession()

    private(set) var isActive = false
    private(set) var state: DictationState = .idle
    private(set) var message: String?
    private(set) var lastResult: String?
    private(set) var expiresAt: Date?

    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private var tokens: [ObservationToken] = []
    @ObservationIgnored private var heartbeat: Timer?
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var resetTask: Task<Void, Never>?

    private init() {
        tokens = [
            SessionBridge.observe(.start) { [weak self] in self?.beginCapture() },
            SessionBridge.observe(.stop) { [weak self] in self?.endCapture() },
            SessionBridge.observe(.cancel) { [weak self] in self?.cancelCapture() },
        ]
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                               object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            MainActor.assumeIsolated { self?.endSession(reason: "被其他音訊中斷（例如來電）") }
        }
    }

    // MARK: 工作階段

    func startSession() async -> Bool {
        if isActive { touch(); return true }
        guard await AVAudioApplication.requestRecordPermission() else {
            fail("沒有麥克風權限：請到「設定 → TapSay」開啟麥克風")
            return false
        }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
            try audio.setActive(true)
            try recorder.warmUp()
        } catch {
            fail(error.localizedDescription)
            return false
        }
        isActive = true
        message = nil
        touch()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
        SessionBridge.publish(.idle)
        return true
    }

    func endSession(reason: String? = nil) {
        guard isActive else { return }
        heartbeat?.invalidate()
        heartbeat = nil
        recorder.coolDown()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isActive = false
        expiresAt = nil
        state = .idle
        message = reason
        SessionBridge.endSession()
    }

    private func touch() {
        lastActivity = Date()
        let minutes = max(1, SettingsStore.load().sessionTimeoutMinutes)
        expiresAt = lastActivity.addingTimeInterval(TimeInterval(minutes * 60))
    }

    private func tick() {
        SessionBridge.beat()
        if !recorder.isCapturing, state != .processing, let expiresAt, Date() > expiresAt {
            endSession(reason: "閒置太久，已自動關閉麥克風")
        }
    }

    // MARK: 收音

    /// 從 App 內或鍵盤開始。工作階段還沒開就先開（只有前景時會成功）。
    func beginCapture() {
        guard state != .processing, !recorder.isCapturing else { return }
        Task {
            guard await startSession() else { return }
            do {
                try recorder.begin()
                touch()
                set(.recording)
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    func endCapture() {
        guard recorder.isCapturing else { return }
        touch()
        let wav: Data
        do {
            wav = try recorder.end()
        } catch {
            fail(error.localizedDescription)
            return
        }
        set(.processing)
        let settings = SettingsStore.load()
        // 處理途中 App 可能被切到背景；要一點額外時間把請求跑完。
        let bg = UIApplication.shared.beginBackgroundTask(withName: "tapsay.process")
        Task {
            defer { UIApplication.shared.endBackgroundTask(bg) }
            do {
                let text = try await Pipeline.run(wav: wav, settings: settings)
                lastResult = text
                UIPasteboard.general.string = text  // 保底：鍵盤沒插入成功也能自己貼
                message = nil
                SessionBridge.publishResult(text)
                set(.done, resetAfter: 1.5)
            } catch {
                fail("處理失敗：\(error.localizedDescription)")
            }
            touch()
        }
    }

    func cancelCapture() {
        recorder.cancel()
        set(.idle)
    }

    func toggleCapture() {
        recorder.isCapturing ? endCapture() : beginCapture()
    }

    // MARK: 狀態

    private func fail(_ text: String) {
        message = text
        set(.error, resetAfter: 3)
    }

    private func set(_ new: DictationState, resetAfter delay: Double? = nil) {
        resetTask?.cancel()
        state = new
        if new != .done { SessionBridge.publish(new, message: message) }
        guard let delay else { return }
        resetTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, state == new else { return }
            state = .idle
            SessionBridge.publish(.idle)
        }
    }
}
