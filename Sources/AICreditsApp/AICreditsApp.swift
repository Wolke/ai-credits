import SwiftUI

@main
struct AICreditsApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView().environmentObject(store)
        } label: {
            if let entry = store.nearestEntry {
                Label("AI Credits · \(entry.daysUntilExpiration()) 天", systemImage: "creditcard.fill")
            } else {
                Label("AI Credits", systemImage: "creditcard")
            }
        }
        .menuBarExtraStyle(.window)

        Window("AI Credits", id: "credits") {
            CreditsWindowView().environmentObject(store)
        }
        .defaultSize(width: 820, height: 560)

        WindowGroup("新增 AI 額度", id: "new-credit") {
            CreditEditorView { entries in entries.forEach(store.upsert) }
                .environmentObject(store)
        }
        .defaultSize(width: 460, height: 430)
        .windowResizability(.contentSize)

        Window("設定", id: "settings") {
            SettingsView().environmentObject(store)
        }
        .windowResizability(.contentSize)
    }

    init() {
        Task {
            await NotificationService().requestAuthorization()
        }
    }
}
