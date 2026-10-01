import Foundation
import UserNotifications

struct NotificationService: Sendable {
    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func sendExpirationNotification(for entry: CreditEntry, days: Int) async {
        let content = UNMutableNotificationContent()
        content.title = days == 0 ? "AI 點數今天到期" : "AI 點數即將到期"
        content.body = "\(entry.platform.rawValue) · \(entry.name) 剩下 \(entry.remainingAmount.formatted()) \(entry.unit)，\(days == 0 ? "今天到期" : "還有 \(days) 天")。"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "credit-\(entry.id)-\(days)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

enum NotificationMilestone {
    static func stage(forDaysRemaining days: Int) -> Int? {
        if days < 0 { return nil }
        if days == 0 { return 0 }
        if days <= 1 { return 1 }
        if days <= 7 { return 7 }
        if days <= 30 { return 30 }
        return nil
    }
}

extension Decimal {
    func formatted() -> String {
        let number = NSDecimalNumber(decimal: self)
        return number.decimalValue.formatted(.number.precision(.fractionLength(0...2)))
    }
}
