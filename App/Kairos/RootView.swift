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
    @State private var selection: AppSection? = .today

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(AppSection.workflow) { section in
                    Label(section.title, systemImage: section.symbol).tag(section)
                }
                Section("Profile") {
                    ForEach(AppSection.profile) { section in
                        Label(section.title, systemImage: section.symbol).tag(section)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 232)
        } detail: {
            if let selection {
                PlaceholderView(section: selection)
            } else {
                PlaceholderView(section: .today)
            }
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
            description: Text("This screen isn't built yet.")
        )
        .navigationTitle(section.title)
    }
}

#Preview {
    RootView()
}
