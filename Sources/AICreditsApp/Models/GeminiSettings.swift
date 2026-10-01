import Foundation

enum GeminiSettings {
    static let billingTableKey = "geminiBillingExportTable"
    static var billingTable: String {
        UserDefaults.standard.string(forKey: billingTableKey) ?? ""
    }
}
