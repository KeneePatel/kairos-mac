import JobSources
import Pipeline
import Screening
import Store
import SwiftUI

/// Where jobs come from (job collection v3, C4): the channels, each with this week's yield and one
/// line of settings. Company boards opens the companies list; a search opens its own page. The
/// toolbar holds Add, the Posted limit, More and Find new jobs.
enum Channel: String, CaseIterable, Identifiable, Hashable {
    case boards, googleJobs, himalayas, adzuna

    var id: Self { self }

    var title: String {
        switch self {
        case .boards: "Company boards"
        case .googleJobs: "Google Jobs"
        case .himalayas: "Himalayas"
        case .adzuna: "Adzuna leads"
        }
    }

    var symbol: String {
        switch self {
        case .boards: "building.2"
        case .googleJobs: "magnifyingglass"
        case .himalayas: "globe.americas"
        case .adzuna: "list.bullet.rectangle"
        }
    }

    /// The search source behind a channel; nil for the boards.
    var kind: SourceKind? {
        switch self {
        case .boards: nil
        case .googleJobs: .googleJobs
        case .himalayas: .himalayas
        case .adzuna: .adzuna
        }
    }

    /// What the channel is for, in one line.
    var purpose: String {
        switch self {
        case .boards: "Every open job of the companies Kairos watches, read in full from their own boards."
        case .googleJobs:
            "Employers on Workday, LinkedIn, Indeed and other sites Kairos can't read itself, through SerpApi."
        case .himalayas: "Remote roles open to your countries, in full, with each job's own application link."
        case .adzuna: "Which companies post at your roles: never jobs, since Adzuna sends snippets, but boards to find."
        }
    }
}

struct SourcesView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [Channel] = []
    @State private var addingCompany = false
    @State private var addingAdzuna = false
    @State private var addingSearch: SearchChoice?
    @State private var clearing: JobRepository.Clearing?
    @State private var facts = AppModel.ChannelFacts()

    /// Which optional search's sheet is open.
    struct SearchChoice: Identifiable {
        let kind: SourceKind
        var id: String { kind.rawValue }
    }

    var body: some View {
        NavigationStack(path: $path) {
            channels
                .navigationTitle("Sources")
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
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
                            Button(
                                model.source(of: .googleJobs) == nil ? "Google Jobs (SerpApi)…" : "Change SerpApi key…"
                            ) {
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
                .navigationDestination(for: Channel.self) { channel in
                    if channel == .boards {
                        CompaniesView(addCompany: { addingCompany = true }, changeAdzuna: { addingAdzuna = true })
                    } else {
                        ChannelView(
                            channel: channel, facts: facts,
                            changeKey: {
                                if channel == .adzuna {
                                    addingAdzuna = true
                                } else if let kind = channel.kind {
                                    addingSearch = SearchChoice(kind: kind)
                                }
                            })
                    }
                }
        }
        .task(id: model.lastFetch?.id) { facts = await model.channelFacts() }
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

    /// The channels, each a row: its name, this week's yield, and where it stands.
    private var channels: some View {
        VStack(spacing: 0) {
            ColumnTitle(title: "Sources", line: countLine)
            List {
                ForEach(Channel.allCases) { channel in
                    NavigationLink(value: channel) { row(channel) }
                        .listRowInsets(EdgeInsets(top: 0, leading: Spacing.space4, bottom: 0, trailing: Spacing.space4))
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
        .background(Color(.surface))
    }

    private func row(_ channel: Channel) -> some View {
        HStack(alignment: .top, spacing: Spacing.space3) {
            Image(systemName: channel.symbol).font(TypeStyle.title2).foregroundStyle(Color(.inkSecondary))
                .frame(width: 28).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.title).font(TypeStyle.headline).foregroundStyle(Color(.ink))
                Text(model.channelLine(channel, facts: facts)).font(TypeStyle.callout)
                    .foregroundStyle(Color(.inkSecondary)).lineLimit(2)
                Text(channel.purpose).font(TypeStyle.caption).foregroundStyle(Color(.inkSecondary)).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.space3)
    }

    /// "4 channels · 163 companies hiring for you · checked 12:39 AM".
    private var countLine: String {
        var parts = ["\(Channel.allCases.count) channels"]
        let hiring = model.rolesBySource.filter { $0.value > 0 }.count
        parts.append("\(hiring) compan\(hiring == 1 ? "y" : "ies") hiring for you")
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
