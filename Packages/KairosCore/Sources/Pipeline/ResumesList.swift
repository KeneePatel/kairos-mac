import Foundation
import Tailoring

/// The Resumes list (UI v2): every build, the ones under way first, then by the day they were
/// started. Pure, so the grouping is tested.
public enum ResumesList {
    public enum GroupKind: String, Sendable, CaseIterable, Identifiable {
        case building, today, yesterday, earlier
        public var id: Self { self }

        public var title: String {
            switch self {
            case .building: "Building"
            case .today: "Today"
            case .yesterday: "Yesterday"
            case .earlier: "Earlier"
            }
        }
    }

    public struct Group: Identifiable, Equatable, Sendable {
        public let kind: GroupKind
        public let builds: [BuildRecord]
        public var id: GroupKind { kind }

        public init(kind: GroupKind, builds: [BuildRecord]) {
            self.kind = kind
            self.builds = builds
        }
    }

    /// `builds` in four groups, newest first within each; empty groups are left out. Queued and
    /// running builds are Building whatever their day.
    public static func groups(
        _ builds: [BuildRecord], now: Date = Date(), calendar: Calendar = .current
    ) -> [Group] {
        var byKind: [GroupKind: [BuildRecord]] = [:]
        for build in builds {
            let kind: GroupKind =
                switch build.status {
                case .queued, .running: .building
                case .done, .failed:
                    calendar.isDate(build.createdAt, inSameDayAs: now)
                        ? .today : calendar.isDateInYesterday(build.createdAt, relativeTo: now) ? .yesterday : .earlier
                }
            byKind[kind, default: []].append(build)
        }
        return GroupKind.allCases.compactMap { kind in
            guard let members = byKind[kind], !members.isEmpty else { return nil }
            return Group(kind: kind, builds: members.sorted { $0.createdAt > $1.createdAt })
        }
    }

    /// "2 building · 9 today · 48 this week".
    public static func summary(_ builds: [BuildRecord], now: Date = Date(), calendar: Calendar = .current) -> String {
        let building = builds.count { $0.status == .queued || $0.status == .running }
        let today = builds.count { calendar.isDate($0.createdAt, inSameDayAs: now) }
        let week = builds.count { now.timeIntervalSince($0.createdAt) < 7 * 86_400 }
        var parts: [String] = []
        if building > 0 { parts.append("\(building) building") }
        parts.append("\(today) today")
        parts.append("\(week) this week")
        return parts.joined(separator: " · ")
    }
}

extension Calendar {
    /// Yesterday relative to `now`, not to the wall clock, so the grouping is testable.
    fileprivate func isDateInYesterday(_ date: Date, relativeTo now: Date) -> Bool {
        guard let yesterday = self.date(byAdding: .day, value: -1, to: now) else { return false }
        return isDate(date, inSameDayAs: yesterday)
    }
}
