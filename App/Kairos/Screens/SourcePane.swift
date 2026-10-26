import AppKit
import JobSources
import Screening
import Store
import SwiftUI

/// One source beside the Sources table (UI v2): what kind of board it is and how it came, its
/// status, the open roles it has for you, what your filters dropped from it, and its history.
/// Pause, Stop watching, or change a search's keys.
struct SourcePane: View {
    @Environment(AppModel.self) private var model
    let source: Source
    var changeAdzuna: () -> Void = {}
    var openJob: (JobID) -> Void = { _ in }
    @State private var removing = false

    /// Every job Kairos got from this source, newest first.
    private var jobs: [Job] {
        model.jobs.filter { $0.sourceID == source.id }.sorted { $0.firstSeenAt > $1.firstSeenAt }
    }

    /// Judged jobs still posted: what this source has for you now.
    private var openRoles: [Job] {
        jobs.filter { $0.isOpen && $0.verdict != nil && $0.verdictSource != .prefilter && $0.state != .archived }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.space6) {
                header
                roles
                dropped
                history
            }
            .padding(.horizontal, Spacing.space7)
            .padding(.vertical, Spacing.space6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.surface))
        .confirmationDialog(
            source.isFromCatalog ? "Stop watching \(source.displayName)?" : "Remove \(source.displayName)?",
            isPresented: $removing, titleVisibility: .visible
        ) {
            Button(source.isFromCatalog ? "Stop watching" : "Remove", role: .destructive) {
                Task { await model.remove(source) }
            }
        } message: {
            Text(
                source.isFromCatalog
                    ? "Kairos stops checking its board and won't add it back from the catalog. Its jobs stay."
                    : "Kairos stops checking its board. Its jobs stay.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            Text(origin).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            Text(source.displayName).font(TypeStyle.title1).foregroundStyle(Color(.ink))
            HStack(spacing: Spacing.space2) {
                statusDot
                Text(statusLine).font(TypeStyle.callout).foregroundStyle(Color(.ink2))
            }
            HStack(spacing: Spacing.space2) {
                if let url = boardURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        ActionLabel(title: "Open board", key: "↩")
                    }
                    .help(url.host() ?? url.absoluteString)
                }
                Button {
                    Task { await model.setEnabled(!source.enabled, for: source) }
                } label: {
                    ActionLabel(title: source.enabled ? "Pause" : "Resume", key: "P")
                }
                .help(source.enabled ? "Kairos stops checking it until you resume" : "Check it again from the next run")
                if source.kind == .adzuna {
                    Button("Change keys…") { changeAdzuna() }
                }
                Button(source.isFromCatalog ? "Stop watching" : "Remove", role: .destructive) { removing = true }
            }
            .padding(.top, Spacing.space3)
        }
    }

    /// "Greenhouse board · added by you Oct 20", "from Kairos's catalog", "found behind a search".
    private var origin: String {
        let how =
            switch BoardConfig.decode(source.config)?.origin {
            case "catalog"?: "from Kairos's catalog"
            case "search"?: "found behind a search snippet"
            default: "added by you"
            }
        switch source.kind {
        case .adzuna, .himalayas, .googleJobs: return "A search for your roles · \(how)"
        default: return "\(source.kind.displayName) board · \(how)"
        }
    }

    @ViewBuilder private var statusDot: some View {
        if !source.enabled {
            Circle().fill(Color(.inkSecondary)).frame(width: 8, height: 8).accessibilityHidden(true)
        } else if model.failures[source.id] != nil || source.health == .gone {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(.error)).font(TypeStyle.caption)
                .accessibilityHidden(true)
        } else {
            Circle().fill(Color(.yes)).frame(width: 8, height: 8).accessibilityHidden(true)
        }
    }

    /// "Active · checked 12:39 AM · 62 postings on the board, 1 open role for you".
    private var statusLine: String {
        var parts: [String] = []
        if !source.enabled {
            parts.append("Paused by you")
        } else if let failure = model.failures[source.id] {
            parts.append("Can't reach · \(failure)")
        } else if source.health == .gone {
            parts.append("Gone · the board answered \"not found\" three times")
        } else if source.lastRunAt == nil {
            parts.append("Not checked yet")
        } else {
            parts.append("Active")
        }
        if let checked = source.lastRunAt { parts.append("checked \(SourcesTable.checked(checked))") }
        if source.lastRunAt != nil {
            let found = jobs.count
            parts.append(
                "\(found) posting\(found == 1 ? "" : "s") kept, \(openRoles.count) open role\(openRoles.count == 1 ? "" : "s") for you"
            )
        }
        return parts.joined(separator: " · ")
    }

    /// The board's page, from the newest job's link: the host, plus the company's path on a
    /// multi-tenant host such as boards.greenhouse.io.
    private var boardURL: URL? {
        guard let first = jobs.first, let url = URL(string: first.url), let host = url.host(),
            let scheme = url.scheme
        else { return nil }
        let multiTenant = ["greenhouse.io", "lever.co", "ashbyhq.com", "smartrecruiters.com", "workable.com"]
        let path = url.path().split(separator: "/").first.map { "/\($0)" } ?? ""
        let keepPath = multiTenant.contains { host.hasSuffix($0) }
        return URL(string: "\(scheme)://\(host)\(keepPath ? path : "")")
    }

    // MARK: - Sections

    @ViewBuilder private var roles: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Open roles for you").font(TypeStyle.title2).foregroundStyle(Color(.ink))
                Spacer()
                Text(
                    source.lastRunAt == nil
                        ? "Not checked yet"
                        : "\(openRoles.count) of \(jobs.count) passed your filters"
                )
                .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).monospacedDigit()
            }
            if openRoles.isEmpty {
                Text(source.lastRunAt == nil ? "Find new jobs checks this board." : "Nothing open for you right now.")
                    .font(TypeStyle.body).foregroundStyle(Color(.inkSecondary))
            } else {
                ForEach(openRoles.prefix(12)) { job in
                    Button {
                        openJob(job.id)
                    } label: {
                        JobRow(
                            job: job, reason: model.screening(for: job)?.reasons.first,
                            score: model.matchScore(for: job), hasResume: model.latestBuild(for: job) != nil,
                            dimmed: job.verdict == .no || model.isActedOn(job))
                    }
                    .buttonStyle(.plain)
                }
                if openRoles.count > 12 {
                    Text("and \(openRoles.count - 12) more in the Inbox").font(TypeStyle.callout)
                        .foregroundStyle(Color(.inkSecondary))
                }
            }
        }
    }

    /// What the filters dropped from this board, by reason.
    @ViewBuilder private var dropped: some View {
        let counts = Dictionary(grouping: jobs.filter { $0.verdictSource == .prefilter }) { model.filterRule(of: $0) }
            .compactMap { rule, members in rule.map { ($0, members.count) } }
            .sorted { $0.1 > $1.1 }
        if !counts.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.space2) {
                Text("What the filters dropped here").font(TypeStyle.title2).foregroundStyle(Color(.ink))
                Text(
                    counts.map { "\($0.0.reason) \($0.1)" }.joined(separator: " · ")
                        + " · change them in Settings, Search"
                )
                .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).fixedSize(
                    horizontal: false, vertical: true)
            }
        }
    }

    private var history: some View {
        let applied = jobs.count { $0.state == .applied }
        let built = jobs.count { model.latestBuild(for: $0) != nil }
        var parts: [String] = []
        if let first = jobs.map(\.firstSeenAt).min() {
            parts.append("First job seen \(first.formatted(.dateTime.month(.abbreviated).day()))")
        }
        parts.append("\(jobs.count) job\(jobs.count == 1 ? "" : "s") in all")
        if built > 0 { parts.append("\(built) with a resume") }
        if applied > 0 { parts.append("\(applied) you applied to") }
        if source.emptyRuns > 0 {
            parts.append("\(source.emptyRuns) check\(source.emptyRuns == 1 ? "" : "s") with nothing new")
        }
        return VStack(alignment: .leading, spacing: Spacing.space2) {
            Text("History").font(TypeStyle.title2).foregroundStyle(Color(.ink))
            Text(parts.joined(separator: " · ")).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
