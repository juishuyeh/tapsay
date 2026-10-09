import AppKit
import SwiftUI
import TapSayKit

struct PlatformSettingsSection: View {
    @Binding var settings: AppSettings
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Section {
            LabeledContent("全域快捷鍵") {
                HStack {
                    Text(recording ? "請按下新的組合鍵…" : settings.hotkey.displayString)
                        .monospaced()
                    Button(recording ? "取消" : "變更…", action: toggleRecording)
                    Button("預設") { settings.hotkey = .default }
                        .disabled(settings.hotkey == .default)
                }
            }
            Toggle("自動貼到游標位置", isOn: $settings.autoPaste)
            if settings.autoPaste && !Paster.isTrusted {
                Button("自動貼上需要「輔助使用」權限，點這裡開啟…") { Paster.requestTrust() }
            }
        } header: {
            Text("macOS")
        } footer: {
            Text("快捷鍵至少要含一個 ⌘、⌥ 或 ⌃。關閉自動貼上時，結果只會放進剪貼簿。")
        }
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        if recording { stopRecording(); return }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let spec = HotkeySpec(event: event)
            if event.keyCode == 53 && spec.modifiers == 0 {  // Esc 取消
                stopRecording()
                return nil
            }
            let hasModifier = !event.modifierFlags.intersection([.command, .option, .control]).isEmpty
            let isFunctionKey = (96...122).contains(Int(event.keyCode))  // F1–F12 等可以不帶修飾鍵
            guard hasModifier || isFunctionKey else { return nil }
            settings.hotkey = spec
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}
