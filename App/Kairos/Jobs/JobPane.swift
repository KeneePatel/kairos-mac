import AppKit
import Engine
import Jobs
import Screening
import Store
import SwiftUI
import Tailoring

/// One job: its title and the decisions with their keys, the verdict card, what the posting asks
/// for and whether your master resume shows it, where it's posted, and the posting itself.
struct JobPane: View {
    let id: String
    @Environment(AppModel.self) private var model
    @State private var detail: JobDetail?
    @State private var profile: ScreeningProfile?

    var body: some View {
        ScrollView {
            if let detail {
                VStack(alignment: .leading, spacing: Spacing.space6) {
                    header(detail.job)
                    verdictCard(detail)
                    if let analysis = detail.analysis { requirements(analysis) }
                    whereItsPosted(detail)
                    PaneSection(title: "The posting") {
                        if detail.job.description.isEmpty {
                            Text("Kairos keeps no text for this job; open the posting to read it.")
                                .font(TypeStyle.body).foregroundStyle(Color(.inkSecondary))
                        } else {
                            MarkdownView(detail.job.description)
                        }
                    }
                }
                .padding(Spacing.space7)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: Reload(id: id, summary: model.summary(id))) {
            detail = try? await model.workspace?.store.jobs.detail(id)
        }
        .task(id: model.resume.version) { profile = ScreeningProfile(model.resume) }
    }

    /// The pane reads the job again when its row changes (a decision, a verdict, a build).
    struct Reload: Equatable {
        let id: String
        let summary: JobSummary?
    }

    private var summary: JobSummary? { model.summary(id) }

    // MARK: - Header and decisions

    private func header(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            VStack(alignment: .leading, spacing: Spacing.space1) {
                Text(job.title).font(TypeStyle.title1).foregroundStyle(Color(.ink)).textSelection(.enabled)
                Text(meta(job)).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            }
            HStack(spacing: Spacing.space2) {
                buildButton
                Button {
                    model.toggleSave(job.id)
                } label: {
                    ActionLabel(title: summary?.decision == .saved ? "Saved" : "Save", key: "S")
                }
                Button {
                    model.skip(job.id)
                } label: {
                    ActionLabel(title: summary?.decision == .skipped ? "Bring back" : "Skip", key: "X")
                }
                Button {
                    model.openPosting(job.id)
                } label: {
                    ActionLabel(title: "Open posting", key: "O")
                }
                Spacer()
                Menu {
                    Button("Build with a cover letter") { model.build(job.id, letter: true) }
                    Button("Build Lite: your words, best order") { model.build(job.id, mode: .lite) }
                    if model.stretch.enabled {
                        Button("Build Stretch: with gap bullets") { model.build(job.id, mode: .stretch) }
                    }
                    Divider()
                    Button("Mark applied") { model.markApplied(job.id) }
                    Menu("Your verdict") {
                        ForEach(Verdict.allCases, id: \.self) { verdict in
                            Button(verdict.title) { model.setVerdict(verdict, for: job.id) }
                        }
                        if summary?.screening?.yourVerdict != nil {
                            Divider()
                            Button("Use screening's verdict") { model.setVerdict(nil, for: job.id) }
                        }
                    }
                    Button("Re-evaluate") { model.reevaluate(job.id) }
                    Divider()
                    Button("Copy link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(job.openURL, forType: .string)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .controlSize(.large)
        }
    }

    @ViewBuilder private var buildButton: some View {
        if let build = summary?.build, !build.status.isFinished {
            Button {
            } label: {
                ActionLabel(title: "Building…", key: nil)
            }.disabled(true)
        } else if summary?.build?.status == .done {
            Button {
                model.selectedBuild = summary?.build?.id
                model.section = .resumes
            } label: {
                ActionLabel(title: "Open resume", key: nil, primary: true)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button {
                model.build(id)
            } label: {
                ActionLabel(title: "Build", key: "B", primary: true)
            }
            .buttonStyle(.borderedProminent)
            .help("A tailored resume for this job. More ways to build are in the … menu.")
        }
    }

    private func meta(_ job: Job) -> String {
        var parts = [job.company, job.placeLine]
        if let salary = job.salary, let line = Self.salaryLine(salary) { parts.append(line) }
        if let posted = job.postedAt { parts.append("Posted \(posted.shortDay)") }
        if let via = job.via { parts.append("via \(via)") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func salaryLine(_ salary: Salary) -> String? {
        if let text = salary.text, !text.isEmpty { return text }
        func money(_ value: Double) -> String {
            value >= 1_000 ? "$\(Int((value / 1_000).rounded()))K" : "$\(Int(value))"
        }
        let range = [salary.min, salary.max].compactMap { $0 }.map(money).joined(separator: "–")
        guard !range.isEmpty else { return nil }
        return [range, salary.currency, salary.period.map { "a \($0.rawValue)" }].compactMap { $0 }.joined(
            separator: " ")
    }

    // MARK: - Verdict

    @ViewBuilder private func verdictCard(_ detail: JobDetail) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.space3) {
                HStack(alignment: .center, spacing: Spacing.space3) {
                    if let verdict = detail.screening?.shownVerdict {
                        VerdictPill(verdict: verdict, large: true)
                    } else {
                        Text(detail.screening?.stage == .filtered ? "Filtered out" : "Waiting for the AI")
                            .font(TypeStyle.headline).foregroundStyle(Color(.inkSecondary))
                    }
                    if detail.screening?.yourVerdict != nil {
                        Text("Your verdict").font(TypeStyle.caption).foregroundStyle(Color(.inkSecondary))
                    }
                    Spacer()
                    if let coverage = detail.screening?.coverage {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("\(coverage.percent)").font(TypeStyle.score).foregroundStyle(Color(.ink))
                            Text("match").font(TypeStyle.caption).foregroundStyle(Color(.inkSecondary))
                        }
                    }
                }
                ForEach(Array((detail.screening?.reasons ?? []).enumerated()), id: \.offset) { index, reason in
                    Text(reason)
                        .font(index == 0 ? TypeStyle.headline : TypeStyle.body)
                        .foregroundStyle(index == 0 ? Color(.ink) : Color(.inkSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if detail.screening?.stage == .filtered {
                    Button("Bring back") { model.bringBack(detail.job.id) }
                }
            }
        }
    }

    // MARK: - Requirements

    private func requirements(_ analysis: JobAnalysis) -> some View {
        let musts = analysis.requirements.filter { $0.kind == .must }
        let nices = analysis.requirements.filter { $0.kind == .nice }
        return VStack(alignment: .leading, spacing: Spacing.space6) {
            if !musts.isEmpty {
                PaneSection(title: "Must-haves", trailing: shown(musts)) {
                    ForEach(Array(musts.enumerated()), id: \.offset) { _, requirement in
                        RequirementRow(requirement: requirement, describe: { profile?.describe($0) })
                    }
                }
            }
            if !nices.isEmpty {
                PaneSection(title: "Nice-to-haves", trailing: shown(nices)) {
                    ForEach(Array(nices.enumerated()), id: \.offset) { _, requirement in
                        RequirementRow(requirement: requirement, describe: { profile?.describe($0) })
                    }
                }
            }
        }
    }

    private func shown(_ requirements: [JobAnalysis.Requirement]) -> String {
        let counted = requirements.filter(\.counts)
        let credit = counted.reduce(0) { $0 + $1.effectiveMatch.credit }
        return "\(credit.formatted()) of \(counted.count) shown"
    }

    // MARK: - Where it's posted

    private func whereItsPosted(_ detail: JobDetail) -> some View {
        PaneSection(title: "Where it's posted") {
            VStack(alignment: .leading, spacing: Spacing.space2) {
                ForEach(detail.listings) { listing in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: listing.closedAt == nil ? "circle.fill" : "circle")
                            .font(.system(size: 7)).foregroundStyle(
                                listing.closedAt == nil ? Color(.yes) : Color(.inkDimmed))
                        Link(
                            listing.sourceName.isEmpty ? listing.url : listing.sourceName,
                            destination: URL(string: listing.url) ?? URL(filePath: "/")
                        )
                        .font(TypeStyle.body)
                        Spacer()
                        Text(listing.closedAt.map { "Closed \($0.shortDay)" } ?? "Seen \(listing.lastSeenAt.shortDay)")
                            .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                    }
                }
                if !detail.events.isEmpty {
                    Text(detail.events.map { "\(Self.title($0.kind)) \($0.at.shortDay)" }.joined(separator: " · "))
                        .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                }
            }
        }
    }

    static func title(_ kind: JobEvent.Kind) -> String {
        switch kind {
        case .found: "Found"
        case .postedElsewhere: "Posted elsewhere"
        case .changed: "Changed"
        case .upgraded: "Full posting"
        case .closed: "Closed"
        case .reopened: "Reopened"
        }
    }
}

/// One requirement as the screener read it: whether your master resume shows it, and the evidence.
/// Solid check for Shown, half circle for Partly shown, dashed circle for Not shown; soft skills and
/// conditions taken as met are shown but never count.
struct RequirementRow: View {
    let requirement: JobAnalysis.Requirement
    var describe: (String) -> String? = { _ in nil }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(requirement.text).font(TypeStyle.body).foregroundStyle(Color(.ink))
                    .fixedSize(horizontal: false, vertical: true)
                Text(meta).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var symbol: String {
        guard requirement.counts else { return "minus.circle" }
        switch requirement.effectiveMatch {
        case .yes: return "checkmark.circle.fill"
        case .partial: return "circle.lefthalf.filled"
        case .no, .notJudged: return "circle.dashed"
        }
    }

    private var color: Color {
        guard requirement.counts else { return Color(.inkSecondary) }
        switch requirement.effectiveMatch {
        case .yes: return Color(.yes)
        case .partial: return Color(.maybe)
        case .no, .notJudged: return Color(.no)
        }
    }

    private var meta: String {
        guard requirement.counts else { return "Not judged: taken as met or left to your filters" }
        let evidence = (requirement.evidence ?? []).compactMap(describe).prefix(2).joined(separator: "; ")
        switch requirement.effectiveMatch {
        case .yes: return evidence.isEmpty ? "Shown" : "Shown · \(evidence)"
        case .partial: return evidence.isEmpty ? "Partly shown" : "Partly shown · \(evidence)"
        case .no, .notJudged: return "Not shown"
        }
    }
}
