import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var openAIKey = ""
    @State private var claudeKey = ""
    @State private var elevenLabsKey = ""
    @State private var elevenLabsMessage: String?
    @State private var isSavingElevenLabs = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var message: String?
    @State private var isSaving = false
    @AppStorage(GeminiSettings.billingTableKey) private var geminiBillingTable = ""
    @State private var geminiServiceAccountJSON = ""
    @AppStorage("hasGeminiCredential") private var hasGeminiCredential = false
    @State private var showingServiceAccountImporter = false
    @State private var isSavingGemini = false
    @State private var geminiMessage: String?

    var body: some View {
        Form {
            Section("自動同步") {
                SecureField("OpenAI Admin API Key（留空保留原值）", text: $openAIKey)
                ProviderStatusRow(platform: .openAI, status: store.providerStatuses[.openAI])
                SecureField("Claude Admin API Key（留空保留原值）", text: $claudeKey)
                ProviderStatusRow(platform: .claude, status: store.providerStatuses[.claude])
                Text("金鑰僅存於 macOS Keychain。OpenAI 與 Claude 每 15 分鐘同步帳務用量。請先輸入目前剩餘額度與到期日；首次同步建立基準，之後扣除新增花費。這些帳務 API 不提供贈送額度到期日。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("儲存並測試金鑰") { saveKeys() }
                        .disabled(isSaving)
                    Button("清除") { clearKeys() }
                        .disabled(isSaving)
                    if isSaving { ProgressView().controlSize(.small) }
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("ElevenLabs credits") {
                SecureField("ElevenLabs API Key（留空保留原值）", text: $elevenLabsKey)
                ProviderStatusRow(platform: .elevenLabs, status: store.providerStatuses[.elevenLabs])
                Text("API Key 需有 User: Read 權限。每 15 分鐘讀取方案總額度、已使用 credits 與下次重設時間，並自動建立或更新方案額度。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("儲存並測試 ElevenLabs") { saveElevenLabs() }
                        .disabled(isSavingElevenLabs)
                    Button("清除 ElevenLabs 金鑰") { clearElevenLabs() }
                        .disabled(isSavingElevenLabs)
                    if isSavingElevenLabs { ProgressView().controlSize(.small) }
                    if let elevenLabsMessage { Text(elevenLabsMessage).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("Gemini（Google Cloud Billing）") {
                TextField(
                    "BigQuery 完整表名",
                    text: $geminiBillingTable,
                    prompt: Text("project.dataset.gcp_billing_export_v1_XXXXXX")
                )
                HStack {
                    Button(hasGeminiCredential ? "重新匯入 Service Account JSON" : "匯入 Service Account JSON") {
                        showingServiceAccountImporter = true
                    }
                    if hasGeminiCredential {
                        Label("憑證已存入 Keychain", systemImage: "checkmark.shield.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                }
                ProviderStatusRow(platform: .gemini, status: store.providerStatuses[.gemini])
                Text("每 6 小時查詢一次。表名可在 GCP → Billing → Billing export → BigQuery export 查看。Service Account 需要 BigQuery Job User 與 Data Viewer 權限。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("儲存並測試 Gemini") { saveGemini() }
                        .disabled(isSavingGemini || geminiBillingTable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!hasGeminiCredential && geminiServiceAccountJSON.isEmpty))
                    Button("清除 Gemini 設定") { clearGemini() }
                        .disabled(isSavingGemini)
                    if isSavingGemini { ProgressView().controlSize(.small) }
                    if let geminiMessage { Text(geminiMessage).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("一般") {
                Toggle("登入後自動啟動", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in updateLaunchAtLogin(enabled) }
                Text("到期前 30、7、1 天，以及到期當天發送通知。")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("版本", value: "\(AppVersion.short) (\(AppVersion.build))")
            }
        }
        .formStyle(.grouped)
        .frame(width: 650, height: 760)
        .navigationTitle("AI Credits 設定")
        .task { await store.refreshIfNeeded() }
        .fileImporter(isPresented: $showingServiceAccountImporter, allowedContentTypes: [.json]) { result in
            importServiceAccount(result)
        }
    }

    private func saveKeys() {
        do {
            if !openAIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try store.setAPIKey(openAIKey, for: .openAI)
            }
            if !claudeKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try store.setAPIKey(claudeKey, for: .claude)
            }
            message = "已儲存，正在同步…"
            openAIKey = ""
            claudeKey = ""
            isSaving = true
            Task {
                await store.refresh(platform: .openAI)
                await store.refresh(platform: .claude)
                isSaving = false
                message = [.openAI, .claude].contains { store.providerStatuses[$0]?.state == .failed }
                    ? "同步失敗，請查看上方原因" : "檢查完成，請查看各平台狀態"
            }
        } catch { message = error.localizedDescription }
    }

    private func saveElevenLabs() {
        do {
            if !elevenLabsKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try store.setAPIKey(elevenLabsKey, for: .elevenLabs)
                elevenLabsKey = ""
            }
            isSavingElevenLabs = true
            elevenLabsMessage = "正在同步…"
            Task {
                await store.refresh(platform: .elevenLabs)
                isSavingElevenLabs = false
                elevenLabsMessage = store.providerStatuses[.elevenLabs]?.state == .success
                    ? "已同步方案額度" : "請查看上方同步狀態"
            }
        } catch { elevenLabsMessage = error.localizedDescription }
    }

    private func clearElevenLabs() {
        do {
            try store.setAPIKey("", for: .elevenLabs)
            elevenLabsKey = ""
            elevenLabsMessage = "已清除金鑰，保留最後一次額度紀錄"
        } catch { elevenLabsMessage = error.localizedDescription }
    }

    private func clearKeys() {
        openAIKey = ""
        claudeKey = ""
        do {
            try store.setAPIKey("", for: .openAI)
            try store.setAPIKey("", for: .claude)
            message = "已清除金鑰"
        } catch { message = error.localizedDescription }
    }

    private func importServiceAccount(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            _ = try JSONDecoder().decode(GoogleServiceAccount.self, from: data)
            guard let text = String(data: data, encoding: .utf8) else { throw GoogleCloudError.invalidServiceAccount }
            geminiServiceAccountJSON = text
            geminiMessage = "已選擇 \(url.lastPathComponent)，請按儲存並測試"
        } catch {
            geminiMessage = "匯入失敗：\(error.localizedDescription)"
        }
    }

    private func saveGemini() {
        do {
            if !geminiServiceAccountJSON.isEmpty {
                try store.setAPIKey(geminiServiceAccountJSON, for: .gemini)
                hasGeminiCredential = true
                geminiServiceAccountJSON = ""
            }
            geminiBillingTable = geminiBillingTable.trimmingCharacters(in: .whitespacesAndNewlines)
            geminiMessage = "已儲存，正在測試…"
            isSavingGemini = true
            Task {
                await store.refresh(platform: .gemini)
                isSavingGemini = false
                geminiMessage = store.providerStatuses[.gemini]?.state == .success
                    ? "Gemini 同步成功" : "請查看上方同步狀態"
            }
        } catch {
            geminiMessage = error.localizedDescription
        }
    }

    private func clearGemini() {
        do {
            try store.setAPIKey("", for: .gemini)
            geminiBillingTable = ""
            geminiServiceAccountJSON = ""
            hasGeminiCredential = false
            geminiMessage = "已清除 Gemini 設定"
        } catch {
            geminiMessage = error.localizedDescription
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            message = enabled ? "已啟用登入啟動" : "已停用登入啟動"
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            message = error.localizedDescription
        }
    }
}

private struct ProviderStatusRow: View {
    let platform: CreditPlatform
    let status: ProviderSyncStatus?

    var body: some View {
        if let status {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon(for: status.state))
                    .foregroundStyle(color(for: status.state))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(platform.rawValue)：\(status.message)")
                        .font(.caption)
                        .foregroundStyle(status.state == .failed ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                    if let date = status.fetchedAt {
                        Text("檢查時間：\(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func icon(for state: ProviderSyncStatus.State) -> String {
        switch state {
        case .notConfigured: "key.slash"
        case .syncing: "arrow.triangle.2.circlepath"
        case .success: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private func color(for state: ProviderSyncStatus.State) -> Color {
        switch state {
        case .notConfigured: .secondary
        case .syncing: .blue
        case .success: .green
        case .failed: .red
        }
    }
}
