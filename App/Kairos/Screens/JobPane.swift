import Screening
import Store
import SwiftUI

/// One job (UI v2, ADR-017): the pane beside the Inbox, Saved and Skipped lists, and the page a job
/// opens full width on Return. The posting's facts, the decisions with their keys, the verdict and
/// the reason, every requirement as it was matched with the evidence quoted, where it's posted,
/// then the posting in full. Re-evaluate asks the AI again. Once the job has a build, Resume opens
/// its resume page.
struct JobPane: View {
    @Environment(AppModel.self) private var model
    let id: JobID
    /// The list this job came from: its actions differ (Skipped offers Bring back, not Skip).
    var scope = JobsScope.inbox
    /// Full width (Return): wider columns and the whole posting without a scroll of its own.
    var full = false

    @State private var stored: StoredAnalysis?
    @State private var reevaluating = false
    @State private var problem: String?
    @State private var confirmingApplied = false
    @AppStorage("buildCoverLetter") private var coverLetter = false
    @State private var showingResume = false
    @State private var listings: [Listing] = []
    @State private var history: [JobEvent] = []

    init(
        id: JobID, scope: JobsScope = .inbox, full: Bool = false, preview: StoredAnalysis? = nil,
        listings: [Listing] = [], history: [JobEvent] = []
    ) {
        self.id = id
        self.scope = scope
        self.full = full
        _stored = State(initialValue: preview)
        _listings = State(initialValue: listings)
        _history = State(initialValue: history)
    }

    private var job: Job? { model.job(id) }

    var body: some View {
        Group {
            if let job {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.space6) {
                        header(job)
                        actions(job)
                        verdict(job)
                        if let analysis = stored?.analysis { requirements(analysis) }
                        if !listings.isEmpty { wherePosted(job) }
                        posting(job)
                    }
                    .padding(.horizontal, Spacing.space7)
                    .padding(.vertical, Spacing.space6)
                    .frame(maxWidth: full ? 920 : .infinity, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            } else {
                EmptyState("This job is gone", "It was deleted or tidied away.")
            }
        }
        .background(Color(.surface))
        .navigationDestination(isPresented: $showingResume) { BuildsView(job: id) }
        // Reloads when the job's verdict is recorded again (a re-evaluation or a re-screen).
        .task(id: "\(id.rawValue)-\(job.flatMap { model.screening(for: $0)?.at.timeIntervalSince1970 } ?? 0)") {
            if let job { stored = await model.storedAnalysis(for: job) ?? stored }
        }
        // Reloads when a fetch sees the job again, or it closes.
        .task(id: "\(id.rawValue)-\(job?.lastSeenAt?.timeIntervalSince1970 ?? 0)-\(job?.isOpen ?? true)") {
            guard let job else { return }
            let found = await model.postings(of: job)
            if !found.listings.isEmpty { (listings, history) = found }
        }
        .alert("Couldn't do that", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
        .confirmationDialog(
            "Mark applied without a resume?", isPresented: $confirmingApplied, titleVisibility: .visible
        ) {
            Button("Mark applied") { if let job { Task { await model.markApplied(job) } } }
        } message: {
            Text("Kairos records that you applied with your master resume as it is. Build one first if you'd rather.")
        }
    }

    // MARK: - Header and actions

    private func header(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            HStack(spacing: Spacing.space1) {
                // Adzuna's terms ask that its listings name it, linked: the credit replaces "via".
                if model.source(job.sourceID)?.kind == .adzuna {
                    Text("\(job.company) ·").font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                    AdzunaCredit()
                } else {
                    Text(Self.companyLine(job, source: model.source(job.sourceID)))
                        .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                }
            }
            Text(job.title).font(TypeStyle.title1).foregroundStyle(Color(.ink))
            if let closed = job.closedAt {
                // Not a verdict, but still never colour alone: an icon and the words.
                Label(
                    "No longer posted: gone from every source since \(closed.formatted(date: .abbreviated, time: .omitted))",
                    systemImage: "archivebox"
                )
                .font(TypeStyle.callout.weight(.medium)).foregroundStyle(Color(.inkSecondary))
            }
            Text(
                [
                    job.location.isEmpty ? job.placeLabel : job.location, job.workLabel,
                    job.postedAt.map { "Posted \($0.formatted(.relative(presentation: .named)))" },
                    "First seen \(job.firstSeenAt.formatted(.dateTime.month(.abbreviated).day()))",
                ].compactMap { $0 }.filter { $0 != "—" }.joined(separator: " · ")
            )
            .font(TypeStyle.callout).foregroundStyle(Color(.ink2))
        }
    }

    /// The decisions, each with its key: one primary (Build, or Resume once built), then Save,
    /// Skip or Bring back, Open posting, and the rare ones in More.
    private func actions(_ job: Job) -> some View {
        let applied = model.application(for: job) != nil
        let latest = model.latestBuild(for: job)
        return HStack(spacing: Spacing.space2) {
            if let latest {
                Button {
                    showingResume = true
                } label: {
                    ActionLabel(
                        title: latest.status == .queued || latest.status == .running ? "Building resume…" : "Resume",
                        key: nil, primary: true)
                }
                .buttonStyle(.borderedProminent)
                .help("Your resume and cover letter for this job, with its build history.")
            } else {
                Button {
                    Task { problem = await model.startBuild(for: job, coverLetter: coverLetter, show: false) }
                } label: {
                    ActionLabel(title: "Build resume", key: "B", primary: true)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.buildBlocked(job, analysed: stored != nil) != nil)
                .help(model.buildBlocked(job, analysed: stored != nil) ?? "Tailor a resume for this job.")
            }
            if !applied {
                if job.state == .shortlisted {
                    Button {
                        Task { await model.unsave(job) }
                    } label: {
                        ActionLabel(title: "Unsave", key: "S")
                    }
                    .help("Back to the Inbox.")
                } else {
                    Button {
                        Task { await model.save(job) }
                    } label: {
                        ActionLabel(title: "Save", key: "S")
                    }
                    .help("Keep it in Saved for later.")
                }
                if job.state == .skipped {
                    Button {
                        Task { await model.unskip(job) }
                    } label: {
                        ActionLabel(title: "Bring back", key: "X")
                    }
                    .help("Back to the Inbox.")
                } else {
                    Button {
                        Task { await model.skip(job) }
                    } label: {
                        ActionLabel(title: "Skip", key: "X")
                    }
                    .help("Not for you. It moves to Skipped; ⌘Z brings it back.")
                }
            }
            Button {
                model.openPosting(job)
            } label: {
                ActionLabel(title: "Open posting", key: "O")
            }
            .help("Opens the posting in your browser.")
            Menu {
                if applied {
                    Button("Open the application") {
                        if let application = model.application(for: job) {
                            model.openApplication(application.id)
                        }
                    }
                } else {
                    Button("Mark applied") {
                        if latest == nil { confirmingApplied = true } else { Task { await model.markApplied(job) } }
                    }
                }
                Menu("Change verdict") {
                    ForEach(Verdict.allCases, id: \.self) { verdict in
                        Button(verdict.title) { Task { await model.overrule(job, to: verdict) } }
                            .disabled(verdict == job.verdict)
                    }
                }
                Button("Re-evaluate") {
                    Task {
                        reevaluating = true
                        problem = await model.reevaluate(job)
                        stored = await model.storedAnalysis(for: job)
                        reevaluating = false
                    }
                }
                .disabled(reevaluating)
                Divider()
                Toggle("Write a cover letter with each build", isOn: $coverLetter)
                Button("Copy link") { model.copyLink(job) }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Mark applied, change the verdict, re-evaluate, copy the link")
            if applied {
                Label("Applied", systemImage: "paperplane").font(TypeStyle.callout)
                    .foregroundStyle(Color(.inkSecondary))
            }
        }
    }

    // MARK: - Verdict

    /// The score, the verdict with its deciding reason, what the AI read, and who decided.
    private func verdict(_ job: Job) -> some View {
        let record = model.screening(for: job)
        return HStack(alignment: .top, spacing: Spacing.space5) {
            if let score = model.matchScore(for: job) {
                VStack(spacing: 0) {
                    Text("\(score)").font(TypeStyle.score).foregroundStyle(Color(.ink))
                    Text("Match").font(TypeStyle.caption).foregroundStyle(Color(.inkSecondary))
                }
            }
            VStack(alignment: .leading, spacing: Spacing.space2) {
                HStack(spacing: Spacing.space3) {
                    if let verdict = job.verdict { VerdictPill(verdict: verdict, large: true) }
                    if reevaluating {
                        ProgressView().controlSize(.small)
                        Text("Asking the AI again…").font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                    }
                }
                if let reason = record?.reasons.first {
                    Text(reason).font(TypeStyle.body).foregroundStyle(Color(.ink))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let analysis = stored?.analysis {
                    Text(Self.read(analysis)).font(TypeStyle.callout).foregroundStyle(Color(.ink2))
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(notes(job), id: \.self) { note in
                    Text(note).font(TypeStyle.callout).foregroundStyle(Color(.ink2))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(provenance(record)).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                    .help(decidedBy(record))
                if let blocked = model.buildBlocked(job, analysed: stored != nil) {
                    Label(blocked, systemImage: "lock").font(TypeStyle.callout)
                        .foregroundStyle(Color(.inkSecondary)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Spacing.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Color(.surfaceRaised)))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Color(.separator), lineWidth: 1))
    }

    /// "3+ years · Intermediate level · No sponsorship · French an asset · logistics".
    static func read(_ analysis: JobAnalysis) -> String {
        let flags = analysis.flags
        let parts = [
            analysis.yearsRequired.map { "\($0)+ years" }, analysis.seniority.map { $0.title + " level" },
            flags.sponsorship == .notMentioned
                ? nil : flags.sponsorship == .offered ? "Offers sponsorship" : "No sponsorship",
            flags.clearance == .notMentioned
                ? nil : "Clearance \(flags.clearance == .required ? "required" : "obtainable")",
            flags.french == .notMentioned ? nil : "French \(flags.french == .required ? "required" : "an asset")",
            analysis.domains.isEmpty ? nil : analysis.domains.joined(separator: ", "),
        ].compactMap { $0 }
        return parts.isEmpty ? "No years, level or conditions named." : parts.joined(separator: " · ")
    }

    /// "Decided by code from the AI's reading · 1 hour ago · gemini-flash-lite-latest".
    private func provenance(_ record: ScreeningRecord?) -> String {
        var parts = [decidedBy(record)]
        if let stored {
            parts.append(stored.analyzedAt.formatted(.relative(presentation: .named)))
            parts.append(stored.model)
        }
        return parts.joined(separator: " · ")
    }

    private func decidedBy(_ record: ScreeningRecord?) -> String {
        switch record?.stage {
        case .prefilter?: "Decided by your filters, before any AI call"
        case .analysis?: "Decided by code from the AI's reading"
        case .user?: "You decided"
        case nil: "Not screened yet"
        }
    }

    /// Everything after the deciding reason except the coverage line, which the groups show.
    private func notes(_ job: Job) -> [String] {
        Array((model.screening(for: job)?.reasons ?? []).dropFirst()).filter { !$0.hasPrefix("Covers ") }
    }

    // MARK: - Requirements

    /// Must-haves and nice-to-haves side by side when there's room, else stacked.
    private func requirements(_ analysis: JobAnalysis) -> some View {
        let must = analysis.requirements.filter { $0.kind == .must }
        let nice = analysis.requirements.filter { $0.kind == .nice }
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Spacing.space6) {
                group("Must-haves", must).frame(minWidth: 320, maxWidth: .infinity, alignment: .topLeading)
                group("Nice-to-haves", nice).frame(minWidth: 320, maxWidth: .infinity, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: Spacing.space6) {
                group("Must-haves", must)
                group("Nice-to-haves", nice)
            }
        }
    }

    private func group(_ title: String, _ items: [JobAnalysis.Requirement]) -> some View {
        let profile = model.screeningProfile
        return VStack(alignment: .leading, spacing: Spacing.space3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(TypeStyle.title2).foregroundStyle(Color(.ink))
                Spacer()
                Text(items.isEmpty ? "None listed" : items.shownSummary).font(TypeStyle.callout)
                    .foregroundStyle(Color(.inkSecondary)).monospacedDigit()
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, requirement in
                RequirementRow(requirement: requirement) { profile?.describe($0) }
            }
        }
    }

    // MARK: - Where it's posted and the posting

    private func wherePosted(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Where it's posted").font(TypeStyle.title2).foregroundStyle(Color(.ink))
                Spacer()
                Text(seenLine(job)).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            }
            VStack(spacing: 0) {
                ForEach(Array(listings.enumerated()), id: \.element.id) { index, listing in
                    if index > 0 { Divider().overlay(Color(.separatorRow)) }
                    listingRow(listing, shown: listing.id == (job.primaryListingID ?? job.id))
                }
            }
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(Color(.surfaceRaised)))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Color(.separator), lineWidth: 1))
            if !history.isEmpty {
                Text(history.map(describe).joined(separator: " · ")).font(TypeStyle.callout)
                    .foregroundStyle(Color(.inkSecondary)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func listingRow(_ listing: Listing, shown: Bool) -> some View {
        let source = model.source(listing.sourceID)
        return HStack(spacing: Spacing.space3) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.space1) {
                    if source?.kind == .adzuna {
                        AdzunaCredit()
                    } else {
                        Text(source.map(Self.boardName) ?? "A removed source")
                            .font(TypeStyle.callout.weight(.semibold)).foregroundStyle(Color(.ink))
                    }
                    if shown {
                        Text("· shown here").font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                    }
                }
                Text(listingLine(listing)).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            }
            Spacer()
            if let url = URL(string: listing.url) {
                Link(destination: url) { Label("Open", systemImage: "arrow.up.right.square") }
                    .font(TypeStyle.callout)
            }
        }
        .padding(.horizontal, Spacing.space3)
        .padding(.vertical, Spacing.space2)
    }

    /// "Scotiabank · posted on its own site · found on Google Jobs", "Softline Technology · posted
    /// on Indeed · found on Google Jobs", or "Stripe · via Greenhouse" for a board's job.
    static func companyLine(_ job: Job, source: Source?) -> String {
        guard let source else { return job.company }
        guard let via = job.via, !via.isEmpty else { return "\(job.company) · via \(source.kind.displayName)" }
        let own = via.compare(job.company, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        return "\(job.company) · posted on \(own ? "its own site" : via) · found on \(source.kind.displayName)"
    }

    /// "Stripe on Greenhouse", or "A Greenhouse board" when you didn't name the company.
    static func boardName(_ source: Source) -> String {
        source.displayName == source.kind.displayName
            ? "A \(source.kind.displayName) board" : "\(source.displayName) on \(source.kind.displayName)"
    }

    /// "Full posting · open, seen today", "Snippet · closed Oct 30".
    private func listingLine(_ listing: Listing) -> String {
        let text =
            switch listing.descriptionKind {
            case .full: "Full posting"
            case .snippet: "Snippet"
            case .none: "No description"
            }
        let state =
            listing.closedAt.map { "closed \($0.formatted(date: .abbreviated, time: .omitted))" }
            ?? "open, seen \(listing.lastSeenAt.formatted(.relative(presentation: .named)))"
        return "\(text) · \(state)"
    }

    private func seenLine(_ job: Job) -> String {
        let first = "First seen \(job.firstSeenAt.formatted(date: .abbreviated, time: .omitted))"
        guard let last = job.lastSeenAt else { return first }
        return first + " · last seen \(last.formatted(.relative(presentation: .named)))"
    }

    /// "Found on Greenhouse Oct 20", "Also on Adzuna Oct 21", "Closed Oct 30".
    private func describe(_ event: JobEvent) -> String {
        let source = event.sourceID.flatMap { model.source($0) }.map { " on \($0.kind.displayName)" } ?? ""
        let date = event.at.formatted(.dateTime.month(.abbreviated).day())
        switch event.kind {
        case .found: return "Found\(source) \(date)"
        case .postedElsewhere: return "Also\(source) \(date)"
        case .changed: return "Edited\(source) \(date)"
        case .upgraded: return "Full posting\(source) \(date)"
        case .closed: return "Closed \(date)"
        case .reopened: return "Back again \(date)"
        }
    }

    @ViewBuilder private func posting(_ job: Job) -> some View {
        if let description = job.descriptionMarkdown, !description.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.space3) {
                Text("The posting").font(TypeStyle.title2).foregroundStyle(Color(.ink))
                MarkdownView(description)
            }
        }
    }
}
