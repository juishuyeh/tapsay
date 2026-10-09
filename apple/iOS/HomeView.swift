import SwiftUI
import TapSayKit

struct HomeView: View {
    let session: DictationSession

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 16) {
                        Button(action: session.toggleCapture) {
                            Image(systemName: session.state == .recording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 44, weight: .semibold))
                                .frame(width: 112, height: 112)
                                .foregroundStyle(.white)
                                .background(Circle().fill(session.state.tint))
                        }
                        .buttonStyle(.plain)
                        .disabled(session.state == .processing)

                        Text(session.state.label).font(.headline)
                        if let message = session.message {
                            Text(message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }

                if let result = session.lastResult {
                    Section("上次結果（已複製到剪貼簿）") {
                        Text(result).textSelection(.enabled)
                        Button("再複製一次") { UIPasteboard.general.string = result }
                    }
                }

                Section {
                    if session.isActive {
                        if let expiresAt = session.expiresAt {
                            LabeledContent("麥克風待命中") {
                                Text(expiresAt, style: .relative)
                            }
                        }
                        Button("結束工作階段（關閉麥克風）", role: .destructive) { session.endSession() }
                    } else {
                        Button("開啟鍵盤用的工作階段") { Task { _ = await session.startSession() } }
                    }
                } header: {
                    Text("在其他 App 裡用 TapSay 鍵盤")
                } footer: {
                    Text("iOS 不允許鍵盤直接使用麥克風，所以由 TapSay 在背景代為錄音。"
                         + "工作階段開著時（畫面上方會有橘色麥克風指示），鍵盤上的麥克風按鈕可直接使用；"
                         + "閒置超過設定的時間會自動關閉。")
                }

                Section("第一次使用") {
                    Label("設定 → 一般 → 鍵盤 → 鍵盤 → 新增鍵盤 → TapSay", systemImage: "keyboard")
                    Label("點 TapSay → 開啟「允許完整取用」（鍵盤要讀取 App 傳來的文字）", systemImage: "lock.open")
                    Label("在下方「設定」填好 STT／LLM 的 Endpoint、API Key、Model", systemImage: "gearshape")
                    Button("打開 TapSay 的系統設定") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }

                Section {
                    NavigationLink("設定") {
                        SettingsView().navigationTitle("設定")
                    }
                }
            }
            .navigationTitle("TapSay")
        }
    }
}

extension DictationState {
    var label: String {
        switch self {
        case .idle: "點一下開始說話"
        case .recording: "錄音中…再點一下送出"
        case .processing: "處理中…"
        case .done: "完成"
        case .error: "發生錯誤"
        }
    }

    var tint: Color {
        switch self {
        case .idle: .accentColor
        case .recording: .red
        case .processing: .orange
        case .done: .green
        case .error: .gray
        }
    }
}
