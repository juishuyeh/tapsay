import Foundation

/// iOS 主 App 與鍵盤擴充之間的溝通。
///
/// iOS 不讓鍵盤擴充使用麥克風，所以實際錄音、呼叫 API 都在主 App（背景音訊模式）裡做：
/// - 指令（鍵盤 → App）：Darwin notification `start` / `stop` / `cancel`
/// - 狀態與結果（App → 鍵盤）：寫進 App Group 的 UserDefaults，再發 `changed` 通知
/// - App 是否還活著：App 每隔幾秒更新一次 heartbeat
public enum SessionBridge {
    public enum Command: String, CaseIterable, Sendable {
        case start, stop, cancel, changed
        public var notificationName: String { "io.github.tapsay.session.\(rawValue)" }
    }

    /// heartbeat 超過這麼久沒更新就視為 App 已經不在背景錄音了。
    public static let heartbeatTimeout: TimeInterval = 6
    /// 結果超過這麼久才被鍵盤看到就不自動插入（多半已經換到別的輸入框了）。
    public static let resultFreshness: TimeInterval = 90

    private enum Key {
        static let heartbeat = "session.heartbeat"
        static let state = "session.state"
        static let message = "session.message"
        static let resultText = "result.text"
        static let resultID = "result.id"
        static let resultDate = "result.date"
        static let consumedID = "result.consumedID"
    }

    private static var defaults: UserDefaults { SharedContainer.defaults }

    // MARK: App 端

    public static func beat() { defaults.set(Date().timeIntervalSince1970, forKey: Key.heartbeat) }

    public static func endSession() {
        defaults.removeObject(forKey: Key.heartbeat)
        publish(.idle)
    }

    public static func publish(_ state: DictationState, message: String? = nil) {
        defaults.set(state.rawValue, forKey: Key.state)
        defaults.set(message, forKey: Key.message)
        post(.changed)
    }

    public static func publishResult(_ text: String) {
        defaults.set(text, forKey: Key.resultText)
        defaults.set(UUID().uuidString, forKey: Key.resultID)
        defaults.set(Date().timeIntervalSince1970, forKey: Key.resultDate)
        publish(.done)
    }

    // MARK: 鍵盤端

    public static var isSessionAlive: Bool {
        let t = defaults.double(forKey: Key.heartbeat)
        return t > 0 && Date().timeIntervalSince1970 - t < heartbeatTimeout
    }

    public static var state: DictationState {
        defaults.string(forKey: Key.state).flatMap(DictationState.init(rawValue:)) ?? .idle
    }

    public static var message: String? { defaults.string(forKey: Key.message) }

    /// 取出還沒插入過、而且夠新的結果；取出即標記為已使用，同一段文字不會插兩次。
    public static func takeResult() -> String? {
        guard let id = defaults.string(forKey: Key.resultID),
              id != defaults.string(forKey: Key.consumedID),
              let text = defaults.string(forKey: Key.resultText)
        else { return nil }
        defaults.set(id, forKey: Key.consumedID)
        let age = Date().timeIntervalSince1970 - defaults.double(forKey: Key.resultDate)
        return age < resultFreshness ? text : nil
    }

    // MARK: Darwin notification

    public static func post(_ command: Command) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(command.notificationName as CFString),
                                             nil, nil, true)
    }

    private static let lock = NSLock()
    private static var handlers: [String: [UUID: () -> Void]] = [:]
    private static var registered: Set<String> = []
    /// CFNotificationCenter 需要一個非 nil 的 observer 識別，用一個常駐物件的位址就好。
    private static let observerID = UnsafeRawPointer(Unmanaged.passUnretained(lock).toOpaque())

    /// 回傳的 token 被釋放時自動取消監聽。handler 一律在主執行緒執行。
    public static func observe(_ command: Command, handler: @escaping () -> Void) -> ObservationToken {
        let name = command.notificationName
        let id = UUID()
        lock.lock()
        handlers[name, default: [:]][id] = handler
        let first = registered.insert(name).inserted
        lock.unlock()
        if first {
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            CFNotificationCenterAddObserver(center, observerID, { _, _, cfName, _, _ in
                guard let raw = cfName?.rawValue else { return }
                SessionBridge.dispatch(raw as String)
            }, name as CFString, nil, .deliverImmediately)
        }
        return ObservationToken { SessionBridge.remove(name, id) }
    }

    private static func dispatch(_ name: String) {
        lock.lock()
        let list = Array(handlers[name, default: [:]].values)
        lock.unlock()
        DispatchQueue.main.async { list.forEach { $0() } }
    }

    private static func remove(_ name: String, _ id: UUID) {
        lock.lock()
        handlers[name]?[id] = nil
        lock.unlock()
        // 系統端的 observer 保留不移除：沒有 handler 時收到通知只是什麼都不做。
    }
}

public final class ObservationToken {
    private let cancel: () -> Void
    init(_ cancel: @escaping () -> Void) { self.cancel = cancel }
    deinit { cancel() }
}
