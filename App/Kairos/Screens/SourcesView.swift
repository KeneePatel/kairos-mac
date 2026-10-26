import Screening
import Store
import SwiftUI

/// Sources (UI v2): the companies and boards Kairos watches in a table, with the chosen board
/// beside it: its status, the open roles it has for you, what the filters dropped from it, and
/// Pause or Stop watching. The toolbar holds the scope, the search, Add, the Posted limit and
/// Find new jobs.
struct SourcesView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [JobID] = []
    @State private var selection: Source.ID?
    @State private var scope = SourcesTable.Scope.yours
    @State private var search = ""
    @State private var addingCompany = false
    @State private var addingAdzuna = false
    @State private var addingSearch: SearchChoice?
    @State private var clearing: JobRepository.Clearing?

    /// Which optional search's sheet is open.
    struct SearchChoice: Identifiable {
        let kind: SourceKind
        var id: String { kind.rawValue }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ListPaneLayout(listWidth: 640) {
                VStack(spacing: 0) {
                    ColumnTitle(title: "Sources", line: countLine)
                    SourcesTable(selection: $selection, scope: scope, search: search)
                    Divider()
                    Text("↑↓ move · ↩ open the board · P pause or resume")
                        .font(TypeStyle.caption).foregroundStyle(Color(.inkSecondary)).lineLimit(1)
                        .padding(.horizontal, Spacing.space6).padding(.vertical, Spacing.space3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } pane: {
                if let id = selection, let source = model.source(id) {
                    SourcePane(source: source, changeAdzuna: { addingAdzuna = true }) { path.append($0) }
                } else {
                    VStack(spacing: Spacing.space1) {
                        Text("Nothing selected").font(TypeStyle.title2).foregroundStyle(Color(.ink))
                        Text("Choose a company in the table.").font(TypeStyle.body)
                            .foregroundStyle(Color(.inkSecondary))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Sources")
            .searchable(text: $search, placement: .toolbar, prompt: "Search companies")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Picker("Show", selection: $scope) {
                        ForEach(SourcesTable.Scope.allCases) { scope in
                            Text("\(scope.rawValue) \(count(scope))").tag(scope)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden().monospacedDigit().fixedSize()
                    Menu {
                        Button("Company board…") { addingCompany = true }
                        Button(model.adzunaSource == nil ? "Adzuna search…" : "Change Adzuna keys…") {
                            addingAdzuna = true
                        }
                        Button(
                            model.source(of: .himalayas) == nil ? "Himalayas remote jobs…" : "Change Himalayas key…"
                        ) {
                            addingSearch = SearchChoice(kind: .himalayas)
                        }
                        Button(model.source(of: .googleJobs) == nil ? "Google Jobs (SerpApi)…" : "Change SerpApi key…")
                        {
                            addingSearch = SearchChoice(kind: .googleJobs)
                        }
                    } label: {
                        Label("Add", systemImage: "plus").labelStyle(.titleAndIcon)
                    }
                    PostedWithinMenu()
                    Menu {
                        Button("Delete all jobs…", role: .destructive) {
                            Task { clearing = await model.clearingPreview() }
                        }
                        .disabled(model.isFetching || model.jobs.isEmpty)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .help("More actions")
                }
                RunControls(model: model, title: "Find new jobs")
            }
            .navigationDestination(for: JobID.self) { JobScreen(id: $0) }
        }
        .task(id: model.sources.map(\.id)) {
            if selection.map({ model.source($0) == nil }) ?? true {
                selection = model.sources.first { !$0.isFromCatalog }?.id ?? model.sources.first?.id
            }
        }
        .sheet(isPresented: $addingCompany) { AddCompanySheet() }
        .sheet(isPresented: $addingAdzuna) { AdzunaSheet() }
        .sheet(item: $addingSearch) { choice in SearchSourceSheet(kind: choice.kind) }
        .confirmationDialog(
            "Delete all jobs?",
            isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } }),
            titleVisibility: .visible, presenting: clearing
        ) { plan in
            Button("Delete \(plan.deleted) job\(plan.deleted == 1 ? "" : "s")", role: .destructive) {
                Task { await model.deleteAllJobs() }
            }
            .disabled(plan.deleted == 0)
        } message: { plan in
            Text(Self.clearingMessage(plan))
        }
    }

    private func count(_ scope: SourcesTable.Scope) -> Int {
        switch scope {
        case .yours: model.sources.count { !$0.isFromCatalog }
        case .catalog: model.sources.count(where: \.isFromCatalog)
        case .all: model.sources.count
        }
    }

    /// "27 companies you added · 794 from the catalog · checked 12:39 AM".
    private var countLine: String {
        let yours = count(.yours)
        let catalog = count(.catalog)
        var parts = ["\(yours) compan\(yours == 1 ? "y" : "ies") you added"]
        if catalog > 0 { parts.append("\(catalog) from the catalog") }
        if let checked = model.sources.compactMap(\.lastRunAt).max() {
            parts.append("checked \(SourcesTable.checked(checked))")
        }
        return parts.joined(separator: " · ")
    }

    /// "Deletes 1,612 jobs, with their verdicts and analyses. The 3 you saved, … stay."
    static func clearingMessage(_ plan: JobRepository.Clearing) -> String {
        var kept: [String] = []
        if plan.saved > 0 { kept.append("\(plan.saved) you saved") }
        if plan.built > 0 { kept.append("\(plan.built) you built a resume for") }
        if plan.applied > 0 { kept.append("\(plan.applied) you applied to") }
        let stay =
            kept.isEmpty
            ? "" : " The " + ListFormatter.localizedString(byJoining: kept) + " stay."
        return
            "Deletes \(plan.deleted) job\(plan.deleted == 1 ? "" : "s"), with their verdicts and analyses.\(stay) Jobs still posted come back on your next Find new jobs, screened afresh."
    }
}

/// "Posted: past week": how recent a posting must be to be fetched at all. Older ones are never
/// stored, so they don't fill Filtered out; a posting with no date is kept. It's Search's
/// posting-age limit, kept here because it acts while fetching.
struct PostedWithinMenu: View {
    @Environment(AppModel.self) private var model

    static let choices: [(days: Int?, title: String)] = [
        (nil, "Any time"), (1, "Past day"), (3, "Past 3 days"), (7, "Past week"), (14, "Past 2 weeks"),
        (30, "Past month"), (60, "Past 2 months"),
    ]

    private var current: Int? { model.searchPreferences.maxAgeDays }

    /// A limit set before the menu existed (28 days, say) stays a choice.
    private var choices: [(days: Int?, title: String)] {
        guard let current, !Self.choices.contains(where: { $0.days == current }) else { return Self.choices }
        return Self.choices + [(current, "Past \(current) days")]
    }

    var body: some View {
        Menu {
            ForEach(choices, id: \.title) { choice in
                Button {
                    var preferences = model.searchPreferences
                    preferences.maxAgeDays = choice.days
                    Task { await model.save(preferences) }
                } label: {
                    if choice.days == current {
                        Label(choice.title, systemImage: "checkmark")
                    } else {
                        Text(choice.title)
                    }
                }
            }
        } label: {
            Label(
                "Posted: \(choices.first { $0.days == current }?.title.lowercased() ?? "any time")",
                systemImage: "calendar"
            )
            .labelStyle(.titleAndIcon)
        }
        .help("Fetch only jobs posted this recently. Older postings aren't saved at all; undated ones are kept.")
    }
}
