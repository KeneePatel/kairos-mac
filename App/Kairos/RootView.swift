import SwiftUI

/// The app's sections in sidebar order (polish P3; reworked 2026-10-22): the workflow, from finding
/// jobs to reviewing the ones that passed your filters, what would widen your reach (Improve), the
/// filtered-out ones apart, resumes and applications, then your profile. Names say what a job
/// seeker recognizes.
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case fetch, review, improve, filtered, builds, applications
    case masterResume, settings, activity

    var id: Self { self }

    static let workflow: [AppSection] = [.fetch, .review, .improve, .filtered, .builds, .applications]
    static let profile: [AppSection] = [.masterResume, .settings, .activity]

    var title: String {
        switch self {
        case .fetch: "Find jobs"
        case .review: "Review"
        case .improve: "Improve"
        case .filtered: "Filtered out"
        case .builds: "Resumes"
        case .applications: "Applications"
        case .masterResume: "Master resume"
        case .settings: "Settings"
        case .activity: "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .fetch: "arrow.down.circle"
        case .review: "checklist"
        case .improve: "chart.line.uptrend.xyaxis"
        case .filtered: "line.3.horizontal.decrease.circle"
        case .builds: "doc.text"
        case .applications: "paperplane"
        case .masterResume: "person.text.rectangle"
        case .settings: "gearshape"
        case .activity: "clock.arrow.circlepath"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    private var selection: Binding<AppSection?> {
        Binding(get: { model.section }, set: { if let section = $0 { model.section = section } })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                ForEach(AppSection.workflow) { section in
                    Label(section.title, systemImage: section.symbol).tag(section)
                        .badge(badge(section))
                }
                Section("Profile") {
                    ForEach(AppSection.profile) { section in
                        Label(section.title, systemImage: section.symbol).tag(section)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 232)
        } detail: {
            switch (model.phase, model.section) {
            case (.opening, _):
                ProgressView()
            case (.failed(let message), _):
                ContentUnavailableView(
                    "Kairos couldn't start", systemImage: "exclamationmark.triangle",
                    description: Text(message).foregroundStyle(Color(.inkSecondary)))
            case (.ready, .fetch):
                FetchView()
            case (.ready, .review):
                ReviewView()
            case (.ready, .improve):
                ImproveView()
            case (.ready, .filtered):
                FilteredOutView()
            case (.ready, .builds):
                BuildsView()
            case (.ready, .applications):
                ApplicationsView()
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
    }
}

extension RootView {
    /// Review counts the jobs worth a look; Filtered out, the jobs your filters dropped.
    func badge(_ section: AppSection) -> Int {
        switch section {
        case .review: model.reviewCount(.yes) + model.reviewCount(.maybe)
        case .filtered: model.filteredCount
        default: 0
        }
    }
}

/// Stands in for each section until its task builds the real screen.
struct PlaceholderView: View {
    let section: AppSection

    var body: some View {
        ContentUnavailableView(
            section.title,
            systemImage: section.symbol,
            description: Text("This screen isn't built yet.").foregroundStyle(Color(.inkSecondary))
        )
        .navigationTitle(section.title)
    }
}

#Preview {
    RootView().environment(AppModel())
}
