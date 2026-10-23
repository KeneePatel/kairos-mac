import Foundation

/// The date formats boards send outside JSON's ISO 8601: Workable's and BambooHR's "2026-10-19",
/// Recruitee's "2026-09-22 13:58:01 UTC", and RSS's "Fri, 24 Jul 2026 09:05:16 +0200".
enum SourceDates {
    static func parse(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
        for format in [
            "yyyy-MM-dd HH:mm:ss 'UTC'", "yyyy-MM-dd", "EEE, dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z",
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
