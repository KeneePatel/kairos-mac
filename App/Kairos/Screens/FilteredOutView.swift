import Screening
import Store
import SwiftUI

/// Filtered out (UI v2): the jobs your filters dropped before any AI call, apart from the Inbox.
/// Reasons on the left with their counts, under All; the chosen reason's jobs on the right with
/// its setting one click away; Bring back on each job sends it to the Inbox to be judged like any
/// other, and the filters never drop it again. Re-check filters applies your current filters to
/// every job without spending AI calls.
struct FilteredOutView: View {
    /// A row of the reasons list: All, or one rule.
    enum Reason: Hashable {
        case all
        case rule(PrefilterRule)
    }

    @Environment(AppModel.self) private var model
    @State private var choice: Reason? = .all
    @State private var path: [JobID] = []
    @State private var selection: JobID?
    @State private var message: String?

    /// The chosen rule; nil for All.
    private var rule: PrefilterRule? {
        if case .rule(let rule)? = choice { return rule }
        return nil
    }

    var body: some View {
        NavigationStack(path: $path) {
            ListPaneLayout(listWidth: 300) {
                reasons
            } pane: {
                jobs
            }
            .navigationTitle("Filtered out")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.recheckFilters()
                    } label: {
                        Label("Re-check filters · no AI calls", systemImage: "arrow.triangle.2.circlepath")
                            .labelStyle(.titleOnly)
                    }
                    .disabled(model.isFetching || model.jobs.isEmpty)
                    .help(
                        "Applies your current filters to every job, with no AI calls. Jobs they now let through go to the Inbox."
                    )
                }
            }
            .navigationDestination(for: JobID.self) { JobScreen(id: $0) }
        }
        .onChange(of: selection) { _, id in
            guard let id else { return }
            path.append(id)
            selection = nil
        }
        .alert("Brought back", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    /// Every reason with its count, most first, under All.
    private var reasons: some View {
        VStack(spacing: 0) {
            ColumnTitle(
                title: "Filtered out",
                line:
                    "\(model.filteredCount.formatted()) job\(model.filteredCount == 1 ? "" : "s") your filters dropped before any AI call"
            )
            if model.filteredCount == 0 {
                EmptyState(
                    "Nothing filtered out",
                    "Jobs your settings rule out (titles, level, countries, French and more) appear here, by reason.")
            } else {
                List(selection: $choice) {
                    row("All", count: model.filteredCount).tag(Reason.all)
                    ForEach(model.filteredReasons, id: \.rule) { reason in
                        row(reason.rule.reason, count: reason.count).tag(Reason.rule(reason.rule))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func row(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(TypeStyle.body).foregroundStyle(Color(.ink)).lineLimit(1)
            Spacer()
            Text(count.formatted()).font(TypeStyle.callout).monospacedDigit().foregroundStyle(Color(.inkSecondary))
        }
        .frame(height: 32)
        .listRowInsets(EdgeInsets(top: 0, leading: Spacing.space4, bottom: 0, trailing: Spacing.space4))
    }

    /// The chosen reason's jobs: its title and setting, the link to change it, then the table.
    @ViewBuilder private var jobs: some View {
        if model.filteredCount == 0 {
            EmptyState("Nothing to show", "Find new jobs fills this once your filters have dropped something.")
        } else {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.space4) {
                    VStack(alignment: .leading, spacing: Spacing.space1) {
                        Text("\(rule?.reason ?? "All") · \(model.filteredJobs(rule).count.formatted())")
                            .font(TypeStyle.title1).foregroundStyle(Color(.ink))
                        Text(setting(for: rule)).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                            .lineLimit(2)
                    }
                    Spacer()
                    if let rule {
                        Button(rule == .postingAge ? "Change in Sources" : "Change in Settings") {
                            if rule == .postingAge {
                                model.section = .sources
                            } else {
                                model.settingsTab = .search
                                model.section = .settings
                            }
                        }
                    }
                }
                .padding(.horizontal, Spacing.space7)
                .padding(.top, Spacing.space6)
                .padding(.bottom, Spacing.space4)
                Divider()
                table
                Divider()
                Text(
                    "A job you bring back goes to the Inbox to be judged like any other, and these filters never drop it again."
                )
                .font(TypeStyle.caption).foregroundStyle(Color(.inkSecondary)).lineLimit(1)
                .padding(.horizontal, Spacing.space7).padding(.vertical, Spacing.space3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var table: some View {
        Table(model.filteredJobs(rule), selection: $selection) {
            TableColumn("Role") { job in
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title).font(TypeStyle.headline).foregroundStyle(Color(.ink)).lineLimit(1)
                    Text(
                        rule == nil
                            ? "\(job.company) · \(model.filterRule(of: job)?.reason ?? "Other reasons")" : job.company
                    )
                    .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).lineLimit(1)
                }
                .padding(.vertical, Spacing.space1)
            }
            .width(min: 240, ideal: 400)
            TableColumn("Location") { job in
                Text(job.placeLabel).foregroundStyle(Color(.inkSecondary)).lineLimit(1)
            }
            .width(min: 100, ideal: 150)
            TableColumn("Found") { job in
                Text(job.firstSeenAt.formatted(.relative(presentation: .named))).foregroundStyle(Color(.inkSecondary))
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 100)
            TableColumn("") { job in
                Button("Bring back") {
                    Task { message = await model.bringBack(job) }
                }
                .help("Sends it to the Inbox to be judged like any other. Your filters won't drop it again.")
            }
            .width(min: 90, ideal: 100)
        }
    }

    /// The setting behind a reason, in words.
    private func setting(for rule: PrefilterRule?) -> String {
        let preferences = model.searchPreferences
        func list(_ items: [String], none: String) -> String { items.isEmpty ? none : items.joined(separator: ", ") }
        switch rule {
        case nil: return "Every job your filters removed, newest first. Choose a reason to see its setting."
        case .titleInclude?:
            let roles = RoleFamily.allCases.filter(preferences.roles.contains).map(\.title)
            return roles.isEmpty
                ? "Your titles: " + list(preferences.titleInclude, none: "none set")
                : "Your roles: " + roles.joined(separator: "; ") + ". Other titles: "
                    + list(preferences.titleInclude, none: "none")
        case .titleExclude?: return "Titles you skip: " + list(preferences.titleExclude, none: "none set")
        case .seniority?:
            let off = Seniority.allCases.filter { !preferences.seniority.contains($0) }.map(\.title)
            return "Levels you've turned off: " + list(off, none: "none")
        case .yearsRequired?:
            return preferences.maxYearsRequired.map { "Your limit: jobs asking for \($0) years or fewer" }
                ?? "No years limit set"
        case .location?:
            return "Your countries and regions: " + list(preferences.countries.map(\.displayName), none: "none")
        case .remoteScope?: return "Remote jobs open only to people elsewhere"
        case .workAuthorization?: return "Your work authorization, in Settings, Search"
        case .clearance?: return "Jobs that need a security clearance you don't hold"
        case .french?: return "Jobs that need French, which isn't among your languages"
        case .blacklist?: return "Companies you've blocked: " + list(preferences.blacklist, none: "none")
        case .postingAge?: return "Older than your Posted limit, from before the limit applied while fetching"
        case .alreadyApplied?: return "Close matches to jobs you've applied to"
        }
    }
}

extension PrefilterRule {
    /// Why the prefilter dropped a job, as a list label.
    var reason: String {
        switch self {
        case .titleInclude: "Not one of your roles"
        case .titleExclude: "Title you skip"
        case .seniority: "Level you've turned off"
        case .yearsRequired: "Asks for too many years"
        case .location: "Outside your countries or regions"
        case .remoteScope: "Remote only elsewhere"
        case .workAuthorization: "Work authorization"
        case .clearance: "Needs a security clearance"
        case .french: "Needs French"
        case .blacklist: "Company you've blocked"
        case .postingAge: "Older than your limit"
        case .alreadyApplied: "Already applied"
        }
    }
}
