import SwiftUI

struct CreditEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entry: CreditEntry
    @State private var isMonthlySeries = false
    @State private var grantCount = 12
    @State private var validityMonths = 2
    private let isNewEntry: Bool
    let onSave: ([CreditEntry]) -> Void

    init(entry: CreditEntry = CreditEntry(), onSave: @escaping ([CreditEntry]) -> Void) {
        _entry = State(initialValue: entry)
        isNewEntry = entry.name.isEmpty && entry.originalAmount == 0 && entry.remainingAmount == 0
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("平台", selection: $entry.platform) {
                    ForEach(CreditPlatform.allCases) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: entry.platform) { old, new in
                    guard isNewEntry else { return }
                    if new == .elevenLabs && entry.unit == "USD" { entry.unit = "credits" }
                    else if old == .elevenLabs && entry.unit == "credits" { entry.unit = "USD" }
                }
                if entry.platform == .elevenLabs {
                    Text("設定 API Key 可自動建立方案 credits 與重設時間；此處新增的額度為獨立手動紀錄。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField("來源名稱（選填）", text: $entry.name, prompt: Text("例如：年度方案贈送"))
                if isNewEntry {
                    Toggle("每月定期發放", isOn: $isMonthlySeries)
                }
                if isMonthlySeries {
                    DecimalField("每月額度", value: $entry.originalAmount)
                    Stepper("發放次數：\(grantCount) 個月", value: $grantCount, in: 1...60)
                    Stepper("每筆有效期限：\(validityMonths) 個月", value: $validityMonths, in: 1...24)
                } else {
                    HStack {
                        DecimalField("原始額度", value: $entry.originalAmount)
                        DecimalField("剩餘額度", value: $entry.remainingAmount)
                    }
                }
                TextField("單位／幣別", text: $entry.unit)
                DatePicker(isMonthlySeries ? "首次發放日" : "取得日", selection: $entry.receivedAt, displayedComponents: .date)
                if !isMonthlySeries {
                    DatePicker("到期日", selection: $entry.expiresAt, displayedComponents: .date)
                } else {
                    Text("將建立 \(grantCount) 筆額度；每筆於取得日的 \(validityMonths) 個月後到期。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                TextField("備註", text: $entry.notes, axis: .vertical)
            }
            .formStyle(.grouped)
            .navigationTitle(entry.name.isEmpty ? "新增 AI 額度" : "編輯額度")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        if isMonthlySeries {
                            onSave(CreditEntry.monthlyGrantSeries(
                                from: entry,
                                count: grantCount,
                                validityMonths: validityMonths
                            ))
                        } else {
                            onSave([entry])
                        }
                        dismiss()
                    }
                        .disabled(entry.originalAmount < 0 || entry.remainingAmount < 0)
                }
            }
        }
        .frame(width: 460, height: isMonthlySeries ? 520 : 430)
    }
}

private struct DecimalField: View {
    let title: String
    @Binding var value: Decimal
    init(_ title: String, value: Binding<Decimal>) { self.title = title; _value = value }
    var body: some View {
        TextField(title, value: $value, format: .number.precision(.fractionLength(0...4)))
            .textFieldStyle(.roundedBorder)
    }
}
