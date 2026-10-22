import Screening
import Store
import SwiftUI

/// Review (polish P3; reworked 2026-10-22): the jobs that passed your filters, best first, grouped
/// by country in your order. Yes, Maybe and No are what's left to decide; All adds the jobs you've
/// applied to or marked "Not for me" (dimmed) and those waiting for the AI. What your filters
/// dropped is in Filtered out. Choosing a job opens it full width.
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: AppModel.ReviewFilter
    @State private var path: [JobID] = []
    @State private var selection: JobID?
    @State private var confirmingRescreen = false
    @State private var callsNeeded = 0

    init(filter: AppModel.ReviewFilter = .yes) {
        _filter = State(initialValue: filter)
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Review")
                .navigationSubtitle(model.runSummary)
                .toolbar {
                    ToolbarItem(placement: .principal) { filterPicker }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task {
                                callsNeeded = await model.analysesNeeded()
                                if callsNeeded == 0 { model.screenAgain() } else { confirmingRescreen = true }
                            }
                        } label: {
                            Label("Re-screen all", systemImage: "arrow.triangle.2.circlepath")
                                .labelStyle(.titleAndIcon)
                        }
                        .disabled(model.isFetching || model.jobs.isEmpty)
                        .help(
                            "Applies your current settings to every job again. Jobs analysed with the current prompt keep their analysis; the rest are sent to the AI."
                        )
                    }
                }
                .navigationDestination(for: JobID.self) { JobScreen(id: $0) }
        }
        .confirmationDialog(
            "Re-screen all jobs?", isPresented: $confirmingRescreen, titleVisibility: .visible
        ) {
            Button("Re-screen, using about \(callsNeeded) AI call\(callsNeeded == 1 ? "" : "s")") {
                model.screenAgain()
            }
        } message: {
            Text(
                "\(callsNeeded) job\(callsNeeded == 1 ? " hasn't" : "s haven't") been analysed with the current prompt, so each costs one AI call from your daily budget. The rest reuse their analysis for free."
            )
        }
        .onChange(of: selection) { _, id in
            guard let id else { return }
            path.append(id)
            selection = nil
        }
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 0) {
            if model.waitingForAI > 0 {
                Label(
                    "\(model.waitingForAI) job\(model.waitingForAI == 1 ? " is" : "s are") waiting for the AI. Add a key in Settings, AI providers, then choose Re-screen all.",
                    systemImage: "hourglass"
                )
                .font(TypeStyle.callout).foregroundStyle(Color(.ink))
                .padding(.horizontal, Spacing.space4).padding(.vertical, Spacing.space2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.maybeBg))
            }
            list
        }
    }

    @ViewBuilder private var list: some View {
        if model.reviewJobs(filter).isEmpty {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: "checklist")
            } description: {
                Text(emptyMessage).foregroundStyle(Color(.inkSecondary))
            }
        } else {
            table
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .yes: "No Yes jobs"
        case .maybe: "No Maybe jobs"
        case .no: "No rejections from the AI"
        case .all: "No jobs yet"
        }
    }

    private var emptyMessage: String {
        if model.sources.isEmpty { return "Add a company in Find jobs, then choose Find new jobs." }
        if model.waitingForAI > 0 {
            return
                "\(model.waitingForAI) jobs passed your filters and wait for the AI. Add a key in Settings, then choose Re-screen all."
        }
        switch filter {
        case .yes, .maybe:
            return "None right now. No shows what the AI ruled out, and Filtered out what your filters dropped."
        case .no:
            return "The AI hasn't ruled anything out."
        case .all:
            return "Choose Find new jobs in Find jobs to check your companies' boards."
        }
    }

    private var filterPicker: some View {
        Picker("Show", selection: $filter) {
            ForEach(AppModel.ReviewFilter.allCases) { filter in
                Text("\(filter.title) \(model.reviewCount(filter))").tag(filter)
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
                if let verdict = job.verdict {
                    VerdictPill(verdict: verdict)
                } else {
                    Text("Waiting").font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                }
            }
            .width(min: 84, ideal: 92)
            TableColumn("Role") { job in
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title).font(TypeStyle.headline).foregroundStyle(primary(job))
                    Text(roleLine(job)).font(TypeStyle.callout).foregroundStyle(secondary(job)).lineLimit(1)
                }
                .padding(.vertical, Spacing.space1)
            }
            .width(min: 260, ideal: 420)
            TableColumn("Location") { job in Text(job.placeLabel).foregroundStyle(secondary(job)) }
                .width(min: 110, ideal: 140)
            TableColumn("Work") { job in Text(job.workLabel).foregroundStyle(secondary(job)) }
                .width(min: 90, ideal: 120)
            TableColumn("Match") { job in
                Text(model.matchScore(for: job).map(String.init) ?? "—").font(TypeStyle.headline).monospacedDigit()
                    .foregroundStyle(primary(job))
            }
            .width(min: 50, ideal: 60)
        } rows: {
            ForEach(model.reviewSections(filter)) { section in
                Section("\(section.title) · \(section.jobs.count) job\(section.jobs.count == 1 ? "" : "s")") {
                    ForEach(section.jobs) { TableRow($0) }
                }
            }
        }
    }

    /// The company, then what you did with it, or for a maybe or a no the reason that decided it.
    private func roleLine(_ job: Job) -> String {
        if job.state == .applied { return "\(job.company) · Applied" }
        if job.state == .skipped { return "\(job.company) · Not for me" }
        guard job.verdict != .yes, let reason = model.screening(for: job)?.reasons.first else { return job.company }
        return "\(job.company) · \(reason)"
    }

    /// "No" rows and jobs you've acted on are dimmed with ink-dimmed, not opacity (design rule 1).
    private func dimmed(_ job: Job) -> Bool { job.verdict == .no || model.isActedOn(job) }
    private func primary(_ job: Job) -> Color { dimmed(job) ? Color(.inkDimmed) : Color(.ink) }
    private func secondary(_ job: Job) -> Color { dimmed(job) ? Color(.inkDimmed) : Color(.inkSecondary) }
}
