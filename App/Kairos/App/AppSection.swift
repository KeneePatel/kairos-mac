import SwiftUI

/// The app's sections in sidebar order: the five places you work in, then the reports, then setup.
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case inbox, saved, resumes, applied, interviews
    case improve, filtered, skipped
    case masterResume, sources, settings

    var id: Self { self }

    static let working: [AppSection] = [.inbox, .saved, .resumes, .applied, .interviews]
    static let reports: [AppSection] = [.improve, .filtered, .skipped]
    static let setup: [AppSection] = [.masterResume, .sources, .settings]

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .saved: "Saved"
        case .resumes: "Resumes"
        case .applied: "Applied"
        case .interviews: "Interviews"
        case .improve: "Improve"
        case .filtered: "Filtered out"
        case .skipped: "Skipped"
        case .masterResume: "Master resume"
        case .sources: "Sources"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .inbox: "tray"
        case .saved: "bookmark"
        case .resumes: "doc.text"
        case .applied: "paperplane"
        case .interviews: "person.2"
        case .improve: "chart.line.uptrend.xyaxis"
        case .filtered: "line.3.horizontal.decrease"
        case .skipped: "minus.circle"
        case .masterResume: "person.text.rectangle"
        case .sources: "antenna.radiowaves.left.and.right"
        case .settings: "gearshape"
        }
    }

    /// ⌘1 to ⌘5 for the working sections.
    var shortcut: KeyEquivalent? {
        guard let index = Self.working.firstIndex(of: self) else { return nil }
        return KeyEquivalent(Character("\(index + 1)"))
    }

    /// The sections that list jobs with the job pane.
    var isJobList: Bool { [.inbox, .saved, .skipped].contains(self) }
}

/// Settings' pages.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, search, ai

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .search: "Search"
        case .ai: "AI"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .search: "magnifyingglass"
        case .ai: "sparkles"
        }
    }
}
