import SwiftUI
import TapSayKit

@main
struct TapSayMacApp: App {
    @State private var controller = MacController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            Image(systemName: controller.state.symbol)
        }

        Settings {
            SettingsView()
                .frame(minWidth: 560, minHeight: 640)
                .onDisappear { controller.reloadSettings() }
        }
    }
}

private struct MenuContent: View {
    let controller: MacController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(controller.statusLine)
        if let message = controller.lastMessage {
            Text(message).lineLimit(3)
        }
        Divider()
        Button(controller.state == .recording ? "停止並送出" : "開始錄音") { controller.toggle() }
            .disabled(controller.state == .processing)
        if controller.state == .recording {
            Button("取消錄音") { controller.cancel() }
        }
        if let last = controller.lastResult {
            Button("再複製一次上次結果") { Paster.copy(last) }
        }
        Divider()
        Button("設定…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")
        if !Paster.isTrusted {
            Button("開啟「輔助使用」權限（自動貼上需要）…") { Paster.requestTrust() }
        }
        Divider()
        Button("結束 TapSay") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

extension DictationState {
    var symbol: String {
        switch self {
        case .idle: "mic"
        case .recording: "mic.fill"
        case .processing: "ellipsis.circle"
        case .done: "checkmark.circle"
        case .error: "exclamationmark.triangle"
        }
    }
}
