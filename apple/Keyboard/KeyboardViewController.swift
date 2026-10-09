import Observation
import SwiftUI
import TapSayKit
import UIKit

/// TapSay 鍵盤：一顆大麥克風按鈕，加上切換鍵盤、空白、刪除、換行。
/// 錄音與 API 都在主 App 做（鍵盤擴充不能用麥克風），這裡只送指令、收結果、插入文字。
final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
    private var host: UIHostingController<KeyboardView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        model.controller = self
        let host = UIHostingController(rootView: KeyboardView(model: model))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            view.heightAnchor.constraint(equalToConstant: 236),
        ])
        host.didMove(toParent: self)
        self.host = host
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.appear()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.disappear()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // Observable 不會比對新舊值，相同也重繪；只在真的改變時才設，避免版面重排無限循環。
        if model.showsGlobe != needsInputModeSwitchKey { model.showsGlobe = needsInputModeSwitchKey }
    }

    /// 鍵盤擴充沒有 UIApplication.shared，也不能用 extensionContext.open。
    /// 沿著 responder chain 找到宿主的 UIApplication 再呼叫 open(_:options:completionHandler:)。
    func openContainingApp(_ url: URL) {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication, app.responds(to: selector) {
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, OpaquePointer?) -> Void
                let imp = app.method(for: selector)
                unsafeBitCast(imp, to: Open.self)(app, selector, url as NSURL, NSDictionary(), nil)
                return
            }
            responder = r.next
        }
        model.notice = "無法自動開啟 TapSay，請手動打開 App"
    }
}

@MainActor
@Observable
final class KeyboardModel {
    var state: DictationState = .idle
    var sessionAlive = false
    var notice: String?
    var showsGlobe = true
    @ObservationIgnored weak var controller: KeyboardViewController?

    @ObservationIgnored private var token: ObservationToken?
    @ObservationIgnored private var timer: Timer?

    var hasFullAccess: Bool { controller?.hasFullAccess ?? false }

    func appear() {
        token = SessionBridge.observe(.changed) { [weak self] in self?.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func disappear() {
        timer?.invalidate()
        timer = nil
        token = nil
    }

    func refresh() {
        guard hasFullAccess else { return }
        let alive = SessionBridge.isSessionAlive
        let newState = alive ? SessionBridge.state : .idle
        if alive != sessionAlive { sessionAlive = alive }
        if newState != state {
            state = newState
            notice = newState == .error ? SessionBridge.message : nil
        }
        if let text = SessionBridge.takeResult() {
            controller?.textDocumentProxy.insertText(text)
            notice = nil
        }
    }

    func micTapped() {
        guard hasFullAccess else {
            notice = "請到 設定 → 一般 → 鍵盤 → 鍵盤 → TapSay 開啟「允許完整取用」"
            return
        }
        guard SessionBridge.isSessionAlive else {
            notice = "正在開啟 TapSay… 開始說話後點左上角「◀ 返回」回來"
            controller?.openContainingApp(URL(string: "tapsay://dictate")!)
            return
        }
        notice = nil
        switch state {
        case .recording: SessionBridge.post(.stop)
        case .processing: break
        default: SessionBridge.post(.start)
        }
    }

    func cancel() { SessionBridge.post(.cancel) }

    var statusText: String {
        if let notice { return notice }
        if !hasFullAccess { return "需要開啟「允許完整取用」" }
        if !sessionAlive { return "點麥克風會先打開 TapSay 開啟麥克風" }
        switch state {
        case .recording: return "錄音中…再點一下送出"
        case .processing: return "處理中…"
        case .done: return "已輸入"
        case .error: return "發生錯誤"
        case .idle: return "點麥克風開始說話"
        }
    }
}

struct KeyboardView: View {
    let model: KeyboardModel

    var body: some View {
        VStack(spacing: 10) {
            Text(model.statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 34)

            HStack(spacing: 18) {
                if model.state == .recording {
                    KeyButton(systemName: "xmark", label: "取消") { model.cancel() }
                } else {
                    Color.clear.frame(width: 52, height: 44)
                }
                Button(action: model.micTapped) {
                    Group {
                        if model.state == .processing {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: model.state == .recording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 32, weight: .semibold))
                        }
                    }
                    .frame(width: 88, height: 88)
                    .foregroundStyle(.white)
                    .background(Circle().fill(model.state == .recording ? Color.red : Color.accentColor))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.state == .recording ? "停止並送出" : "開始說話")
                Color.clear.frame(width: 52, height: 44)
            }

            HStack(spacing: 6) {
                if model.showsGlobe {
                    GlobeKey(controller: model.controller).frame(width: 44, height: 42)
                }
                KeyButton(systemName: nil, label: "空白") { model.controller?.textDocumentProxy.insertText(" ") }
                    .frame(maxWidth: .infinity)
                KeyButton(systemName: "delete.left", label: "刪除") { model.controller?.textDocumentProxy.deleteBackward() }
                    .frame(width: 56)
                KeyButton(systemName: "return", label: "換行") { model.controller?.textDocumentProxy.insertText("\n") }
                    .frame(width: 56)
            }
            .padding(.horizontal, 6)
        }
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}

private struct KeyButton: View {
    let systemName: String?
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemName { Image(systemName: systemName) } else { Text(label) }
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(uiColor: .secondarySystemBackground)))
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// 「切換鍵盤」鍵必須交給系統處理，長按才會出現鍵盤清單（App Review 也要求一定要有）。
private struct GlobeKey: UIViewRepresentable {
    weak var controller: KeyboardViewController?

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "globe"), for: .normal)
        button.tintColor = .label
        button.backgroundColor = .secondarySystemBackground
        button.layer.cornerRadius = 6
        button.accessibilityLabel = "切換鍵盤"
        if let controller {
            button.addTarget(controller, action: #selector(UIInputViewController.handleInputModeList(from:with:)),
                             for: .allTouchEvents)
        }
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}
}
