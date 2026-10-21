import Foundation
import Store
import UserNotifications

/// A follow-up reminder is a local notification at the time you set (T45). macOS delivers it even
/// when Kairos isn't open. Asking permission waits until the first reminder you set.
enum FollowUpReminders {
    static func identifier(_ id: UUID) -> String { "follow-up-\(id.lowercased)" }

    /// Replaces the application's reminder with its current one, if it's still ahead.
    static func schedule(_ application: Application, job: Job?) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier(application.id)])
        guard let due = application.nextActionAt, due > Date(),
            (try? await center.requestAuthorization(options: [.alert, .sound])) == true
        else { return }
        let content = UNMutableNotificationContent()
        content.title = "Follow up: \(job?.company ?? "an application")"
        content.body = application.nextAction ?? job.map { "About \($0.title)" } ?? ""
        content.sound = .default
        let when = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
        let request = UNNotificationRequest(
            identifier: identifier(application.id), content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false))
        try? await center.add(request)
    }

    static func cancel(_ id: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier(id)])
    }
}
