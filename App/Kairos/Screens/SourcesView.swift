import Screening
import Store
import SwiftUI

/// Sources (UI v2, 2026-10-26; the Find jobs page until then): the companies and boards Kairos
/// watches, with Add, the Posted limit, and Find new jobs. What the last run did is the sidebar's
/// status line; what the filters dropped is in Filtered out.
struct SourcesView: View {
    @Environment(AppModel.self) private var model
    @State private var addingCompany = false
    @State private var addingAdzuna = false
    @State private var addingSearch: SearchChoice?

    /// Which optional search's sheet is open.
    struct SearchChoice: Identifiable {
        let kind: SourceKind
        var id: String { kind.rawValue }
    }
    @State private var clearing: JobRepository.Clearing?

    var body: some View {
        // One container: the table's body is two sibling views, and a toolbar on a tuple of views
        // is added once per view.
        VStack(spacing: 0) { SourcesTable() }
            .navigationTitle("Sources")
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Company board…") { addingCompany = true }
                        Button(model.adzunaSource == nil ? "Adzuna search…" : "Change Adzuna keys…") {
                            addingAdzuna = true
                        }
                        Button(model.source(of: .himalayas) == nil ? "Himalayas remote jobs…" : "Change Himalayas key…")
                        {
                            addingSearch = SearchChoice(kind: .himalayas)
                        }
                        Button(model.source(of: .googleJobs) == nil ? "Google Jobs (SerpApi)…" : "Change SerpApi key…")
                        {
                            addingSearch = SearchChoice(kind: .googleJobs)
                        }
                    } label: {
                        Label("Add", systemImage: "plus").labelStyle(.titleAndIcon)
                    }
                }
                ToolbarItem(placement: .primaryAction) { PostedWithinMenu() }
                ToolbarItem(placement: .primaryAction) {
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

    private var subtitle: String {
        let count = model.sources.count
        let watched = "\(count) compan\(count == 1 ? "y" : "ies") watched"
        guard let checked = model.sources.compactMap(\.lastRunAt).max() else { return watched }
        return "\(watched) · checked \(checked.formatted(date: .omitted, time: .shortened))"
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
/// stored, so they don't fill Prefiltered; a posting with no date is kept. It's Search's posting-age
/// limit, moved here from Settings because it now acts while fetching.
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
