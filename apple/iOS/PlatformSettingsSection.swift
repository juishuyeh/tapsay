import SwiftUI
import TapSayKit

struct PlatformSettingsSection: View {
    @Binding var settings: AppSettings

    var body: some View {
        Section {
            Stepper("閒置 \(settings.sessionTimeoutMinutes) 分鐘後關閉麥克風",
                    value: $settings.sessionTimeoutMinutes, in: 1...60)
        } header: {
            Text("鍵盤工作階段")
        } footer: {
            Text("時間越長越不用常常回 TapSay 重開，但麥克風指示燈會一直亮著、也比較耗電。")
        }
    }
}
