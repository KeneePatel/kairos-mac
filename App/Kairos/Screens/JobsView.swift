import Pipeline
import Render
import Screening
import Store
import SwiftUI
import Tailoring

/// The three lists of jobs (UI v2, ADR-017): the Inbox, Saved and Skipped. Each is the list on
/// the left with the chosen job beside it, a Filter and a Sort menu, search, and one key per
/// decision while the list has focus. A decision moves the selection on.
enum JobsScope: String, CaseIterable {
    case inbox, saved, skipped

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .saved: "Saved"
        case .skipped: "Skipped"
        }
    }

    var emptyTitle: String {
        switch self {
        case .inbox: "Nothing to decide"
        case .saved: "Nothing saved"
        case .skipped: "Nothing skipped"
        }
    }
}

struct JobsView: View {
    let scope: JobsScope
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @State private var query = Inbox.Query()
    @State private var showNo = false
    @State private var path: [JobID] = []
    @State private var confirmingRescreen = false
    @State private var callsNeeded = 0
    @State private var bulk: BulkRequest?
    @State private var notice: (title: String, message: String)?
    @AppStorage("buildCoverLetter") private var coverLetter = false

    /// A "Build resumes" choice waiting for you to confirm it.
    struct BulkRequest {
        let filter: AppModel.ReviewFilter
        let plan: BulkBuild
        let used: Int?
        let budget: Int?
    }

    private var groups: [Inbox.Group] { model.groups(scope, query: query) }
    private var visible: [JobID] { groups.flatMap { $0.kind == .noFromAI && !showNo ? [] : $0.jobs.map(\.id) } }

    private var selection: Binding<JobID?> {
        Binding(get: { model.selectedJob }, set: { model.selectedJob = $0 })
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle(scope.title)
                .searchable(text: $query.search, placement: .toolbar, prompt: "Search jobs")
                .toolbar { toolbar }
                .navigationDestination(for: JobID.self) { JobScreen(id: $0) }
        }
        .onAppear { model.undoManager = undoManager }
        .task(id: visible) {
            model.visibleJobs = visible
            if model.selectedJob.map({ !visible.contains($0) }) ?? true { model.selectedJob = visible.first }
        }
        .confirmationDialog(
            "Re-screen every job?", isPresented: $confirmingRescreen, titleVisibility: .visible
        ) {
            Button("Re-screen, about \(callsNeeded) AI call\(callsNeeded == 1 ? "" : "s")") { model.screenAgain() }
        } message: {
            Text(
                "Every job is judged again with your current settings and keeps its verdict until it gets a new one. The \(callsNeeded) without an analysis from the current prompt cost one AI call each; the rest reuse theirs."
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
    }

    private var content: some View {
        ListPaneLayout {
            list
        } pane: {
            if let id = model.selectedJob, visible.contains(id) {
                JobPane(id: id, scope: scope)
            } else {
                paneEmpty
            }
        }
    }

    // MARK: - The list

    private var list: some View {
        VStack(spacing: 0) {
            ColumnTitle(title: scope.title, line: countLine)
            if groups.isEmpty {
                empty
            } else {
                List(selection: selection) {
                    ForEach(groups) { group in
                        Section {
                            if group.kind != .noFromAI || showNo {
                                ForEach(group.jobs) { job in
                                    JobRow(
                                        job: job, reason: model.screening(for: job)?.reasons.first,
                                        score: model.matchScore(for: job),
                                        hasResume: model.latestBuild(for: job) != nil,
                                        dimmed: job.verdict == .no || scope == .skipped
                                    )
                                    .tag(job.id)
                                    .listRowInsets(
                                        EdgeInsets(top: 0, leading: Spacing.space3, bottom: 0, trailing: Spacing.space3)
                                    )
                                    .contextMenu { rowMenu(job) }
                                }
                            }
                        } header: {
                            groupHeader(group)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onKeyPress(characters: Self.decisionKeys) { press in
                    handle(press.characters.lowercased()) ? .handled : .ignored
                }
                .onKeyPress(.return) {
                    guard let id = model.selectedJob else { return .ignored }
                    path.append(id)
                    return .handled
                }
            }
            Divider()
            Text(hint).font(TypeStyle.caption).foregroundStyle(Color(.inkSecondary)).lineLimit(1)
                .padding(.horizontal, Spacing.space6).padding(.vertical, Spacing.space3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let decisionKeys = CharacterSet(charactersIn: "bsxoarjkBSXOARJK")

    /// One key per decision while the list has focus; the Job menu lists the same with ⌘.
    private func handle(_ key: String) -> Bool {
        guard let job = model.job(model.selectedJob) else { return false }
        switch key {
        case "b": Task { _ = await model.startBuild(for: job, coverLetter: coverLetter, show: false) }
        case "s": Task { job.state == .shortlisted ? await model.unsave(job) : await model.save(job) }
        case "x": Task { job.state == .skipped ? await model.unskip(job) : await model.skip(job) }
        case "o": model.openPosting(job)
        case "a": Task { await model.markApplied(job) }
        case "r": Task { _ = await model.reevaluate(job) }
        case "j": model.selectNeighbour(1)
        case "k": model.selectNeighbour(-1)
        default: return false
        }
        return true
    }

    private func groupHeader(_ group: Inbox.Group) -> some View {
        HStack(spacing: Spacing.space1) {
            if group.kind == .noFromAI {
                Button {
                    showNo.toggle()
                } label: {
                    Label(
                        "\(group.kind.title) · \(group.jobs.count)",
                        systemImage: showNo ? "chevron.down" : "chevron.right"
                    )
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
            } else {
                Text("\(group.kind.title) · \(group.jobs.count)")
            }
        }
        .font(TypeStyle.caption).foregroundStyle(Color(.inkSecondary)).monospacedDigit()
        .padding(.horizontal, Spacing.space3)
        .padding(.top, Spacing.space2)
        .textCase(nil)
    }

    @ViewBuilder private func rowMenu(_ job: Job) -> some View {
        Button("Open full width") { path.append(job.id) }
        Button("Open posting") { model.openPosting(job) }
        Divider()
        if job.state == .shortlisted {
            Button("Unsave") { Task { await model.unsave(job) } }
        } else {
            Button("Save") { Task { await model.save(job) } }
        }
        if job.state == .skipped {
            Button("Bring back") { Task { await model.unskip(job) } }
        } else {
            Button("Skip") { Task { await model.skip(job) } }
        }
    }

    /// "247 to decide · 14 new today · 12 waiting for the AI".
    private var countLine: String {
        let all = model.groups(scope, query: Inbox.Query())
        func count(_ kind: Inbox.GroupKind) -> Int { all.first { $0.kind == kind }?.jobs.count ?? 0 }
        switch scope {
        case .inbox:
            var parts = ["\(count(.decide)) to decide"]
            let new = Inbox.newToday(model.inboxJobs)
            if new > 0 { parts.append("\(new) new today") }
            if model.waitingForAI > 0 { parts.append("\(model.waitingForAI) waiting for the AI") }
            return parts.joined(separator: " · ")
        case .saved:
            let n = model.savedJobs.count
            return n == 0 ? "Jobs you keep for later" : "\(n) saved · press S on a job to keep it here"
        case .skipped:
            let n = model.skippedJobs.count
            return n == 0
                ? "Jobs you skipped, and ones no longer posted"
                : "\(n) skipped or gone · Bring back sends one to the Inbox"
        }
    }

    private var hint: String {
        switch scope {
        case .inbox, .saved: "↑↓ move · ↩ open · B build · S save · X skip · O posting"
        case .skipped: "↑↓ move · ↩ open · X bring back · O posting"
        }
    }

    private var empty: some View {
        VStack(spacing: Spacing.space2) {
            Text(query.search.isEmpty && query.verdict == nil && query.country == nil ? scope.emptyTitle : "No matches")
                .font(TypeStyle.title2).foregroundStyle(Color(.ink))
            Text(emptyLine).font(TypeStyle.body).foregroundStyle(Color(.inkSecondary))
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if scope == .inbox, query.search.isEmpty {
                Button {
                    model.fetchNow()
                } label: {
                    ActionLabel(title: "Find new jobs", key: "⌘R")
                }
                .disabled(model.isFetching || model.sources.allSatisfy { !$0.enabled })
                .padding(.top, Spacing.space2)
            }
        }
        .padding(Spacing.space7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyLine: String {
        if !query.search.isEmpty || query.verdict != nil || query.country != nil {
            return "Nothing here matches the filter or the search."
        }
        switch scope {
        case .inbox:
            if model.sources.isEmpty { return "Add a company in Sources, then find new jobs." }
            if model.waitingForAI > 0 {
                return "\(model.waitingForAI) jobs wait for the AI; the status line below has Screen now."
            }
            let saved = model.savedJobs.count
            return saved > 0
                ? "Saved holds the \(saved) job\(saved == 1 ? "" : "s") you kept."
                : "Jobs show up here as Kairos finds and screens them."
        case .saved: return "Press S on a job in the Inbox to keep it here."
        case .skipped: return "Press X on a job in the Inbox to skip it. Jobs no longer posted land here too."
        }
    }

    private var paneEmpty: some View {
        VStack(spacing: Spacing.space1) {
            Text("Nothing selected").font(TypeStyle.title2).foregroundStyle(Color(.ink))
            Text("Choose a job in the list.").font(TypeStyle.body).foregroundStyle(Color(.inkSecondary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("Verdict", selection: $query.verdict) {
                    Text("Any verdict").tag(Verdict?.none)
                    ForEach(Verdict.allCases, id: \.self) { Text($0.title).tag(Verdict?.some($0)) }
                }
                Picker("Country", selection: $query.country) {
                    Text("Any country").tag(Country?.none)
                    ForEach(Country.allCases, id: \.self) { Text($0.displayName).tag(Country?.some($0)) }
                }
            } label: {
                Label(filterTitle, systemImage: "line.3.horizontal.decrease").labelStyle(.titleAndIcon)
            }
            .help("Narrow the list by verdict or country")
            Menu {
                Picker("Sort", selection: $query.sort) {
                    ForEach(Inbox.Sort.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                Label("Sort: \(query.sort.title)", systemImage: "arrow.up.arrow.down").labelStyle(.titleOnly)
            }
            if scope == .inbox { moreMenu }
            Button {
                model.fetchNow()
            } label: {
                Label("Find new jobs", systemImage: "arrow.clockwise").labelStyle(.titleAndIcon)
            }
            .disabled(model.isFetching || model.sources.allSatisfy { !$0.enabled })
            .help("Check every enabled board, then screen what's new (⌘R)")
        }
    }

    private var filterTitle: String {
        var parts: [String] = []
        if let verdict = query.verdict { parts.append(verdict.title) }
        if let country = query.country { parts.append(country.displayName) }
        return parts.isEmpty ? "Filter" : parts.joined(separator: " · ")
    }

    /// Actions you rarely need: resumes for a whole list, and screening everything again.
    private var moreMenu: some View {
        Menu {
            ForEach([AppModel.ReviewFilter.yes, .maybe]) { list in
                Button("Build resumes for every \(list.title) job (\(model.reviewCount(list)))…") {
                    Task { await prepare(list) }
                }
                .disabled(model.reviewCount(list) == 0)
            }
            Divider()
            if model.waitingForAI > 0 {
                Button("Screen the \(model.waitingForAI) waiting for the AI") { model.screenWaiting() }
                    .disabled(model.isFetching || !model.canAnalyse)
            }
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
        .help("Resumes for a whole list, or screen everything again")
    }

    // MARK: - Build resumes for a list

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
            "They build two at a time; you can keep working. "
                + (coverLetter ? "Each gets a cover letter." : "No cover letters: the switch is in a job's More menu."))
        if let used = request.used, let budget = request.budget {
            parts.append(
                "You've used \(used) of your \(budget) AI calls today. Builds past the budget wait for tomorrow.")
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
}
