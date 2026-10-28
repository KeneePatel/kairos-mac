import Engine
import Screening
import Store
import SwiftUI

/// Improve: what keeps your Maybe and No jobs from a Yes, as fixes ranked by the verdicts each
/// could move, with where your master resume stands. A report: it changes nothing, and each job
/// opens in the Inbox.
struct ImproveView: View {
    @Environment(AppModel.self) private var model
    @State private var report: ImproveReport?
    @State private var choice: String?

    var body: some View {
        ListPaneLayout(listWidth: 380) {
            VStack(spacing: 0) {
                ColumnTitle(title: "Improve", line: line)
                List(selection: $choice) {
                    if let report {
                        Section {
                            ForEach(report.fixes.prefix(40)) { fix in
                                HStack {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(fix.title).font(TypeStyle.headline).lineLimit(1)
                                        Text(Self.standing(fix.standing)).font(TypeStyle.callout)
                                            .foregroundStyle(Color(.inkSecondary)).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(fix.toYes > 0 ? "+\(fix.toYes) yes" : "\(fix.jobs.count) jobs")
                                        .font(TypeStyle.callout.weight(.semibold)).monospacedDigit()
                                        .foregroundStyle(fix.toYes > 0 ? Color(.yes) : Color(.inkSecondary))
                                }
                                .frame(height: Spacing.rowHeightComfortable)
                                .tag(fix.id)
                            }
                        } header: {
                            GroupHeader(title: "Fixes", count: report.fixes.count)
                        }
                        if !report.held.isEmpty {
                            Section {
                                ForEach(report.held) { held in
                                    HStack {
                                        Text(Self.title(held.rule)).font(TypeStyle.body)
                                        Spacer()
                                        Text("\(held.jobs.count)").font(TypeStyle.callout).monospacedDigit()
                                            .foregroundStyle(Color(.inkSecondary))
                                    }
                                    .tag("held:\(held.rule.rawValue)")
                                }
                            } header: {
                                GroupHeader(title: "No resume changes these")
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .overlay {
                    if report == nil {
                        ProgressView().controlSize(.small)
                    } else if report?.fixes.isEmpty == true, report?.held.isEmpty == true {
                        EmptyState(
                            "Nothing to improve yet",
                            "Once the AI has judged some Maybe and No jobs, the asks they share appear here.")
                    }
                }
            }
        } pane: {
            if let fix = report?.fixes.first(where: { $0.id == choice }) {
                FixPane(fix: fix)
            } else if let held = report?.held.first(where: { "held:\($0.rule.rawValue)" == choice }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.space4) {
                        Text(Self.title(held.rule)).font(TypeStyle.title1)
                        Text(
                            "These jobs were decided by something your resume can't change. Your settings decide them: change Search or General if they should count."
                        )
                        .font(TypeStyle.body).foregroundStyle(Color(.inkSecondary))
                        JobLinks(ids: held.jobs)
                    }
                    .padding(Spacing.space7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                EmptyState("Choose a fix", "Each one shows what the jobs ask and where your master resume stands.")
            }
        }
        .navigationTitle("Improve")
        .task(id: model.jobs) { await load() }
    }

    private var line: String {
        guard let report else { return "Reading your Maybe and No jobs…" }
        return "\(report.analysed) Maybe and No jobs analysed · \(report.fixes.count) fixes"
    }

    private func load() async {
        guard let store = model.workspace?.store else { return }
        let judged = model.jobs.filter { $0.screening?.stage == .judged && $0.verdict != .yes }
        let ids = judged.map(\.id)
        let analyses = (try? await store.screening.analyses(for: ids)) ?? [:]
        let details = Dictionary(((try? await store.jobs.jobs(ids)) ?? []).map { ($0.id, $0) }) { first, _ in first }
        report = ImproveReport(
            jobs: judged, analyses: analyses, details: details, resume: model.resume, preferences: model.preferences,
            profile: model.workProfile)
        if choice == nil { choice = report?.fixes.first?.id }
    }

    static func standing(_ standing: ImproveReport.Standing) -> String {
        switch standing {
        case .proven(let name): "In your skills as Proven: \(name)"
        case .canDiscuss(let name): "Can discuss: \(name)"
        case .mentioned(let place): "Mentioned in \(place)"
        case .absent: "Not on your resume"
        }
    }

    static func title(_ rule: VerdictRule) -> String {
        switch rule {
        case .workAuthorization: "Work authorization"
        case .remoteScope: "Remote where you'd need a visa"
        case .clearance: "Security clearance"
        case .french: "French required"
        case .enrolment: "Students or graduates only"
        case .seniority: "A level you turned off"
        case .yearsRequired: "More years than your limit"
        case .yearsAboveYours: "More years than yours"
        case .strongMatch, .partialMatch, .weakMatch, .noRequirements, .snippetOnly: "How much your resume shows"
        }
    }
}

struct FixPane: View {
    let fix: ImproveReport.Fix

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.space6) {
                VStack(alignment: .leading, spacing: Spacing.space1) {
                    Text(fix.title).font(TypeStyle.title1)
                    Text(ImproveView.standing(fix.standing)).font(TypeStyle.callout).foregroundStyle(
                        Color(.inkSecondary))
                }
                Card {
                    HStack(spacing: Spacing.space6) {
                        stat("\(fix.toYes)", "could become Yes")
                        stat("\(fix.toMaybe)", "No could become Maybe")
                        stat("\(fix.jobs.count)", "jobs ask for it")
                    }
                }
                PaneSection(title: "What to do") {
                    Text(advice).font(TypeStyle.body).foregroundStyle(Color(.ink2)).fixedSize(
                        horizontal: false, vertical: true)
                }
                PaneSection(title: "What the jobs ask") {
                    ForEach(Array(Set(fix.asks)).sorted().prefix(12), id: \.self) { ask in
                        Text("“\(ask)”").font(TypeStyle.body).foregroundStyle(Color(.ink2))
                    }
                }
                PaneSection(title: "The jobs") { JobLinks(ids: fix.jobs) }
            }
            .padding(Spacing.space7)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var advice: String {
        switch fix.standing {
        case .proven(let name):
            "\(name) is in your skills, but no bullet shows it. Add a bullet that says what you did with it, with a number if you have one."
        case .canDiscuss(let name):
            "\(name) is a Can discuss skill. If your work shows it, make it Proven and add a bullet; otherwise Stretch mode can list it as something to be ready to discuss."
        case .mentioned(let place):
            "Your \(place) entry mentions it. Add it to your skills as Proven if that's fair, and make the bullet say it plainly."
        case .absent:
            "Your master resume doesn't show it. If you've used it, add a bullet where you did; if not, these jobs are a stretch."
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(TypeStyle.score)
            Text(label).font(TypeStyle.caption).foregroundStyle(Color(.inkSecondary))
        }
    }
}

/// Jobs by id, each opening in the Inbox.
struct JobLinks: View {
    let ids: [String]
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            ForEach(ids.prefix(30), id: \.self) { id in
                if let job = model.summary(id) {
                    Button {
                        model.selectedJob = id
                        model.section = job.decision == .skipped ? .skipped : job.decision == .saved ? .saved : .inbox
                    } label: {
                        HStack {
                            if let verdict = job.verdict { VerdictPill(verdict: verdict) }
                            Text("\(job.title) · \(job.company)").font(TypeStyle.body).foregroundStyle(Color(.ink))
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
