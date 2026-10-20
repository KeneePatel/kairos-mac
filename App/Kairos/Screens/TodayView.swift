import Screening
import Store
import SwiftUI

/// Today (SPEC §5.2, step 7; design `Main.dc.html`): the screened jobs you haven't acted on, best
/// first, grouped by country in your order, with the selected job's explanation in the inspector.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: JobID?
    @State private var filter: Verdict?
    @State private var showsInspector = true

    var body: some View {
        content
            .navigationTitle("Today")
            .navigationSubtitle(model.runSummary)
            .toolbar {
                ToolbarItem(placement: .principal) { verdictFilter }
                RunControls(model: model)
            }
            .inspector(isPresented: $showsInspector) {
                inspector.inspectorColumnWidth(min: 340, ideal: 420, max: 560)
            }
    }

    @ViewBuilder private var content: some View {
        if model.todayJobs.isEmpty {
            ContentUnavailableView {
                Label("Nothing screened yet", systemImage: "sun.max")
            } description: {
                Text(emptyMessage)
            }
        } else {
            table
        }
    }

    private var emptyMessage: String {
        if model.sources.isEmpty { return "Add a company in Sources, then choose Run now." }
        if model.waitingForAI > 0 {
            return
                "\(model.waitingForAI) jobs passed the prefilter and wait for analysis. Add an AI key in Settings, then choose Run now."
        }
        return "Choose Run now to fetch your companies' boards and screen what's new."
    }

    /// All, Yes, Maybe or No, with counts.
    private var verdictFilter: some View {
        Picker("Verdict", selection: $filter) {
            Text("All \(model.todayCount(nil))").tag(Verdict?.none)
            ForEach(Verdict.allCases, id: \.self) { verdict in
                Text("\(verdict.title) \(model.todayCount(verdict))").tag(Verdict?.some(verdict))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .monospacedDigit()
        .fixedSize()
    }

    private var table: some View {
        Table(of: Job.self, selection: $selection) {
            TableColumn("Verdict") { job in
                if let verdict = job.verdict { VerdictPill(verdict: verdict) }
            }
            .width(min: 84, ideal: 92)
            TableColumn("Role") { job in
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title).font(TypeStyle.headline).foregroundStyle(primary(job))
                    Text(roleLine(job)).font(TypeStyle.callout).foregroundStyle(secondary(job)).lineLimit(1)
                }
                .padding(.vertical, Spacing.space1)
            }
            .width(min: 240, ideal: 380)
            TableColumn("Location") { job in Text(job.placeLabel).foregroundStyle(secondary(job)) }
                .width(min: 110, ideal: 140)
            TableColumn("Work") { job in Text(job.workLabel).foregroundStyle(secondary(job)) }
                .width(min: 90, ideal: 130)
            TableColumn("Source") { job in
                Text(model.source(job.sourceID)?.kind.displayName ?? "—").foregroundStyle(secondary(job))
            }
            .width(min: 80, ideal: 100)
            TableColumn("Match") { job in
                Text(model.matchScore(for: job).map(String.init) ?? "—").font(TypeStyle.headline).monospacedDigit()
                    .foregroundStyle(primary(job))
            }
            .width(min: 50, ideal: 60)
        } rows: {
            ForEach(model.todaySections(showing: filter)) { section in
                Section("\(section.title) · \(section.jobs.count) job\(section.jobs.count == 1 ? "" : "s")") {
                    ForEach(section.jobs) { TableRow($0) }
                }
            }
        }
    }

    /// The company, then for a maybe or a no the reason that decided it.
    private func roleLine(_ job: Job) -> String {
        guard job.verdict != .yes, let reason = model.screening(for: job)?.reasons.first else { return job.company }
        return "\(job.company) · \(reason)"
    }

    /// "No" rows are dimmed with ink-dimmed, not opacity (design rule 1).
    private func primary(_ job: Job) -> Color { job.verdict == .no ? Color(.inkDimmed) : Color(.ink) }
    private func secondary(_ job: Job) -> Color { job.verdict == .no ? Color(.inkDimmed) : Color(.inkSecondary) }

    @ViewBuilder private var inspector: some View {
        if let job = model.job(selection) {
            JobExplanationLoader(job: job)
        } else {
            ContentUnavailableView("Select a job", systemImage: "sidebar.right")
        }
    }
}

/// Loads the analysis behind the selected job's verdict, then shows the explanation.
private struct JobExplanationLoader: View {
    @Environment(AppModel.self) private var model
    /// Shared with the Build screen's toggle: a per-Mac convenience, not a synced setting.
    @AppStorage("buildCoverLetter") private var coverLetter = false
    let job: Job
    @State private var analysis: JobAnalysis?
    @State private var problem: String?

    var body: some View {
        JobExplanationView(
            job: job, source: model.source(job.sourceID), record: model.screening(for: job), analysis: analysis,
            score: model.matchScore(for: job),
            overrule: { verdict in Task { await model.overrule(job, to: verdict) } },
            skip: { Task { await model.skip(job) } },
            build: { Task { problem = await model.startBuild(for: job, coverLetter: coverLetter) } },
            coverLetter: $coverLetter,
            buildBlocked: buildBlocked
        )
        .task(id: job.id) { analysis = await model.analysis(for: job) }
        .alert("Can't build", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    /// S14: Build waits for a ready master resume, and for this job's analysis.
    private var buildBlocked: String? {
        if let readiness = model.resume?.readiness, !readiness.isReady {
            return "Finish your master resume first: \(readiness.missing.map(\.message).joined(separator: " "))"
        }
        return analysis == nil ? "This job needs an analysis first: run screening with an AI key." : nil
    }
}
