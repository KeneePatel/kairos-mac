import Screening
import Store
import SwiftUI

/// Why a job got its verdict (SPEC user story 4): the score, the deciding reason, each requirement
/// covered or missing with the skill that matched, notes such as a TN route, and a way to overrule.
struct JobExplanationView: View {
    let job: Job
    let source: Source?
    let record: ScreeningRecord?
    let analysis: JobAnalysis?
    let score: Int?
    var overrule: (Verdict) -> Void = { _ in }
    var skip: () -> Void = {}
    /// Starts a build; nil until builds can run.
    var build: (() -> Void)?
    /// Why Build is blocked, such as an unfinished master resume (S14).
    var buildBlocked: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.space5) {
                header
                verdict
                if let analysis {
                    requirements("Must-haves", analysis.requirements.filter { $0.kind == .must })
                    requirements("Nice-to-haves", analysis.requirements.filter { $0.kind == .nice })
                }
                if !notes.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.space2) {
                        ForEach(notes, id: \.self) { note in
                            Label(note, systemImage: "info.circle").font(TypeStyle.callout)
                                .foregroundStyle(Color(.ink2))
                        }
                    }
                }
                actions
                if let description = job.descriptionMarkdown {
                    Divider()
                    DisclosureGroup("Posting") { MarkdownView(description).padding(.top, Spacing.space2) }
                        .font(TypeStyle.headline)
                }
            }
            .padding(Spacing.space5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.surface))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            Text(source.map { "\(job.company) · via \($0.kind.displayName)" } ?? job.company)
                .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            Text(job.title).font(TypeStyle.title2).foregroundStyle(Color(.ink))
            Text(
                [
                    job.location.isEmpty ? job.placeLabel : job.location, job.workLabel,
                    job.postedAt.map { "Posted \($0.formatted(.relative(presentation: .named)))" },
                ].compactMap { $0 }.filter { $0 != "—" }.joined(separator: " · ")
            )
            .font(TypeStyle.callout).foregroundStyle(Color(.ink2))
        }
    }

    /// The score, the verdict with the reason that decided it, and the overrule menu.
    private var verdict: some View {
        HStack(alignment: .top, spacing: Spacing.space4) {
            if let score {
                VStack(spacing: 0) {
                    Text("\(score)").font(.system(size: 28, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Color(.ink))
                    Text("Match").font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                }
            }
            VStack(alignment: .leading, spacing: Spacing.space2) {
                HStack(spacing: Spacing.space2) {
                    if let verdict = job.verdict { VerdictPill(verdict: verdict, large: true) }
                    Menu("Change verdict") {
                        ForEach(Verdict.allCases, id: \.self) { verdict in
                            Button(verdict.title) { overrule(verdict) }.disabled(verdict == job.verdict)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .foregroundStyle(Color(.accentText))
                }
                if let summary {
                    Text(summary).font(TypeStyle.body).foregroundStyle(Color(.ink))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(decidedBy).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            }
        }
    }

    private func requirements(_ title: String, _ items: [JobAnalysis.Requirement]) -> some View {
        let skills = items.filter { !Coverage.isCondition($0.text) }
        let covered = skills.count { $0.matchedSkill != nil }
        return VStack(alignment: .leading, spacing: Spacing.space2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(TypeStyle.headline).foregroundStyle(Color(.ink))
                Spacer()
                Text(skills.isEmpty ? "None listed" : "\(covered) of \(skills.count) covered")
                    .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: Spacing.space3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, requirement in row(requirement) }
            }
            .padding(Spacing.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.row).fill(Color(.surfaceGrouped)))
        }
    }

    /// Covered: a solid green check. Missing: a dashed grey circle. The meta line names the match.
    private func row(_ requirement: JobAnalysis.Requirement) -> some View {
        let condition = Coverage.isCondition(requirement.text)
        let (symbol, color, meta): (String, Color, String) =
            if let skill = requirement.matchedSkill {
                ("checkmark.circle.fill", Color(.yes), "Covered · Matched: \(skill)")
            } else if condition {
                ("person.crop.circle", Color(.inkSecondary), "A condition, checked against your profile")
            } else {
                ("circle.dashed", Color(.inkSecondary), "Missing")
            }
        return HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(requirement.text).font(TypeStyle.body).foregroundStyle(Color(.ink))
                    .fixedSize(horizontal: false, vertical: true)
                Text(meta).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            }
        }
    }

    private var actions: some View {
        HStack(spacing: Spacing.space2) {
            Button("Build resume") { build?() }
                .buttonStyle(.borderedProminent)
                .disabled(build == nil || buildBlocked != nil)
                .help(buildBlocked ?? "Tailor a resume for this job from your master resume.")
            if let url = URL(string: job.url) {
                Link(destination: url) { Label("Open posting", systemImage: "arrow.up.right.square") }
            }
            Button("Not for me", action: skip)
                .help("Takes it off Today. The verdict stays.")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    /// The reason that decided the verdict, or the coverage line for a plain match.
    private var summary: String? { record?.reasons.first }

    /// Everything after the deciding reason except the coverage line, which the groups show.
    private var notes: [String] {
        Array((record?.reasons ?? []).dropFirst()).filter { !$0.hasPrefix("Covers ") }
    }

    private var decidedBy: String {
        switch record?.stage {
        case .prefilter?: "Decided by the prefilter, before any AI call."
        case .analysis?: "Decided from the AI's reading of the posting and your profile."
        case .user?: "You decided."
        case nil: "Not screened yet."
        }
    }
}
