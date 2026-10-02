import AppKit
import SwiftUI

// All preview values are synthetic. Never open the user's persistence or Keychain.
private struct DemoCredentials: CredentialStore {
    func get(for platform: CreditPlatform, allowInteraction: Bool) throws -> String? { nil }
    func set(_ value: String, for platform: CreditPlatform) throws {}
    func delete(for platform: CreditPlatform) throws {}
}

@main
struct DemoPreview {
    @MainActor static func main() throws {
        precondition(CommandLine.arguments.count == 2, "Pass an output PNG path")
        NSApplication.shared.setActivationPolicy(.prohibited)
        let demoRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: demoRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: demoRoot) }
        let persistence = PersistenceService(fileURL: demoRoot.appendingPathComponent("demo.json"))
        let today = Calendar.current.startOfDay(for: .now)
        func date(_ days: Int) -> Date { Calendar.current.date(byAdding: .day, value: days, to: today)! }
        let claude = CreditEntry(platform: .claude, name: "示範開發專案", originalAmount: 500,
                                 remainingAmount: 325, receivedAt: date(-30), expiresAt: date(14), lastSyncedAt: .now)
        let openAI = CreditEntry(platform: .openAI, name: "示範贈送額度", originalAmount: 1000,
                                 remainingAmount: 740, receivedAt: date(-30), expiresAt: date(45), lastSyncedAt: .now)
        let eleven = CreditEntry(platform: .elevenLabs, name: "示範語音方案", originalAmount: 100000,
                                 remainingAmount: 65000, unit: "credits", receivedAt: date(-15), expiresAt: date(15),
                                 lastSyncedAt: .now, isSubscriptionBalance: true, subscriptionResetsAt: date(15))
        var data = AppData(entries: [claude, openAI, eleven])
        data.elevenLabsUSDValuation = ElevenLabsUSDValuation(credits: 100000, usd: 20)
        try persistence.save(data)
        let store = AppStore(persistence: persistence, keychain: DemoCredentials(), automaticallyRefresh: false)
        let host = NSHostingView(rootView: MenuContentView().environmentObject(store)
            .environment(\.locale, Locale(identifier: "zh_TW"))
            .environment(\.colorScheme, .light).background(Color.white))
        host.appearance = NSAppearance(named: .aqua)
        let size = host.fittingSize
        precondition(size.width == 380 && size.height >= 500, "Unexpected menu size: \(size)")
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Cannot render preview") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode preview") }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("Rendered synthetic demo: \(Int(size.width)) × \(Int(size.height)) points")
    }
}
