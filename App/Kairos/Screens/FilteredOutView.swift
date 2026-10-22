import Screening
import Store
import SwiftUI

/// Filtered out (2026-10-22): the jobs your filters dropped before any AI call, apart from Review.
/// Reasons on the left, with All; the setting behind the chosen reason one click away; Bring back
/// on each job sends it to Review to be judged like any other, and the filters never drop it again.
/// Re-check filters applies your current filters to every job without spending AI calls.
struct FilteredOutView: View {
    /// A row of the reasons list: All, or one rule.
    enum Reason: Hashable {
        case all
        case rule(PrefilterRule)
    }

    @Environment(AppModel.self) private var model
    @State private var choice: Reason? = .all

    /// The chosen rule; nil for All.
    private var rule: PrefilterRule? {
        if case .rule(let rule)? = choice { return rule }
        return nil
    }
    @State private var path: [JobID] = []
    @State private var selection: JobID?
    @State private var message: String?

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Filtered out")
                .navigationSubtitle("\(model.filteredCount) jobs your filters removed before any AI call")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.recheckFilters()
                        } label: {
                            Label("Re-check filters", systemImage: "arrow.triangle.2.circlepath")
                                .labelStyle(.titleAndIcon)
                        }
                        .disabled(model.isFetching || model.jobs.isEmpty)
                        .help(
                            "Applies your current filters to every job, with no AI calls. Jobs they now let through go to Review."
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

    @ViewBuilder private var content: some View {
        if model.filteredCount == 0 {
            ContentUnavailableView {
                Label("Nothing filtered out", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Jobs your settings rule out (titles, level, countries, French and more) appear here, by reason.")
                    .foregroundStyle(Color(.inkSecondary))
            }
        } else {
            HStack(spacing: 0) {
                reasons.frame(width: 250)
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    ruleBar
                    Divider()
                    table
                }
            }
        }
    }

    /// Every reason with its count, most first, under All.
    private var reasons: some View {
        List(selection: $choice) {
            row("All", count: model.filteredCount).tag(Reason.all)
            ForEach(model.filteredReasons, id: \.rule) { reason in
                row(reason.rule.reason, count: reason.count).tag(Reason.rule(reason.rule))
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).foregroundStyle(Color(.ink))
            Spacer()
            Text(count.formatted()).monospacedDigit().foregroundStyle(Color(.inkSecondary))
        }
    }

    /// What the chosen reason is about, and where to change it.
    private var ruleBar: some View {
        HStack(spacing: Spacing.space3) {
            Text(setting(for: rule)).font(TypeStyle.callout).foregroundStyle(Color(.ink2)).lineLimit(2)
            Spacer()
            Button(rule == .postingAge ? "Change in Find jobs" : "Change in Settings") {
                if rule == .postingAge {
                    model.section = .fetch
                } else {
                    model.settingsTab = .search
                    model.section = .settings
                }
            }
            .buttonStyle(.link)
        }
        .padding(.horizontal, Spacing.space4).padding(.vertical, Spacing.space3)
        .background(Color(.surfaceGrouped))
    }

    private var table: some View {
        Table(model.filteredJobs(rule), selection: $selection) {
            TableColumn("Role") { job in
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title).font(TypeStyle.headline).foregroundStyle(Color(.ink))
                    Text(
                        rule == nil
                            ? "\(job.company) · \(model.filterRule(of: job)?.reason ?? "Other reasons")" : job.company
                    )
                    .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).lineLimit(1)
                }
                .padding(.vertical, Spacing.space1)
            }
            .width(min: 260, ideal: 420)
            TableColumn("Location") { job in Text(job.placeLabel).foregroundStyle(Color(.inkSecondary)) }
                .width(min: 110, ideal: 150)
            TableColumn("Found") { job in
                Text(job.firstSeenAt.formatted(.relative(presentation: .named))).foregroundStyle(Color(.inkSecondary))
            }
            .width(min: 90, ideal: 110)
            TableColumn("") { job in
                Button("Bring back") {
                    Task { message = await model.bringBack(job) }
                }
                .help("Sends it to Review to be judged like any other. Your filters won't drop it again.")
            }
            .width(min: 100, ideal: 110)
        }
    }

    /// The setting behind a reason, in words.
    private func setting(for rule: PrefilterRule?) -> String {
        let preferences = model.searchPreferences
        func list(_ items: [String], none: String) -> String { items.isEmpty ? none : items.joined(separator: ", ") }
        switch rule {
        case nil: return "Every job your filters removed, newest first. Choose a reason to see its setting."
        case .titleInclude?: return "Your titles: " + list(preferences.titleInclude, none: "none set")
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
