import SwiftUI

/// The app's sections in sidebar order (SPEC §4), grouped the way the Today mockup groups them.
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case today, jobs, builds, applications
    case masterResume, sources, settings, activity

    var id: Self { self }

    static let workflow: [AppSection] = [.today, .jobs, .builds, .applications]
    static let profile: [AppSection] = [.masterResume, .sources, .settings, .activity]

    var title: String {
        switch self {
        case .today: "Today"
        case .jobs: "Jobs"
        case .builds: "Builds"
        case .applications: "Applications"
        case .masterResume: "Master resume"
        case .sources: "Sources"
        case .settings: "Settings"
        case .activity: "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .jobs: "briefcase"
        case .builds: "doc.text"
        case .applications: "paperplane"
        case .masterResume: "person.text.rectangle"
        case .sources: "antenna.radiowaves.left.and.right"
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
            case (.ready, .today):
                TodayView()
            case (.ready, .jobs):
                JobsView()
            case (.ready, .builds):
                BuildsView()
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
    }
}

extension RootView {
    /// Today counts the jobs worth a look; Jobs counts everything stored.
    func badge(_ section: AppSection) -> Int {
        switch section {
        case .today: model.todayCount(.yes) + model.todayCount(.maybe)
        case .jobs: model.jobs.count
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
