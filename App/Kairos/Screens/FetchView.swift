import Screening
import Store
import SwiftUI

/// Find jobs (polish P3; renamed 2026-10-22): the first step of the workflow. Find new jobs checks
/// every board and screens what's new; under it, the last run, what your filters dropped and why
/// (all of it in Filtered out), and the companies you watch.
struct FetchView: View {
    @Environment(AppModel.self) private var model
    @State private var addingCompany = false
    @State private var addingAdzuna = false
    @State private var clearing: JobRepository.Clearing?

    var body: some View {
        VStack(spacing: 0) {
            // The panels get their full height first and the table takes what's left. The priority does
            // this, not fixedSize on the text: the window's minimum height is measured at the narrowest
            // width, where fixed text wraps a word a line and asked for 1,185 points, taller than a
            // laptop screen, so opening Find jobs pushed the window off it.
            summary
                .padding(Spacing.space5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.surface))
                .layoutPriority(1)
            Divider()
            SourcesTable()
        }
        .navigationTitle("Find jobs")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Company board…") { addingCompany = true }
                    Button(model.adzunaSource == nil ? "Adzuna search…" : "Change Adzuna keys…") { addingAdzuna = true }
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

    /// Three panels side by side: the last run, what your filters dropped, and what waits for AI.
    private var summary: some View {
        HStack(alignment: .top, spacing: Spacing.space4) {
            panel("Last run", symbol: "clock") {
                Text(model.runSummary).font(TypeStyle.body).foregroundStyle(Color(.ink))
                if model.lastScreening != nil {
                    Button("Review the results") { model.section = .review }
                        .buttonStyle(.link)
                }
            }
            panel("Filtered out", symbol: "line.3.horizontal.decrease.circle") {
                if model.droppedByRule.isEmpty {
                    Text("Nothing yet.").font(TypeStyle.body).foregroundStyle(Color(.inkSecondary))
                } else {
                    ForEach(model.droppedByRule.prefix(6), id: \.rule) { row in
                        HStack {
                            Text(row.rule.reason).font(TypeStyle.body).foregroundStyle(Color(.ink))
                            Spacer()
                            Text("\(row.count)").font(TypeStyle.body).monospacedDigit()
                                .foregroundStyle(Color(.inkSecondary))
                        }
                    }
                    Button("See them in Filtered out") { model.section = .filtered }
                        .buttonStyle(.link)
                }
            }
            panel("Waiting for the AI", symbol: "hourglass") {
                Text(model.waitingForAI == 0 ? "Nothing waiting." : "\(model.waitingForAI) jobs passed your filters")
                    .font(TypeStyle.body).foregroundStyle(Color(.ink))
                Text(
                    model.waitingForAI == 0
                        ? "Every job that passed your filters has a verdict."
                        : "They're analysed on the next run once an AI key is set."
                )
                .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            }
        }
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

    private func panel(_ title: String, symbol: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Label(title, systemImage: symbol).font(TypeStyle.headline).foregroundStyle(Color(.ink))
            content()
        }
        .padding(Spacing.space4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Radius.row).fill(Color(.surfaceGrouped)))
    }
}

extension PrefilterRule {
    /// Why the prefilter dropped a job, as a list label.
    var reason: String {
        switch self {
        case .titleInclude: "Title not in your list"
        case .titleExclude: "Title you skip"
        case .seniority: "Level you've turned off"
        case .yearsRequired: "Asks for too many years"
        case .location: "Outside your countries or regions"
        case .remoteScope: "Remote only elsewhere"
        case .workAuthorization: "Work authorization"
        case .clearance: "Needs a security clearance"
        case .french: "Needs French"
        case .blacklist: "Company you've blocked"
        case .postingAge: "Older than your limit"
        case .alreadyApplied: "Already applied"
        }
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
