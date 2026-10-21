import Screening
import Store
import SwiftUI

/// Review (polish P3, replacing Today and Jobs): the screened jobs, best first. Yes, Maybe and No
/// are the jobs that reached the AI, grouped by country in your order; Prefiltered is what the
/// prefilter dropped, grouped by the rule; All is everything fetched. Choosing a job opens it full
/// width.
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: AppModel.ReviewFilter
    @State private var path: [JobID] = []
    @State private var selection: JobID?

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
                            model.screenAgain()
                        } label: {
                            Label("Re-screen all", systemImage: "arrow.triangle.2.circlepath")
                                .labelStyle(.titleAndIcon)
                        }
                        .disabled(model.isFetching || model.jobs.isEmpty)
                        .help(
                            "Applies your current settings to every job again. Jobs analysed with the current prompt keep their analysis; the rest are analysed."
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
    }

    @ViewBuilder private var content: some View {
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
        case .prefiltered: "Nothing prefiltered"
        case .all: "No jobs yet"
        }
    }

    private var emptyMessage: String {
        if model.sources.isEmpty { return "Add a company in Fetch, then choose Fetch now." }
        if model.waitingForAI > 0 {
            return
                "\(model.waitingForAI) jobs passed the prefilter and wait for the AI. Add a key in Settings, then fetch again."
        }
        switch filter {
        case .yes, .maybe:
            return "None right now. No and Prefiltered show why the rest didn't make it."
        case .no, .prefiltered:
            return "Every job got past this stage."
        case .all:
            return "Choose Fetch now in Fetch to check your companies' boards."
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

    /// The company, then for a maybe or a no the reason that decided it.
    private func roleLine(_ job: Job) -> String {
        guard job.verdict != .yes, let reason = model.screening(for: job)?.reasons.first else { return job.company }
        return "\(job.company) · \(reason)"
    }

    /// "No" rows are dimmed with ink-dimmed, not opacity (design rule 1).
    private func primary(_ job: Job) -> Color { job.verdict == .no ? Color(.inkDimmed) : Color(.ink) }
    private func secondary(_ job: Job) -> Color { job.verdict == .no ? Color(.inkDimmed) : Color(.inkSecondary) }
}
