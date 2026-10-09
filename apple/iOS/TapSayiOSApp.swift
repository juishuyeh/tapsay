import SwiftUI
import TapSayKit

@main
struct TapSayiOSApp: App {
    @State private var session = DictationSession.shared

    var body: some Scene {
        WindowGroup {
            HomeView(session: session)
                // 鍵盤在工作階段沒開時會打開 tapsay://dictate：開麥克風並立刻開始收音，
                // 使用者再點左上角「◀ 返回」回到原本的 App 繼續說話。
                .onOpenURL { url in
                    guard url.scheme == "tapsay" else { return }
                    switch url.host {
                    case "dictate": session.beginCapture()
                    case "session": Task { _ = await session.startSession() }
                    default: break
                    }
                }
        }
    }
}
