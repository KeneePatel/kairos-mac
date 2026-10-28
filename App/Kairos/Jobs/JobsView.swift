import Engine
import Jobs
import Screening
import Store
import SwiftUI
import Tailoring

/// Inbox, Saved and Skipped: the list of jobs in groups, and the selected job's pane. One key per
/// decision: B build, S save, X skip, O open posting, A mark applied, V verdict, R re-evaluate;
/// Return opens the job full width, Esc comes back.
struct JobsView: View {
    let section: AppSection
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.fullWidthJob, let id = model.selectedJob {
                FullWidthJob(id: id, list: list)
            } else {
                ListPaneLayout {
                    VStack(spacing: 0) {
                        ColumnTitle(title: section.title, line: line)
                        jobList
                    }
                } pane: {
                    if let id = model.selectedJob, list.contains(where: { $0.id == id }) {
                        JobPane(id: id)
                    } else {
                        emptyPane
                    }
                }
            }
        }
        .searchable(text: $model.jobQuery.search, placement: .toolbar, prompt: "Title, company or place")
        .toolbar { toolbar }
        .navigationTitle(section.title)
        .onAppear { if section == .inbox { model.markLooked() } }
        .onChange(of: section) { model.fullWidthJob = false }
    }

    private var list: [JobSummary] { model.jobs(in: section) }

    private var groups: [(JobLists.Group, [JobSummary])] {
        JobLists.groups(list, query: model.jobQuery, countries: model.preferences.countries)
    }

    private var ordered: [JobSummary] { groups.flatMap(\.1) }

    private var line: String {
        let decide = list.filter { $0.verdict != .no }.count
        switch section {
        case .inbox:
            let new = JobLists.newToday(list)
            return "\(decide) to decide · \(list.count - decide) no from the AI"
                + (new > 0 ? " · \(new) new today" : "")
        case .saved: return "\(list.count) saved"
        default: return "\(list.count) skipped or closed"
        }
    }

    private var jobList: some View {
        @Bindable var model = model
        return List(selection: $model.selectedJob) {
            ForEach(groups, id: \.0) { group, jobs in
                Section {
                    ForEach(jobs) { job in
                        JobRow(job: job, dimmed: job.verdict == .no || section == .skipped).tag(job.id)
                    }
                } header: {
                    GroupHeader(title: group.title, count: jobs.count)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if ordered.isEmpty { emptyList }
        }
        .onKeyPress(keys: ["b", "s", "x", "o", "a", "r", "v"]) { press in
            guard let id = model.selectedJob else { return .ignored }
            switch press.characters {
            case "b": model.build(id)
            case "s": model.toggleSave(id)
            case "x": model.skip(id)
            case "o": model.openPosting(id)
            case "a": model.markApplied(id)
            case "r": model.reevaluate(id)
            case "v": cycleVerdict(id)
            default: return .ignored
            }
            return .handled
        }
        .onKeyPress(.return) {
            guard model.selectedJob != nil else { return .ignored }
            model.fullWidthJob = true
            return .handled
        }
        .onAppear {
            if model.selectedJob.map({ id in !ordered.contains { $0.id == id } }) ?? true {
                model.selectedJob = ordered.first?.id
            }
        }
    }

    /// V: Yes, then Maybe, then No, then screening's own again.
    private func cycleVerdict(_ id: String) {
        let next: Verdict? =
            switch model.summary(id)?.screening?.yourVerdict {
            case nil: .yes
            case .yes?: .maybe
            case .maybe?: .no
            case .no?: nil
            }
        model.setVerdict(next, for: id)
    }

    @ViewBuilder private var emptyList: some View {
        switch section {
        case .inbox:
            if model.jobQuery.search.isEmpty {
                EmptyState(
                    "Nothing to decide", "Kairos checks your sources when you ask; new jobs land here once screened."
                ) {
                    Button("Find new jobs") { model.findNewJobs() }.disabled(model.activity.isRunning)
                }
            } else {
                EmptyState("No matches", "Nothing in the Inbox matches “\(model.jobQuery.search)”.")
            }
        case .saved: EmptyState("Nothing saved", "Save a job with S to keep it here until you apply.")
        default: EmptyState("Nothing skipped", "Jobs you skip, and judged jobs no longer posted, wait here.")
        }
    }

    @ViewBuilder private var emptyPane: some View {
        if section == .inbox {
            TodayPane()
        } else {
            EmptyState("No job selected", "Choose a job to see why Kairos judged it so.")
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        @Bindable var model = model
        ToolbarItemGroup {
            Menu {
                Picker("Verdict", selection: $model.jobQuery.verdict) {
                    Text("Any verdict").tag(Verdict?.none)
                    ForEach(Verdict.allCases, id: \.self) { Text($0.title).tag(Verdict?.some($0)) }
                }
                Picker("Country", selection: $model.jobQuery.country) {
                    Text("Any country").tag(Country?.none)
                    ForEach(Country.allCases, id: \.self) { Text($0.name).tag(Country?.some($0)) }
                }
            } label: {
                Label("Filter", systemImage: "line.3.horizontal.decrease")
            }
            Picker("Sort", selection: $model.jobQuery.sort) {
                ForEach(JobLists.Sort.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .help("Sort")
            Button {
                model.findNewJobs()
            } label: {
                Label("Find new jobs", systemImage: "arrow.clockwise")
            }
            .help("Check every source, then screen what's new (⌘R)")
            .disabled(model.activity.isRunning)
        }
    }
}

/// One job in a list: the verdict, the title, a meta line, the match at the trailing edge, and a
/// document glyph once a resume exists. 36 pt; dimmed rows use `ink-dimmed`.
struct JobRow: View {
    let job: JobSummary
    var dimmed = false

    var body: some View {
        HStack(spacing: Spacing.space3) {
            if let verdict = job.verdict {
                VerdictPill(verdict: verdict).frame(width: 74, alignment: .leading)
            } else {
                Text(job.screening?.stage == .filtered ? "Filtered" : "Waiting")
                    .font(TypeStyle.caption).foregroundStyle(Color(.inkSecondary)).frame(width: 74, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(job.title).font(TypeStyle.headline).foregroundStyle(primary).lineLimit(1)
                Text(meta).font(TypeStyle.callout).foregroundStyle(secondary).lineLimit(1)
            }
            Spacer(minLength: Spacing.space2)
            if job.build?.status == .done {
                Image(systemName: "doc.text").font(TypeStyle.callout).foregroundStyle(Color(.accentText))
                    .accessibilityLabel("Resume built")
            }
            Text(job.match.map { "\(Int(($0 * 100).rounded()))" } ?? "—")
                .font(TypeStyle.scoreSmall).foregroundStyle(primary)
                .frame(minWidth: 28, alignment: .trailing)
                .accessibilityLabel(job.match.map { "Match \(Int(($0 * 100).rounded()))" } ?? "No match score")
        }
        .frame(height: Spacing.rowHeight)
        .contentShape(Rectangle())
    }

    /// "Northline Freight · Toronto, ON", with the deciding reason for a Maybe or No.
    private var meta: String {
        var parts = [job.company]
        if !job.placeLine.isEmpty { parts.append(job.placeLine) }
        if job.verdict != .yes, let reason = job.screening?.reasons.first, job.verdict != nil {
            parts.append(reason)
        }
        return parts.joined(separator: " · ")
    }

    private var primary: Color { dimmed ? Color(.inkDimmed) : Color(.ink) }
    private var secondary: Color { dimmed ? Color(.inkDimmed) : Color(.inkSecondary) }
}

/// The Inbox's pane when nothing is selected: today's counts and what's due.
struct TodayPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.space6) {
                Text("Today").font(TypeStyle.title1).foregroundStyle(Color(.ink))
                HStack(spacing: Spacing.space3) {
                    tile("Yes", model.counts.yes, .yes)
                    tile("Maybe", model.counts.maybe, .maybe)
                    tile("No", model.counts.no, .no)
                }
                let due = model.applications.filter { $0.followUpAt.map { $0 <= Date() } ?? false }
                PaneSection(title: "Follow-ups due", trailing: "\(due.count)") {
                    if due.isEmpty {
                        Text("Nothing due.").font(TypeStyle.body).foregroundStyle(Color(.inkSecondary))
                    }
                    ForEach(due) { application in
                        Text(model.summary(application.jobID).map { "\($0.title) at \($0.company)" } ?? "A job")
                            .font(TypeStyle.body).foregroundStyle(Color(.ink))
                    }
                }
                PaneSection(title: "Saved", trailing: "\(model.saved.count)") {
                    ForEach(model.saved.prefix(5)) { job in
                        Text("\(job.title) at \(job.company)").font(TypeStyle.body).foregroundStyle(Color(.ink))
                    }
                }
            }
            .padding(Spacing.space7)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tile(_ title: String, _ count: Int, _ verdict: Verdict) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.space1) {
                Label(title, systemImage: verdict.symbol).font(TypeStyle.headline).foregroundStyle(verdict.color)
                Text("\(count)").font(TypeStyle.score).foregroundStyle(Color(.ink))
            }
        }
    }
}

/// A job full width (Return): Back, Previous and Next, and the same pane.
struct FullWidthJob: View {
    let id: String
    let list: [JobSummary]
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.space2) {
                Button {
                    model.fullWidthJob = false
                } label: {
                    Label(model.section.title, systemImage: "chevron.left")
                }
                .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Previous") { move(-1) }.keyboardShortcut(.upArrow, modifiers: []).disabled(index == 0)
                Button("Next") { move(1) }.keyboardShortcut(.downArrow, modifiers: [])
                    .disabled(index.map { $0 + 1 >= list.count } ?? true)
            }
            .padding(.horizontal, Spacing.space6)
            .padding(.vertical, Spacing.space3)
            Divider()
            JobPane(id: id).background(Color(.surface))
        }
    }

    private var index: Int? { list.firstIndex { $0.id == id } }

    private func move(_ step: Int) {
        guard let index, list.indices.contains(index + step) else { return }
        model.selectedJob = list[index + step].id
    }
}
