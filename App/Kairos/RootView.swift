import SwiftUI

/// The app's sections in sidebar order (UI v2, 2026-10-26; ADR-017): the five places you work in,
/// then the reports, then setup. Names say what a job seeker recognizes; each working section has
/// a ⌘ number.
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

    /// ⌘1 to ⌘5 for the working sections; the rest are reached from the sidebar.
    var shortcut: KeyEquivalent? {
        guard let index = Self.working.firstIndex(of: self) else { return nil }
        return KeyEquivalent(Character("\(index + 1)"))
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    private var selection: Binding<AppSection?> {
        Binding(get: { model.section }, set: { if let section = $0 { model.section = section } })
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        // 580 plus the toolbar keeps the window's minimum under the probe's 640-point limit.
        .frame(minWidth: 960, minHeight: 580)
        .alert(
            model.buildNotice?.title ?? "", isPresented: noticeShown, presenting: model.buildNotice
        ) { notice in
            if let retry = notice.retry {
                Button("Build again") { Task { _ = await model.rebuild(retry) } }
            }
            Button("Open AI settings") {
                model.settingsTab = .ai
                model.section = .settings
            }
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
    }

    /// The working sections with their counts, the reports and setup under their headers, and the
    /// status line at the bottom.
    private var sidebar: some View {
        List(selection: selection) {
            ForEach(AppSection.working) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
                    .badge(badge(section))
            }
            Section("Reports") {
                ForEach(AppSection.reports) { section in
                    Label(section.title, systemImage: section.symbol).tag(section)
                }
            }
            Section("Setup") {
                ForEach(AppSection.setup) { section in
                    Label(section.title, systemImage: section.symbol).tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 232)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.phase == .ready { StatusFooter() }
        }
    }

    @ViewBuilder private var detail: some View {
        switch (model.phase, model.section) {
        case (.opening, _):
            ProgressView()
        case (.failed(let message), _):
            ContentUnavailableView(
                "Kairos couldn't start", systemImage: "exclamationmark.triangle",
                description: Text(message).foregroundStyle(Color(.inkSecondary)))
        case (.ready, .inbox):
            JobsView(scope: .inbox)
        case (.ready, .saved):
            JobsView(scope: .saved)
        case (.ready, .skipped):
            JobsView(scope: .skipped)
        case (.ready, .improve):
            ImproveView()
        case (.ready, .filtered):
            FilteredOutView()
        case (.ready, .resumes):
            ResumesView()
        case (.ready, .applied):
            AppliedView()
        case (.ready, .interviews):
            InterviewsView()
        case (.ready, .sources):
            SourcesView()
        case (.ready, .masterResume):
            if let resume = model.resume, let ai = model.ai {
                MasterResumeView().environment(resume).environment(ai)
            }
        case (.ready, .settings):
            if let ai = model.ai {
                SettingsView().environment(ai)
            }
        case (.ready, let section):
            PlaceholderView(section: section)
        }
    }

    /// A build that failed, or a batch with something to say, wherever you are.
    private var noticeShown: Binding<Bool> {
        Binding(get: { model.buildNotice != nil }, set: { if !$0 { model.buildNotice = nil } })
    }
}

extension RootView {
    /// Inbox counts the jobs waiting for your decision, Resumes the builds under way, Interviews
    /// the applications in progress.
    func badge(_ section: AppSection) -> Int {
        switch section {
        case .inbox: model.inboxCount
        case .resumes: model.buildsUnderWay
        case .interviews: model.applications.count { $0.status.stage == .inProgress }
        default: 0
        }
    }
}

/// Stands in for each section until its slice builds the real screen.
struct PlaceholderView: View {
    let section: AppSection

    var body: some View {
        ContentUnavailableView(
            section.title,
            systemImage: section.symbol,
            description: Text("This screen comes with the next slice of the redesign.")
                .foregroundStyle(Color(.inkSecondary))
        )
        .navigationTitle(section.title)
    }
}

#Preview {
    RootView().environment(AppModel())
}
