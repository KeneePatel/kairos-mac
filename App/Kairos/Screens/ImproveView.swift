import Pipeline
import Screening
import Store
import SwiftUI

/// Improve (P11, 2026-10-22): what keeps Review's No and Maybe jobs from a Yes, as fixes ranked by
/// how many verdicts each could move, with what your master resume already shows and what to do.
/// Search fixes and reasons no resume changes stand apart. A report (your choice): it changes
/// nothing, and each job opens its own page. "Ask the AI" points at your roles and projects that
/// might show a fix, as questions, for one call. Design: the Resume Reach proposal.
struct ImproveView: View {
    /// A row of the list.
    enum Item: Hashable {
        case fix(String)
        case snippets
        case title(String)
        case yearsLimit
        case held(VerdictRule)
        case oneOffs
    }

    @Environment(AppModel.self) private var model
    @State private var report: ImproveReport?
    @State private var choice: Item?
    @State private var path: [JobID] = []
    /// What the AI said this session, by fix.
    @State private var answers: [String: Result<SuggestEvidenceTask.Output, AppModel.SuggestionProblem>] = [:]
    @State private var asking: String?

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Improve")
                .navigationDestination(for: JobID.self) { JobScreen(id: $0) }
        }
        // Worked out again when verdicts, your resume or your title list change.
        .task(id: reloadKey) {
            report = await model.improveReport()
            if let report, choice.map({ !Self.items(report).contains($0) }) ?? true {
                choice = Self.items(report).first
            }
        }
    }

    private var reloadKey: String {
        let screened = model.screenings.values.map(\.at).max()?.timeIntervalSince1970 ?? 0
        return [
            "\(model.jobs.count)", "\(screened)", "\(model.resume?.resume.version ?? 0)",
            model.searchPreferences.titleInclude.joined(separator: "|"),
        ].joined(separator: "-")
    }

    private var subtitle: String {
        guard let report, report.analysed > 0 else { return "" }
        let from = "\(report.analysed) No and Maybe job\(report.analysed == 1 ? "" : "s") analysed"
        return report.considered < 20 ? from + " · early days, patterns firm up with more" : from
    }

    @ViewBuilder private var content: some View {
        if let report {
            ListPaneLayout(listWidth: 380) {
                VStack(spacing: 0) {
                    ColumnTitle(
                        title: "Improve", line: subtitle.isEmpty ? "What keeps No and Maybe jobs from a Yes" : subtitle)
                    if Self.items(report).isEmpty {
                        EmptyState(
                            "Nothing to improve yet",
                            "When the AI rules jobs No or Maybe, what kept them from a Yes, and what could change it, appears here."
                        )
                    } else {
                        list(report)
                    }
                }
            } pane: {
                if Self.items(report).isEmpty {
                    EmptyState("Nothing to show", "Fixes appear here as the AI judges more jobs.")
                } else {
                    ScrollView {
                        detail(report)
                            .padding(.horizontal, Spacing.space7)
                            .padding(.vertical, Spacing.space6)
                            .frame(maxWidth: 760, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Color(.surface))
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - The list

    static func items(_ report: ImproveReport) -> [Item] {
        report.fixes.map { .fix($0.id) } + (report.snippets.isEmpty ? [] : [.snippets])
            + report.titleMisses.map { .title($0.phrase) } + (report.yearsLimit.isEmpty ? [] : [.yearsLimit])
            + report.held.map { .held($0.rule) } + (report.oneOffs.isEmpty ? [] : [.oneOffs])
    }

    private func list(_ report: ImproveReport) -> some View {
        List(selection: $choice) {
            if !report.fixes.isEmpty {
                Section("On your resume") {
                    ForEach(report.fixes) { fix in
                        row(fix.title, gain: Self.gain(fix), meta: meta(fix, report)).tag(Item.fix(fix.id))
                    }
                }
            }
            if !report.snippets.isEmpty || !report.titleMisses.isEmpty || !report.yearsLimit.isEmpty {
                Section("In your search") {
                    if !report.snippets.isEmpty {
                        row("Adzuna snippets", gain: "\(report.snippets.count) Maybe", meta: "Open each and decide")
                            .tag(Item.snippets)
                    }
                    ForEach(report.titleMisses) { miss in
                        row(miss.phrase, gain: Self.jobs(miss.jobs.count), meta: "A title your list leaves out")
                            .tag(Item.title(miss.phrase))
                    }
                    if !report.yearsLimit.isEmpty {
                        row("Your years limit", gain: "\(report.yearsLimit.count) No", meta: "Most years required")
                            .tag(Item.yearsLimit)
                    }
                }
            }
            if !report.held.isEmpty {
                Section("No resume changes these") {
                    ForEach(report.held) { held in
                        row(Self.heldTitle(held.rule), gain: "\(held.jobs.count) No", meta: Self.heldMeta(held.rule))
                            .tag(Item.held(held.rule))
                    }
                }
            }
            if !report.oneOffs.isEmpty {
                Section("One-offs") {
                    row(
                        "\(report.oneOffs.count) asks from one posting each", gain: "",
                        meta: "Niche, so not ranked"
                    )
                    .tag(Item.oneOffs)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func row(_ title: String, gain: String, meta: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(TypeStyle.headline).foregroundStyle(Color(.ink)).lineLimit(2)
                Spacer()
                Text(gain).font(TypeStyle.callout).monospacedDigit().foregroundStyle(Color(.ink2))
            }
            Text(meta).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).lineLimit(2)
        }
        .padding(.vertical, 3)
    }

    /// "up to 2 → Yes", or for No jobs reaching Maybe, "up to 1 → Maybe".
    static func gain(_ fix: ImproveReport.Fix) -> String {
        if fix.toYes > 0 { return "up to \(fix.toYes) → Yes" }
        if fix.toMaybe > 0 { return "up to \(fix.toMaybe) → Maybe" }
        return ""
    }

    /// "Partly shown in 2 jobs · a Proven skill".
    private func meta(_ fix: ImproveReport.Fix, _ report: ImproveReport) -> String {
        if fix.kind == .years {
            return "\(report.years.datedMonths) months in your roles · Total years \(Self.years(report.years.stated))"
        }
        let partial = fix.asks.allSatisfy { $0.match == .partial }
        let missing = fix.asks.allSatisfy { $0.match == .no }
        let how = partial ? "Partly shown" : missing ? "Missing" : "Missing or partly shown"
        let standing =
            switch fix.standing {
            case .proven: "a Proven skill"
            case .canDiscuss: "Can discuss"
            case .mentioned(let heading): "named in \(heading)"
            case .absent: fix.kind == .theme ? "no bullet says it" : "not on your resume"
            }
        return "\(how) in \(Self.jobs(fix.jobs.count)) · \(standing)"
    }

    // MARK: - The detail

    @ViewBuilder private func detail(_ report: ImproveReport) -> some View {
        switch choice {
        case .fix(let id)?:
            if let fix = report.fixes.first(where: { $0.id == id }) { fixDetail(fix, report) }
        case .snippets?:
            page(
                "In your search", "Adzuna snippets",
                "These jobs are Maybe only because Adzuna gives a snippet of each posting, so the AI can't judge the whole match. Open each one, read the posting, and change its verdict yourself if it fits.",
                jobs: report.snippets)
        case .title(let phrase)?:
            if let miss = report.titleMisses.first(where: { $0.phrase == phrase }) {
                page(
                    "In your search", miss.phrase,
                    "Your title list dropped \(Self.jobs(miss.jobs.count)) with this title: it has every word of one of your titles, just not together. With “\(miss.phrase)” added to your job titles in Settings, Search, \(miss.jobs.count == 1 ? "it" : "they") would pass all your filters and be analysed, one AI call each.",
                    jobs: miss.jobs)
            }
        case .yearsLimit?:
            page(
                "In your search", "Your years limit",
                "These ask for more years than your limit in Settings, Search, Most years required. Asks for years predict little about how people do in a job, so a slightly higher limit may be worth it.",
                jobs: report.yearsLimit, source: Self.yearsSource)
        case .held(let rule)?:
            if let held = report.held.first(where: { $0.rule == rule }) {
                page(
                    "No resume changes these", Self.heldTitle(rule),
                    Self.heldText(rule) + " Nothing on your resume moves these; they're counted so you know.",
                    jobs: held.jobs)
            }
        case .oneOffs?:
            oneOffsDetail(report)
        case nil:
            EmptyView()
        }
    }

    private func fixDetail(_ fix: ImproveReport.Fix, _ report: ImproveReport) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space5) {
            heading(kicker(fix), fix.title)
            impact(fix)
            box("What the jobs ask") {
                ForEach(Array(fix.asks.enumerated()), id: \.offset) { _, ask in askRow(ask) }
            }
            box("What your master resume shows") {
                Text(shows(fix, report)).font(TypeStyle.body).foregroundStyle(Color(.ink2))
                    .fixedSize(horizontal: false, vertical: true)
            }
            box("What to do") {
                Text(todo(fix, report)).font(TypeStyle.body).foregroundStyle(Color(.ink2))
                    .fixedSize(horizontal: false, vertical: true)
                let source = Self.source(for: fix)
                Text(source.why).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                if let url = source.url { Link(source.name, destination: url).font(TypeStyle.callout) }
            }
            if fix.kind != .years { suggestions(fix) }
        }
    }

    private func heading(_ kicker: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(kicker).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            Text(title).font(TypeStyle.title2).foregroundStyle(Color(.ink))
        }
    }

    private func kicker(_ fix: ImproveReport.Fix) -> String {
        switch (fix.kind, fix.standing) {
        case (.years, _): "Years of experience"
        case (.theme, _): "A kind of work postings ask for"
        case (_, .proven): "Prove a skill you list"
        case (_, .canDiscuss): "A Can-discuss skill holds you back"
        case (_, .mentioned): "On your resume, not in your Skills"
        case (_, .absent): "A skill these jobs want"
        }
    }

    /// The verdicts that could move, with the verdict colours, icons and words.
    @ViewBuilder private func impact(_ fix: ImproveReport.Fix) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            if fix.toYes > 0 {
                HStack(spacing: Spacing.space2) {
                    Text("Up to \(Self.jobs(fix.toYes)) could become").foregroundStyle(Color(.ink))
                    VerdictPill(verdict: .yes)
                }
            }
            if fix.toMaybe > 0 {
                HStack(spacing: Spacing.space2) {
                    Text("Up to \(fix.toMaybe) No could become").foregroundStyle(Color(.ink))
                    VerdictPill(verdict: .maybe)
                }
            }
            Text(
                fix.toYes + fix.toMaybe > 0
                    ? "If the screener counted these asks as shown. Kairos works this out from the analyses it has; no AI call."
                    : "Showing this alone wouldn't change a verdict: these jobs miss more than this."
            )
            .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func askRow(_ ask: ImproveReport.Ask) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
            Image(systemName: ask.match == .partial ? "circle.lefthalf.filled" : "circle.dashed")
                .foregroundStyle(Color(ask.match == .partial ? .maybe : .inkSecondary)).frame(width: 18)
                .accessibilityLabel(ask.match == .partial ? "Partly shown" : "Missing")
            VStack(alignment: .leading, spacing: 2) {
                Text(ask.text).font(TypeStyle.body).foregroundStyle(Color(.ink))
                    .fixedSize(horizontal: false, vertical: true)
                jobLink(ask.job, prefix: (ask.kind == .must ? "Must-have" : "Nice-to-have") + " · ")
            }
        }
    }

    private func jobLink(_ id: JobID, prefix: String = "") -> some View {
        Button {
            path.append(id)
        } label: {
            Text(prefix + (model.job(id).map { "\($0.title) · \($0.company)" } ?? "A removed job"))
                .font(TypeStyle.callout).multilineTextAlignment(.leading)
        }
        .buttonStyle(.link)
        .help("Open this job")
    }

    private func shows(_ fix: ImproveReport.Fix, _ report: ImproveReport) -> String {
        if fix.kind == .years {
            return
                "Total years: \(Self.years(report.years.stated)). Your dated roles cover \(report.years.datedMonths) months, about \(Self.years(Double(report.years.datedMonths) / 12)) years, each month counted once."
        }
        switch fix.standing {
        case .proven(let name):
            return
                "\(name) is in your Skills as Proven, but no bullet shows it the way these postings ask: for years, scale or a result."
        case .canDiscuss(let name):
            return "\(name) is in your Skills as Can discuss, which counts as half a match."
        case .mentioned(let heading):
            return fix.kind == .theme
                ? "\(heading) touches on it, but no bullet says it in the postings' terms."
                : "It's named in \(heading), but not in your Skills."
        case .absent:
            return fix.kind == .theme
                ? "No bullet describes this kind of work." : "Nothing on your master resume names it."
        }
    }

    private func todo(_ fix: ImproveReport.Fix, _ report: ImproveReport) -> String {
        let only =
            " Only if it's true: Kairos never adds it for you, and builds check every line against your master resume."
        switch (fix.kind, fix.standing) {
        case (.years, _):
            let dated = Double(report.years.datedMonths) / 12
            if dated > (report.years.stated ?? 0) + 0.25 {
                return
                    "If you'd count all these roles as relevant experience in an interview, set Total years in Master resume to \(Self.years((dated * 2).rounded(.down) / 2)). Asks just above your years are still worth applying to: within your grace, they're Maybe, not No."
            }
            return
                "Your roles don't reach these asks yet. Asks just above your years are still worth applying to: within your grace, they're Maybe, not No."
        case (.theme, _):
            return
                "Postings ask for this kind of work without naming a tool. If you've done it, say so in the bullet where you did: the scale, the users, the uptime or the tests."
                + only
        case (_, .proven(let name)):
            return
                "In the role or project where you used \(name), add a bullet that names it with what you built and a result."
                + only
        case (_, .canDiscuss(let name)):
            return
                "If you've used \(name) for real, at work or in a project, add a bullet that shows it and make it Proven. If not, it stays Can discuss, and Stretch mode lists it to prepare."
        case (_, .mentioned(let heading)):
            return "Add \(fix.title) to your Skills as Proven: \(heading) already shows it." + only
        case (_, .absent):
            return
                "If you've used \(fix.title), add it to your Skills with a bullet that shows it. If you haven't, it's one to learn: \(Self.jobs(fix.jobs.count)) here ask for it, and a small project that uses it is enough to show it."
        }
    }

    // MARK: - Ask the AI

    @ViewBuilder private func suggestions(_ fix: ImproveReport.Fix) -> some View {
        box("How could I show this?") {
            switch answers[fix.id] {
            case nil:
                Text(
                    "The AI reads your roles, projects and bullets and asks about the ones that might already show this. It doesn't write anything. One AI call."
                )
                .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).fixedSize(
                    horizontal: false, vertical: true)
                askButton(fix, title: "Ask the AI")
            case .success(let output)?:
                if output.suggestions.isEmpty {
                    Text(output.otherwise).font(TypeStyle.body).foregroundStyle(Color(.ink2))
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(output.suggestions.enumerated()), id: \.offset) { _, suggestion in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion.question).font(TypeStyle.headline).foregroundStyle(Color(.ink))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(suggestion.angle).font(TypeStyle.body).foregroundStyle(Color(.ink2))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(
                            "About: "
                                + suggestion.evidence.compactMap { model.screeningProfile?.describe($0) }.map {
                                    $0.count > 80 ? $0.prefix(80) + "…" : $0
                                }.joined(separator: "; ")
                        )
                        .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, Spacing.space1)
                }
            case .failure(let problem)?:
                Label(problem.message, systemImage: "exclamationmark.triangle.fill").font(TypeStyle.callout)
                    .foregroundStyle(Color(.error)).fixedSize(horizontal: false, vertical: true)
                askButton(fix, title: "Try again")
            }
        }
    }

    private func askButton(_ fix: ImproveReport.Fix, title: String) -> some View {
        HStack(spacing: Spacing.space2) {
            Button {
                Task {
                    asking = fix.id
                    answers[fix.id] = await model.suggestions(for: fix)
                    asking = nil
                }
            } label: {
                Label(title, systemImage: "sparkles").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(asking != nil)
            if asking == fix.id { ProgressView().controlSize(.small) }
        }
    }

    // MARK: - Other pages

    private func page(
        _ kicker: String, _ title: String, _ text: String, jobs: [JobID], source: Source? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space5) {
            heading(kicker, title)
            Text(text).font(TypeStyle.body).foregroundStyle(Color(.ink2)).fixedSize(horizontal: false, vertical: true)
            if let source, let url = source.url { Link(source.name, destination: url).font(TypeStyle.callout) }
            box(Self.jobs(jobs.count).capitalized) {
                ForEach(jobs, id: \.self) { jobLink($0) }
            }
        }
    }

    private func oneOffsDetail(_ report: ImproveReport) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space5) {
            heading("One-offs", "Asks from one posting each")
            Text(
                "Each of these is asked by one posting, for something nowhere on your resume, or it's an ask nothing else groups with. Learning one widens your reach by about one job, so they aren't ranked."
            )
            .font(TypeStyle.body).foregroundStyle(Color(.ink2)).fixedSize(horizontal: false, vertical: true)
            box("The asks") {
                ForEach(report.oneOffs) { fix in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(fix.title).font(TypeStyle.headline).foregroundStyle(Color(.ink))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Text(Self.gain(fix)).font(TypeStyle.callout).foregroundStyle(Color(.ink2))
                        }
                        ForEach(fix.jobs, id: \.self) { jobLink($0) }
                    }
                    .padding(.vertical, Spacing.space1)
                }
            }
        }
    }

    private func box(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Text(title.uppercased()).font(TypeStyle.caption).tracking(0.4).foregroundStyle(Color(.inkSecondary))
            content()
        }
        .padding(Spacing.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Color(.surfaceRaised)))
    }

    // MARK: - Words

    static func jobs(_ count: Int) -> String { "\(count) job\(count == 1 ? "" : "s")" }

    static func years(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "not set"
    }

    static func heldTitle(_ rule: VerdictRule) -> String {
        switch rule {
        case .seniority: "A level you've turned off"
        case .workAuthorization: "No visa sponsorship"
        case .remoteScope: "Remote only where you'd need a visa"
        case .clearance: "A security clearance"
        case .french: "French"
        case .enrolment: "For current students"
        default: rule.rawValue
        }
    }

    static func heldMeta(_ rule: VerdictRule) -> String {
        rule == .seniority ? "Your level setting" : rule == .enrolment ? "Your student status" : "Your situation"
    }

    static func heldText(_ rule: VerdictRule) -> String {
        switch rule {
        case .seniority: "These are at a level you've turned off in Settings, Search."
        case .workAuthorization: "They won't sponsor a visa you'd need for that country."
        case .remoteScope: "They're remote only within a country where you'd need sponsorship."
        case .clearance: "They need a security clearance you don't hold."
        case .french: "They ask for French, which isn't among your languages."
        case .enrolment: "They're for current students, and you've said you've graduated."
        default: ""
        }
    }

    // MARK: - Why

    struct Source {
        let why: String
        let name: String
        let link: String

        var url: URL? { URL(string: link) }
    }

    private static let yearsSource = Source(
        why: "", name: "Van Iddekinge et al., Personnel Psychology, 2019",
        link: "https://digitalcommons.unf.edu/unf_faculty_publications/785/")

    /// The research behind each kind of fix (the Resume Reach proposal).
    static func source(for fix: ImproveReport.Fix) -> Source {
        switch (fix.kind, fix.standing) {
        case (.years, _):
            Source(
                why:
                    "Why: across 81 studies, experience before hiring correlated .06 with job performance. Years asks are a guide, not a bar.",
                name: yearsSource.name, link: yearsSource.link)
        case (.theme, _):
            Source(
                why:
                    "Why: 88% of employers say qualified candidates are screened out for not matching the exact words of a job description.",
                name: "Hidden Workers, Harvard Business School and Accenture, 2021",
                link: "https://hbswk.hbs.edu/item/how-to-tap-the-talent-automated-hr-platforms-miss")
        case (_, .canDiscuss), (_, .absent):
            Source(
                why:
                    "Why: hiring on skills rather than titles grows talent pools by up to 19 times; a project that proves a skill counts.",
                name: "LinkedIn Skills-First report, 2023",
                link: "https://www.techrepublic.com/article/skills-first-hiring-linkedin/")
        case (_, .proven), (_, .mentioned):
            Source(
                why:
                    "Why: recruiters search their applicant system by skill and title, and a resume without the searched words doesn't come up.",
                name: "Enhancv recruiter study, 2025",
                link: "https://enhancv.com/blog/does-ats-reject-resumes/")
        }
    }
}
