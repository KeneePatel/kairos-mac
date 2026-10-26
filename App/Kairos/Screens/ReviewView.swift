import LLM
import Pipeline
import Render
import Screening
import Store
import SwiftUI
import Tailoring

/// Review (polish P3; reworked 2026-10-22): the jobs that passed your filters, best first, grouped
/// by country in your order. Yes, Maybe and No are what's left to decide; All adds the jobs you've
/// applied to or marked "Not for me" (dimmed) and those waiting for the AI. What your filters
/// dropped is in Filtered out. Choosing a job opens it full width. Build resumes queues one for
/// every Yes or every Maybe job that has none, after saying what it costs. Jobs waiting for the AI
/// are screened from the banner above the list; Re-screen all is in More (2026-10-26).
struct ReviewView: View {
    /// A "Build resumes" choice waiting for you to confirm it.
    struct BulkRequest {
        let filter: AppModel.ReviewFilter
        let plan: BulkBuild
        /// AI calls used today, and the daily budget, when AI is set up.
        let used: Int?
        let budget: Int?
    }

    @Environment(AppModel.self) private var model
    @State private var filter: AppModel.ReviewFilter
    @State private var path: [JobID] = []
    @State private var selection: JobID?
    @State private var confirmingRescreen = false
    @State private var callsNeeded = 0
    @State private var bulk: BulkRequest?
    @State private var notice: (title: String, message: String)?
    @AppStorage("buildCoverLetter") private var coverLetter = false

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
                    ToolbarItem(placement: .primaryAction) { buildMenu }
                    ToolbarItem(placement: .primaryAction) { moreMenu }
                }
                .navigationDestination(for: JobID.self) { JobScreen(id: $0) }
        }
        .confirmationDialog(
            "Re-screen every job?", isPresented: $confirmingRescreen, titleVisibility: .visible
        ) {
            Button("Re-screen, using about \(callsNeeded) AI call\(callsNeeded == 1 ? "" : "s")") {
                model.screenAgain()
            }
        } message: {
            Text(
                "Every job is judged again with your current settings, and keeps its verdict until it gets a new one. \(callsNeeded) job\(callsNeeded == 1 ? " hasn't" : "s haven't") been analysed with the current prompt, so each costs one AI call from your daily budget. The rest reuse their analysis for free. To screen only the jobs waiting for the AI, use Screen them above the list."
            )
        }
        .confirmationDialog(
            bulk.map { "Build \($0.plan.jobs.count) resume\($0.plan.jobs.count == 1 ? "" : "s")?" } ?? "",
            isPresented: Binding(get: { bulk != nil }, set: { if !$0 { bulk = nil } }), titleVisibility: .visible,
            presenting: bulk
        ) { request in
            ForEach(modes, id: \.self) { mode in
                Button("\(Self.title(of: mode)), about \(calls(request.plan, mode))") {
                    Task {
                        if let problem = await model.startBuilds(
                            request.plan.jobs, mode: mode, coverLetter: coverLetter)
                        {
                            notice = ("Couldn't build them all", problem)
                        }
                    }
                }
            }
        } message: { request in
            Text(bulkMessage(request))
        }
        .alert(
            notice?.title ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice?.message ?? "")
        }
        .onChange(of: selection) { _, id in
            guard let id else { return }
            path.append(id)
            selection = nil
        }
    }

    /// The banner stays at the top; the list, or its empty state, fills the rest (an empty state
    /// alone used to centre the banner with it, 2026-10-26).
    @ViewBuilder private var content: some View {
        VStack(spacing: 0) {
            ScreeningBanner()
            list.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Actions you rarely need. Re-screen all judges every job again after you change settings;
    /// the waiting jobs alone are screened from the banner.
    private var moreMenu: some View {
        Menu {
            Button("Re-screen all jobs…") {
                Task {
                    callsNeeded = await model.analysesNeeded()
                    if callsNeeded == 0 { model.screenAgain() } else { confirmingRescreen = true }
                }
            }
            .disabled(model.isFetching || model.jobs.isEmpty)
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .help("More actions")
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
        if model.isScreening || model.waitingForAI > 0 { return "Jobs show up here as the AI screens them." }
        switch filter {
        case .yes, .maybe:
            return "None right now. No shows what the AI ruled out, and Filtered out what your filters dropped."
        case .no:
            return "The AI hasn't ruled anything out."
        case .all:
            return "Choose Find new jobs in Find jobs to check your companies' boards."
        }
    }

    // MARK: - Build resumes

    private var buildMenu: some View {
        Menu {
            ForEach([AppModel.ReviewFilter.yes, .maybe]) { list in
                Button("For every \(list.title) job (\(model.reviewCount(list)))…") {
                    Task { await prepare(list) }
                }
                .disabled(model.reviewCount(list) == 0)
            }
        } label: {
            Label("Build resumes", systemImage: "doc.on.doc").labelStyle(.titleAndIcon)
        }
        .disabled(model.reviewCount(.yes) + model.reviewCount(.maybe) == 0)
        .help("Queue a resume for every Yes or every Maybe job that doesn't have one. You'll see the cost first.")
    }

    /// Works out what the list needs, then asks; or says why there's nothing to build.
    private func prepare(_ list: AppModel.ReviewFilter) async {
        let plan = await model.bulkBuild(list)
        guard !plan.jobs.isEmpty else {
            notice = ("Nothing to build", Self.skipped(plan, list: list) ?? "")
            return
        }
        await model.ai?.refreshUsage()
        bulk = BulkRequest(
            filter: list, plan: plan, used: model.ai?.usedToday, budget: model.ai?.settings.budget.dailyCalls)
    }

    /// Your usual mode first, then Lite, the cheapest, unless it's the same.
    private var modes: [BuildMode] {
        model.defaultBuildMode == .lite ? [.lite] : [model.defaultBuildMode, .lite]
    }

    static func title(of mode: BuildMode) -> String {
        switch mode {
        case .strict: "Full: rewrite for each job"
        case .stretch: "Stretch: rewrite, add gap bullets"
        case .lite: "Lite: copy your bullets"
        }
    }

    /// "42–126 AI calls", or "14 AI calls" when it can't vary.
    private func calls(_ plan: BulkBuild, _ mode: BuildMode) -> String {
        let range = plan.calls(mode: mode, coverLetter: coverLetter, summary: ResumeTemplate.standard.hasSummary)
        let count =
            range.lowerBound == range.upperBound
            ? "\(range.lowerBound)" : "\(range.lowerBound)–\(range.upperBound)"
        return "\(count) AI call\(range.upperBound == 1 ? "" : "s")"
    }

    private func bulkMessage(_ request: BulkRequest) -> String {
        var parts: [String] = []
        if let skipped = Self.skipped(request.plan, list: request.filter) { parts.append(skipped) }
        parts.append(
            "They build two at a time, so this takes a while; you can keep working. "
                + (coverLetter
                    ? "Each gets a cover letter, since Cover letter is on."
                    : "No cover letters: Cover letter is off on the job pages."))
        if let used = request.used, let budget = request.budget {
            parts.append(
                "You've used \(used) of your \(budget) AI calls today. Builds past the budget stop with \"\(Budget.reachedMessage)\"; build those again tomorrow."
            )
        }
        return parts.joined(separator: "\n\n")
    }

    /// Why some of the list's jobs aren't built, or nil when none are skipped.
    static func skipped(_ plan: BulkBuild, list: AppModel.ReviewFilter) -> String? {
        var reasons: [String] = []
        if plan.alreadyBuilt > 0 {
            reasons.append(
                "\(plan.alreadyBuilt) already \(plan.alreadyBuilt == 1 ? "has a resume or one" : "have a resume or one") on the way"
            )
        }
        if plan.notAnalysed > 0 {
            reasons.append(
                "\(plan.notAnalysed) \(plan.notAnalysed == 1 ? "hasn't" : "haven't") been analysed with the current prompt; Re-evaluate \(plan.notAnalysed == 1 ? "it" : "them") first"
            )
        }
        guard !reasons.isEmpty else { return nil }
        return "Of your \(list.title) jobs, " + ListFormatter.localizedString(byJoining: reasons) + "."
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
            TableColumn("Resume") { job in ResumeStatus(build: model.latestBuild(for: job), dimmed: dimmed(job)) }
                .width(min: 100, ideal: 120)
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
        if !job.isOpen { return "\(job.company) · No longer posted" }
        guard job.verdict != .yes, let reason = model.screening(for: job)?.reasons.first else { return job.company }
        return "\(job.company) · \(reason)"
    }

    /// "No" rows and jobs you've acted on are dimmed with ink-dimmed, not opacity (design rule 1).
    private func dimmed(_ job: Job) -> Bool { job.verdict == .no || model.isActedOn(job) || !job.isOpen }
    private func primary(_ job: Job) -> Color { dimmed(job) ? Color(.inkDimmed) : Color(.ink) }
    private func secondary(_ job: Job) -> Color { dimmed(job) ? Color(.inkDimmed) : Color(.inkSecondary) }
}

/// Where a job's resume is: an icon and a word, never colour alone.
struct ResumeStatus: View {
    let build: BuildRecord?
    var dimmed = false

    var body: some View {
        switch build?.status {
        case nil:
            Text("—").foregroundStyle(Color(dimmed ? .inkDimmed : .inkSecondary))
        case .queued?:
            Label("Waiting", systemImage: "clock").foregroundStyle(Color(dimmed ? .inkDimmed : .inkSecondary))
        case .running?:
            HStack(spacing: Spacing.space1) {
                ProgressView().controlSize(.mini)
                Text("Building").foregroundStyle(Color(dimmed ? .inkDimmed : .ink2))
            }
        case .done?:
            Label("Built", systemImage: "doc.text.fill").foregroundStyle(Color(dimmed ? .inkDimmed : .ink2))
        case .failed?:
            Label("Didn't finish", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(dimmed ? .inkDimmed : .error))
                .help(build?.error ?? "")
        }
    }
}
