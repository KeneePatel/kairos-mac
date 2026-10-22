import Screening
import Store
import SwiftUI

/// One job, full width (polish P3, replacing the side inspector): the posting's facts, the verdict
/// and the rule behind it, what the AI read, every requirement as it was matched with the evidence
/// from your master resume quoted, then the posting in full. Re-evaluate asks the AI again.
struct JobScreen: View {
    @Environment(AppModel.self) private var model
    let id: JobID
    @State private var stored: StoredAnalysis?
    @State private var reevaluating = false
    @State private var problem: String?
    @AppStorage("buildCoverLetter") private var coverLetter = false

    init(id: JobID, preview: StoredAnalysis? = nil) {
        self.id = id
        _stored = State(initialValue: preview)
    }

    private var job: Job? { model.job(id) }

    var body: some View {
        Group {
            if let job {
                page(job)
            } else {
                ContentUnavailableView("This job is gone", systemImage: "questionmark.folder")
            }
        }
        .background(Color(.surface))
        .navigationTitle(job?.title ?? "Job")
        .navigationSubtitle(job?.company ?? "")
        .toolbar { if let job { toolbar(job) } }
        // Reloads when the job's verdict is recorded again (a re-evaluation or a re-screen).
        .task(id: "\(id.rawValue)-\(job.flatMap { model.screening(for: $0)?.at.timeIntervalSince1970 } ?? 0)") {
            if let job { stored = await model.storedAnalysis(for: job) ?? stored }
        }
        .alert("Couldn't do that", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private func toolbar(_ job: Job) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task {
                    reevaluating = true
                    problem = await model.reevaluate(job)
                    stored = await model.storedAnalysis(for: job)
                    reevaluating = false
                }
            } label: {
                Label("Re-evaluate", systemImage: "arrow.clockwise").labelStyle(.titleAndIcon)
            }
            .disabled(reevaluating)
            .help("Screen this job again: your current settings, then a fresh AI analysis.")
            Menu {
                ForEach(Verdict.allCases, id: \.self) { verdict in
                    Button(verdict.title) { Task { await model.overrule(job, to: verdict) } }
                        .disabled(verdict == job.verdict)
                }
            } label: {
                Label("Change verdict", systemImage: "hand.raised")
            }
            Button {
                Task { await model.skip(job) }
            } label: {
                Label("Not for me", systemImage: "hand.thumbsdown")
            }
            Button {
                Task { await model.markApplied(job) }
            } label: {
                Label(model.application(for: job) == nil ? "Mark applied" : "Applied", systemImage: "paperplane")
            }
            .disabled(model.application(for: job) != nil)
            .help(
                model.application(for: job) == nil
                    ? "Records that you applied, with your latest build. Track it in Applications."
                    : "You applied. Track it in Applications."
            )
            .help("Takes it off To review. The verdict stays.")
            Toggle(isOn: $coverLetter) { Label("Cover letter", systemImage: "envelope") }
                .help("Also write a cover letter when you build.")
            Button {
                Task { problem = await model.startBuild(for: job, coverLetter: coverLetter) }
            } label: {
                Label("Build resume", systemImage: "doc.text").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.buildBlocked(job, analysed: stored != nil) != nil)
            .help(model.buildBlocked(job, analysed: stored != nil) ?? "Tailor a resume for this job.")
        }
    }

    // MARK: - Page

    private func page(_ job: Job) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.space6) {
                header(job)
                verdict(job)
                if let analysis = stored?.analysis {
                    read(analysis, model: stored?.model)
                    requirements("Must-haves", analysis.requirements.filter { $0.kind == .must })
                    requirements("Nice-to-haves", analysis.requirements.filter { $0.kind == .nice })
                }
                if !notes(job).isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.space2) {
                        ForEach(notes(job), id: \.self) { note in
                            Label(note, systemImage: "info.circle").font(TypeStyle.callout)
                                .foregroundStyle(Color(.ink2))
                        }
                    }
                }
                if let description = job.descriptionMarkdown, !description.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.space3) {
                        Text("The posting").font(TypeStyle.title3).foregroundStyle(Color(.ink))
                        MarkdownView(description)
                    }
                }
            }
            .padding(Spacing.space6)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func header(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            HStack(spacing: Spacing.space1) {
                // Adzuna's terms ask that its listings name it, linked: the credit replaces "via".
                if model.isSnippet(job) {
                    Text("\(job.company) ·").font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                    AdzunaCredit()
                } else {
                    Text(
                        model.source(job.sourceID).map { "\(job.company) · via \($0.kind.displayName)" } ?? job.company
                    )
                    .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                }
            }
            Text(job.title).font(TypeStyle.title2).foregroundStyle(Color(.ink))
            HStack(spacing: Spacing.space3) {
                Text(
                    [
                        job.location.isEmpty ? job.placeLabel : job.location, job.workLabel,
                        job.postedAt.map { "Posted \($0.formatted(.relative(presentation: .named)))" },
                    ].compactMap { $0 }.filter { $0 != "—" }.joined(separator: " · ")
                )
                .font(TypeStyle.callout).foregroundStyle(Color(.ink2))
                if let url = URL(string: job.url) {
                    Link(destination: url) { Label("Open posting", systemImage: "arrow.up.right.square") }
                        .font(TypeStyle.callout)
                }
            }
        }
    }

    /// The score, the verdict with its deciding reason, who decided, and why Build waits if it does.
    private func verdict(_ job: Job) -> some View {
        let record = model.screening(for: job)
        return HStack(alignment: .top, spacing: Spacing.space5) {
            if let score = model.matchScore(for: job) {
                VStack(spacing: 0) {
                    Text("\(score)").font(.system(size: 34, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Color(.ink))
                    Text("Match").font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                }
            }
            VStack(alignment: .leading, spacing: Spacing.space2) {
                HStack(spacing: Spacing.space3) {
                    if let verdict = job.verdict { VerdictPill(verdict: verdict, large: true) }
                    if reevaluating {
                        ProgressView().controlSize(.small)
                        Text("Asking the AI again…").font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                    }
                }
                if let reason = record?.reasons.first {
                    Text(reason).font(TypeStyle.body).foregroundStyle(Color(.ink))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(decidedBy(record)).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                if model.isSnippet(job) {
                    Label(
                        "Only a snippet of this posting came from Adzuna. Open the posting to read it all before you build.",
                        systemImage: "text.badge.minus"
                    )
                    .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).fixedSize(
                        horizontal: false, vertical: true)
                }
                if let blocked = model.buildBlocked(job, analysed: stored != nil) {
                    Label(blocked, systemImage: "lock").font(TypeStyle.callout)
                        .foregroundStyle(Color(.inkSecondary)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Spacing.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.row).fill(Color(.surfaceGrouped)))
    }

    /// What the AI took from the posting besides its requirements.
    private func read(_ analysis: JobAnalysis, model name: String?) -> some View {
        let flags = analysis.flags
        let parts = [
            analysis.yearsRequired.map { "\($0)+ years" }, analysis.seniority.map { $0.title + " level" },
            flags.sponsorship == .notMentioned
                ? nil : flags.sponsorship == .offered ? "Offers sponsorship" : "No sponsorship",
            flags.clearance == .notMentioned
                ? nil : "Clearance \(flags.clearance == .required ? "required" : "obtainable")",
            flags.french == .notMentioned ? nil : "French \(flags.french == .required ? "required" : "an asset")",
            analysis.domains.isEmpty ? nil : analysis.domains.joined(separator: ", "),
        ].compactMap { $0 }
        return VStack(alignment: .leading, spacing: Spacing.space1) {
            Text("What the AI read").font(TypeStyle.headline).foregroundStyle(Color(.ink))
            Text(parts.isEmpty ? "No years, level or conditions named." : parts.joined(separator: " · "))
                .font(TypeStyle.body).foregroundStyle(Color(.ink2))
            if let name, let stored {
                Text(
                    "Analysed by \(name), prompt v\(stored.promptVersion), \(stored.analyzedAt.formatted(.relative(presentation: .named)))."
                )
                .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            }
        }
    }

    private func requirements(_ title: String, _ items: [JobAnalysis.Requirement]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(TypeStyle.title3).foregroundStyle(Color(.ink))
                Spacer()
                Text(items.isEmpty ? "None listed" : items.shownSummary).font(TypeStyle.callout)
                    .foregroundStyle(Color(.inkSecondary)).monospacedDigit()
            }
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.space3) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, requirement in
                        RequirementRow(requirement: requirement) { model.screeningProfile?.describe($0) }
                    }
                }
                .padding(Spacing.space4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.row).fill(Color(.surfaceGrouped)))
            }
        }
    }

    /// Everything after the deciding reason except the coverage line, which the groups show.
    private func notes(_ job: Job) -> [String] {
        Array((model.screening(for: job)?.reasons ?? []).dropFirst()).filter { !$0.hasPrefix("Covers ") }
    }

    private func decidedBy(_ record: ScreeningRecord?) -> String {
        switch record?.stage {
        case .prefilter?: "Decided by your filters, before any AI call. Bring it back from Filtered out."
        case .analysis?: "Decided by code, from the AI's reading of the posting against your master resume."
        case .user?: "You decided."
        case nil: "Not screened yet."
        }
    }
}
