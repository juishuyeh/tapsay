import SwiftUI
import TapSayKit

/// iOS 與 macOS 共用的設定畫面。改動即時存檔。
struct SettingsView: View {
    @State private var settings = SettingsStore.load()
    @State private var sttKey = ""
    @State private var llmKey = ""
    @State private var hasSTTKey = false
    @State private var hasLLMKey = false

    var body: some View {
        Form {
            ServiceSection(title: "語音辨識（STT）", kind: .stt, presets: ProviderPreset.stt,
                           config: $settings.stt, keyInput: $sttKey, hasKey: $hasSTTKey) {
                TextField("語言提示（選填，例如 zh、en）", text: $settings.language)
                    .autocorrectionDisabledCompat()
            }

            Section {
                Toggle("用 LLM 整理文字", isOn: $settings.refineEnabled)
            } footer: {
                Text("關掉就直接輸出語音辨識的原始結果，速度最快。")
            }

            if settings.refineEnabled {
                ServiceSection(title: "文字整理（LLM）", kind: .llm, presets: ProviderPreset.llm,
                               config: $settings.llm, keyInput: $llmKey, hasKey: $hasLLMKey,
                               sharesKey: $settings.llmSharesSTTKey) {
                    EmptyView()
                }

                Section {
                    TextEditor(text: $settings.prompt)
                        .font(.body.monospaced())
                        .frame(minHeight: 140)
                    Button("恢復預設 Prompt") { settings.prompt = AppSettings.defaultPrompt }
                        .disabled(settings.prompt == AppSettings.defaultPrompt)
                } header: {
                    Text("Prompt")
                }
            }

            PlatformSettingsSection(settings: $settings)

            Section {
                TextEditor(text: $settings.extraCAPEM)
                    .font(.caption.monospaced())
                    .frame(minHeight: 80)
                Toggle("關閉 TLS 憑證驗證（不安全）", isOn: $settings.insecureTLS)
            } header: {
                Text("受限網路")
            } footer: {
                Text("公司 MITM proxy 或自簽憑證的內部 endpoint 才需要。上面可貼一或多張 PEM 格式的 CA 憑證，"
                     + "會加進系統信任清單（不是取代）。關閉驗證是最後手段，連線內容可被中間人看到。")
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings) { _, new in SettingsStore.save(new) }
        .onAppear {
            hasSTTKey = Keychain.has(.stt)
            hasLLMKey = Keychain.has(.llm)
        }
    }
}

private struct ServiceSection<Extra: View>: View {
    let title: String
    let kind: Keychain.Kind
    let presets: [ProviderPreset]
    @Binding var config: ServiceConfig
    @Binding var keyInput: String
    @Binding var hasKey: Bool
    var sharesKey: Binding<Bool>? = nil
    @ViewBuilder var extra: () -> Extra

    @State private var models: [String] = []
    @State private var status: String?
    @State private var loading = false

    private var usesSharedKey: Bool { sharesKey?.wrappedValue ?? false }

    var body: some View {
        Section {
            Menu("套用常見服務…") {
                ForEach(presets) { p in
                    Button(p.name) {
                        config.endpoint = p.endpoint
                        config.model = (kind == .stt ? p.sttModel : p.llmModel) ?? config.model
                        models = []
                    }
                }
            }
            TextField("Endpoint（例如 https://api.openai.com/v1）", text: $config.endpoint)
                .urlFieldCompat()

            if let sharesKey {
                Toggle("沿用 STT 的 API Key", isOn: sharesKey)
            }
            if !usesSharedKey {
                HStack {
                    SecureField(hasKey ? "已儲存（輸入新值才會覆寫）" : "API Key（本機服務可留白）", text: $keyInput)
                        .onSubmit(saveKey)
                    Button("儲存", action: saveKey).disabled(keyInput.isEmpty)
                    if hasKey {
                        Button("清除", role: .destructive) {
                            Keychain.set(kind, "")
                            hasKey = false
                        }
                    }
                }
            }

            HStack {
                TextField("Model", text: $config.model)
                    .autocorrectionDisabledCompat()
                if !models.isEmpty {
                    Picker("", selection: $config.model) {
                        if !models.contains(config.model) { Text(config.model).tag(config.model) }
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            extra()

            HStack {
                Button(loading ? "連線中…" : "測試連線 / 取得模型", action: fetchModels).disabled(loading)
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        } header: {
            Text(title)
        } footer: {
            Text("任何 OpenAI 相容的服務都可以：填 base URL，程式自己接 /audio/transcriptions、/chat/completions、/models。")
        }
    }

    private func saveKey() {
        guard !keyInput.isEmpty else { return }
        hasKey = Keychain.set(kind, keyInput.trimmingCharacters(in: .whitespacesAndNewlines))
        keyInput = ""
    }

    private func fetchModels() {
        saveKey()
        loading = true
        status = nil
        let endpoint = config.endpoint
        let key = usesSharedKey ? Keychain.get(.stt) : Keychain.get(kind)
        let settings = SettingsStore.load()
        Task {
            do {
                let list = try await APIClient(settings: settings).listModels(endpoint: endpoint, apiKey: key)
                models = list
                status = list.isEmpty ? "連線成功，但沒有模型清單" : "連線成功，\(list.count) 個模型"
            } catch {
                models = []
                status = "\(error.localizedDescription)（不支援模型清單時可直接手動輸入）"
            }
            loading = false
        }
    }
}

extension View {
    @ViewBuilder func urlFieldCompat() -> some View {
        #if os(iOS)
        self.keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }

    @ViewBuilder func autocorrectionDisabledCompat() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }
}
