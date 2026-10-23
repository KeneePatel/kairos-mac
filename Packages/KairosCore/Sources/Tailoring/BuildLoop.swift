import Foundation
import LLM
import MasterResume

/// Strict by default; stretch only when you turn it on (T37); lite copies bullets word for word (T38).
public enum BuildMode: String, Codable, Sendable, CaseIterable {
    case strict, lite, stretch
}

/// What one build is for.
public struct BuildRequest: Sendable, Equatable {
    public var jobTitle: String
    /// The hiring company, so no bullet names it or its products.
    public var company: String
    public var companyProducts: [String]
    public var requirements: JobRequirements
    public var locale: SpellingLocale
    public var mode: BuildMode
    public var pageBudget: Int
    /// You allow a second page when the posting's evidence needs it (`PageSettings`).
    public var twoPagesWhenNeeded: Bool
    /// Characters a line of the template's bullets holds.
    public var lineCharacters: Int
    /// Stretch mode's cap per role (your setting, 0 to 2).
    public var gapBulletsPerRole: Int
    /// Write a cover letter too (optional per build).
    public var coverLetter: Bool
    /// Write a summary. Off for a template that doesn't print one (Harvard's), so no call is spent on
    /// it and the score doesn't count words the PDF won't show.
    public var summary: Bool

    public init(
        jobTitle: String, company: String, companyProducts: [String] = [], requirements: JobRequirements,
        locale: SpellingLocale, mode: BuildMode = .strict, pageBudget: Int = 1, twoPagesWhenNeeded: Bool = false,
        lineCharacters: Int = 100, gapBulletsPerRole: Int = StretchSettings().limit, coverLetter: Bool = false,
        summary: Bool = true
    ) {
        self.jobTitle = jobTitle
        self.company = company
        self.companyProducts = companyProducts
        self.requirements = requirements
        self.locale = locale
        self.mode = mode
        self.pageBudget = pageBudget
        self.twoPagesWhenNeeded = twoPagesWhenNeeded
        self.lineCharacters = lineCharacters
        self.gapBulletsPerRole = gapBulletsPerRole
        self.coverLetter = coverLetter
        self.summary = summary
    }
}

/// Why a build has no letter though one was asked for.
public enum CoverLetterProblem: Sendable, Equatable {
    /// Its reply still failed the checks after the repair; what they found.
    case checks(String)
    /// No model in the chain answered; the last one's reason ("was overloaded (503)").
    case unavailable(String)
}

/// Where a build is, for progress.
public enum BuildStep: Sendable, Equatable {
    case selecting, writing, scoring
    case rewriting(MatchScore.Section, pass: Int)
    /// Stretch mode only.
    case gapBullets
    /// Bullets that run a few words onto another line, cut to a line fewer.
    case shortening
    case fitting(pages: Int)
    case coverLetter
}

public struct BuildOutcome: Sendable, Equatable {
    public var resume: TailoredResume
    public var score: MatchScore
    /// `rewriteSection` calls made.
    public var rewrites: Int
    /// Sections whose writer failed even after its repair, so they use your master resume's words.
    public var fellBack: [MatchScore.Section]
    public var pages: Int?
    /// How the final resume fills its pages, when it was measured.
    public var layout: PageLayout?
    /// Bullets dropped to fit the page budget.
    public var dropped: Int
    /// When one was asked for; nil if it still failed its checks after the repair.
    public var coverLetter: CoverLetter?
    /// Why a letter that was asked for was left out.
    public var coverLetterProblem: CoverLetterProblem?
}

/// One build (SPEC §5.3): select, write the four sections in parallel, polish, score, rewrite any
/// section under 70 (at most 3 passes, keeping the best version), add Stretch mode's gap bullets
/// for what's still uncovered, then fit the page budget by dropping the lowest-ranked bullets, and
/// write the cover letter if asked. Every bullet the writers return has passed the verifier; a
/// section whose writer still fails after its repair falls back to your bullets, word for word,
/// and failed gap bullets or a failed letter are left out.
public struct BuildLoop: Sendable {
    public struct Settings: Sendable {
        /// The one pass mark (SPEC §5.3).
        public var passMark = 80.0
        public var rewriteBelow = 70.0
        public var maxPasses = 3
        public var selector = Selector()

        public init() {}
    }

    public let router: LLMRouter
    public let master: MasterResume
    public let settings: Settings
    public let context: CallContext

    public init(
        router: LLMRouter, master: MasterResume, settings: Settings = Settings(), context: CallContext = CallContext()
    ) {
        self.router = router
        self.master = master
        self.settings = settings
        self.context = context
    }

    public typealias Measure = @Sendable (TailoredResume) async throws -> PageLayout

    /// `measure` renders the resume and measures how it fills its pages; without it nothing is fitted.
    public func run(
        _ request: BuildRequest, measure: Measure? = nil, progress: @Sendable (BuildStep) -> Void = { _ in }
    )
        async throws -> BuildOutcome
    {
        progress(.selecting)
        let selection = settings.selector.select(from: master, for: request.requirements)
        let verifier = Verifier(
            resume: master, mode: request.mode == .stretch ? .stretch : .strict, hiringCompany: request.company,
            companyProducts: request.companyProducts)
        let brief = WriterBrief(
            jobTitle: request.jobTitle, requirements: request.requirements, locale: request.locale,
            lineCharacters: request.lineCharacters)
        let experienceInput = WriteSectionInput(
            brief: brief, entries: selection.experience, skills: selection.skills, verifier: verifier)
        let projectsInput = WriteSectionInput(
            brief: brief, entries: selection.projects, skills: selection.skills, verifier: verifier)
        let polish = Polish(locale: request.locale)

        progress(.writing)
        async let experienceBullets = section(WriteExperienceTask(), experienceInput, lite: request.mode == .lite)
        async let projectBullets = section(WriteProjectsTask(), projectsInput, lite: request.mode == .lite)
        let summaryInput = WriteSummaryInput(
            brief: brief, selection: selection, totalYears: master.header.totalYears, verifier: verifier)
        async let summaryText = request.summary ? summary(summaryInput) : nil
        async let skillGroups = skills(WriteSkillsInput(brief: brief, skills: selection.skills))
        let written = try await (
            experience: experienceBullets, projects: projectBullets, summary: summaryText, skills: skillGroups
        )

        var fellBack: [MatchScore.Section] = []
        if written.experience.fellBack { fellBack.append(.experience) }
        if written.projects.fellBack { fellBack.append(.projects) }
        if request.summary, written.summary == nil { fellBack.append(.summary) }
        if written.skills == nil { fellBack.append(.skills) }

        let ranks = Dictionary(
            (selection.experience + selection.projects).flatMap(\.bullets).map { ($0.bullet.id, $0.score) },
            uniquingKeysWith: max)
        var resume = TailoredResume(
            header: TailoredResume.Header(master.header),
            summary: written.summary.map(polish.text),
            skills: written.skills ?? [SkillGroup(label: "Skills", skills: selection.skills.map(\.name))],
            experience: entries(written.experience.entries, from: selection.experience, polish: polish, ranks: ranks),
            projects: entries(written.projects.entries, from: selection.projects, polish: polish, ranks: ranks),
            education: education(), certifications: certifications(for: request.requirements),
            languages: request.requirements.asksForLanguages ? languages() : nil)

        progress(.scoring)
        var score = MatchScore.score(resume, for: request.requirements)
        var rewrites = 0
        if request.mode != .lite {
            for pass in 1...max(1, settings.maxPasses) {
                let weak = [MatchScore.Section.experience, .projects].filter {
                    (score.score($0) ?? 100) < settings.rewriteBelow
                }
                guard !weak.isEmpty else { break }
                var improved = false
                for section in weak {
                    progress(.rewriting(section, pass: pass))
                    let writer = section == .experience ? experienceInput : projectsInput
                    let current = (section == .experience ? resume.experience : resume.projects).map {
                        WrittenEntry(entryID: $0.entryID, bullets: $0.bullets)
                    }
                    let input = RewriteSectionInput(
                        section: section, writer: writer, current: current, findings: score.findings(section))
                    rewrites += 1
                    guard let result = try await rewrite(input) else { continue }
                    var candidate = resume
                    let rewritten = entries(
                        RewriteSectionTask.written(result, input: input), from: writer.entries, polish: polish,
                        ranks: ranks)
                    if section == .experience {
                        candidate.experience = rewritten
                    } else {
                        candidate.projects = rewritten
                    }
                    let candidateScore = MatchScore.score(candidate, for: request.requirements)
                    let before = section == .experience ? resume.experience : resume.projects
                    if (candidateScore.score(section) ?? 0) > (score.score(section) ?? 0),
                        Self.keepsTheFacts(rewritten, of: before, master: master)
                    {
                        resume = candidate
                        score = candidateScore
                        improved = true
                    }
                }
                if !improved { break }
            }
        }

        if request.mode == .stretch {
            let input = GapBulletsInput(
                brief: brief, written: resume, master: master, perRole: request.gapBulletsPerRole, verifier: verifier)
            if !input.isEmpty {
                progress(.gapBullets)
                if let added = try await gapBullets(input) {
                    resume.experience = resume.experience.map { entry in
                        Self.adding(added[entry.entryID] ?? [], to: entry, polish: polish)
                    }
                    score = MatchScore.score(resume, for: request.requirements)
                }
            }
        }

        // Bullets a few words past a line cost the page a line each: one call cuts them to a line
        // fewer, keeping every number and claim, before the fitter decides what stays.
        if let measure, request.mode != .lite {
            let input = ShortenBulletsInput(
                resume, layout: try await measure(resume), lineCharacters: request.lineCharacters,
                locale: request.locale, verifier: verifier)
            if !input.items.isEmpty {
                progress(.shortening)
                if let output = try await shorten(input) {
                    resume = ShortenBulletsTask.applying(output, input: input, to: resume, polish: polish)
                }
            }
        }

        var layout: PageLayout?
        var dropped = 0
        var budget = request.pageBudget
        if let measure {
            let fitter = PageFitter(
                budget: request.pageBudget, allowingTwo: request.twoPagesWhenNeeded, measure: measure)
            let fitted = try await fitter.fit(resume, progress: progress)
            resume = fitted.resume
            layout = fitted.layout
            dropped = fitted.dropped
            budget = fitted.budget
        }
        let pages = layout?.pages
        score = MatchScore.score(resume, for: request.requirements, pages: pages, pageBudget: budget)

        var letter: CoverLetter?
        var problem: CoverLetterProblem?
        if request.coverLetter {
            progress(.coverLetter)
            let input = CoverLetterInput(
                brief: brief, company: request.company, entries: selection.experience + selection.projects,
                skills: selection.skills, totalYears: master.header.totalYears,
                verifier: Verifier(resume: master, companyProducts: request.companyProducts))
            (letter, problem) = try await coverLetter(input, header: resume.header)
        }
        return BuildOutcome(
            resume: resume, score: score, rewrites: rewrites, fellBack: fellBack, pages: pages, layout: layout,
            dropped: dropped, coverLetter: letter, coverLetterProblem: problem)
    }

    /// A rewrite counts only if it keeps every bullet and every number the section had: one that
    /// showed more of the posting's keywords by merging bullets or rounding off specifics made the
    /// resume thinner (resume v2 plan, phase 1).
    static func keepsTheFacts(
        _ rewritten: [TailoredResume.Entry], of current: [TailoredResume.Entry], master: MasterResume
    ) -> Bool {
        let after = rewritten.flatMap(\.bullets)
        let before = current.flatMap(\.bullets)
        return after.count >= before.count
            && BuildReport.numbersKept(after, master: master) >= BuildReport.numbersKept(before, master: master)
    }

    // MARK: - Writers

    /// Every call goes out with your contact details removed from its data.
    private func run<T: LLMTask>(_ task: T, _ input: T.Input) async throws(LLMError) -> LLMResult<T.Output> {
        try await router.run(Redacted(task, header: master.header), input: input, context: context)
    }

    /// The writer's bullets, or your own word for word: in lite mode, or when the writer's reply
    /// still fails its checks after the repair call.
    /// The writer's bullets, or your own word for word: in lite mode, or when no model in the
    /// task's chain gives a reply that passes its checks (overloaded, unreachable, or wrong after
    /// the repair). Only your stopping it or the budget running out ends the build.
    private func section<T: LLMTask>(_ task: T, _ input: WriteSectionInput, lite: Bool) async throws -> (
        entries: [WrittenEntry], fellBack: Bool
    ) where T.Input == WriteSectionInput, T.Output == SectionOutput {
        guard !input.entries.isEmpty else { return ([], false) }
        guard !lite else { return (Self.originals(input), false) }
        do {
            let result = try await run(task, input)
            return (SectionWriter.written(result.output, input: input), false)
        } catch {
            if error.stopsEverything { throw error }
            return (Self.originals(input), true)
        }
    }

    /// Nil when no model gave a usable reply: the build goes on without what it would have added.
    private func optional<T: LLMTask>(_ task: T, _ input: T.Input) async throws -> T.Output? {
        do {
            return try await run(task, input).output
        } catch {
            if error.stopsEverything { throw error }
            return nil
        }
    }

    private func summary(_ input: WriteSummaryInput) async throws -> String? {
        try await optional(WriteSummaryTask(), input)?.summary
    }

    private func skills(_ input: WriteSkillsInput) async throws -> [SkillGroup]? {
        try await optional(WriteSkillsTask(), input).map { WriteSkillsTask.groups($0, input: input) }
    }

    /// Nil when the rewrite can't be had: the section keeps its current bullets.
    private func rewrite(_ input: RewriteSectionInput) async throws -> SectionOutput? {
        try await optional(RewriteSectionTask(), input)
    }

    /// No letter when the reply still fails its checks after the repair, or no model answers, and why.
    private func coverLetter(_ input: CoverLetterInput, header: TailoredResume.Header) async throws -> (
        CoverLetter?, CoverLetterProblem?
    ) {
        do {
            let result = try await run(CoverLetterTask(), input)
            return (
                CoverLetterTask.letter(result.output, input: input, header: header, date: settings.selector.now), nil
            )
        } catch .invalidOutput(let problems) {
            return (nil, .checks(problems))
        } catch {
            if error.stopsEverything { throw error }
            return (nil, .unavailable(error.reason))
        }
    }

    /// Nil when it can't be had: the bullets stay as written.
    private func shorten(_ input: ShortenBulletsInput) async throws -> ShortenBulletsOutput? {
        try await optional(ShortenBulletsTask(), input)
    }

    /// Nil when it can't be had: the build has no gap bullets.
    private func gapBullets(_ input: GapBulletsInput) async throws -> [UUID: [TailoredBullet]]? {
        try await optional(GapBulletsTask(), input).map { GapBulletsTask.written($0, input: input) }
    }

    static func originals(_ input: WriteSectionInput) -> [WrittenEntry] {
        input.entries.map { selected in
            WrittenEntry(
                entryID: selected.entry.id,
                bullets: selected.bullets.map { TailoredBullet(text: $0.bullet.text, sourceIDs: [$0.bullet.id]) },
                verbatim: true)
        }
    }

    // MARK: - Assembly

    private func entries(
        _ written: [WrittenEntry], from selected: [SelectedEntry], polish: Polish, ranks: [UUID: Double]
    ) -> [TailoredResume.Entry] {
        selected.compactMap { chosen in
            guard let entry = written.first(where: { $0.entryID == chosen.entry.id }) else { return nil }
            let bullets = entry.bullets
            let texts = entry.verbatim ? bullets.map(\.text) : polish.bullets(bullets.map(\.text))
            let tailored = zip(bullets, texts).map { bullet, text in
                TailoredBullet(
                    text: text, sourceIDs: bullet.sourceIDs, gap: bullet.gap,
                    rank: bullet.sourceIDs.compactMap { ranks[$0] }.max() ?? 0)
            }
            switch chosen.entry.fields {
            case .experience(let role):
                return TailoredResume.Entry(
                    entryID: chosen.entry.id, title: role.title, organization: role.employer,
                    location: role.location.isEmpty ? nil : role.location, dates: DisplayDates.range(chosen.entry),
                    period: TailoredResume.Period(chosen.entry), bullets: tailored)
            case .project(let project):
                return TailoredResume.Entry(
                    entryID: chosen.entry.id, title: project.name,
                    organization: project.tech.isEmpty ? nil : project.tech.joined(separator: ", "),
                    dates: DisplayDates.range(chosen.entry), period: TailoredResume.Period(chosen.entry),
                    bullets: tailored)
            default:
                return nil
            }
        }
    }

    /// Gap bullets go after a role's own, polished so none opens on a verb the role already used.
    /// The role's own bullets stay exactly as they were.
    static func adding(_ gaps: [TailoredBullet], to entry: TailoredResume.Entry, polish: Polish)
        -> TailoredResume.Entry
    {
        guard !gaps.isEmpty else { return entry }
        var entry = entry
        let polished = polish.bullets(entry.bullets.map(\.text) + gaps.map(\.text)).suffix(gaps.count)
        entry.bullets += zip(gaps, polished).map { gap, text in
            var gap = gap
            gap.text = text
            return gap
        }
        return entry
    }

    /// Your degrees, each with its honours or grade ("GPA 3.78/4.3") after it.
    private func education() -> [TailoredResume.Entry] {
        master.entries(.education).compactMap { entry in
            guard case .education(let school) = entry.fields else { return nil }
            let title = [school.credential, school.field, school.honours].filter { !$0.isEmpty }.joined(
                separator: ", ")
            return TailoredResume.Entry(
                entryID: entry.id, title: title.isEmpty ? school.institution : title,
                organization: title.isEmpty ? nil : school.institution,
                location: school.location.isEmpty ? nil : school.location,
                dates: DisplayDates.range(entry, monthNames: false), period: TailoredResume.Period(entry))
        }
    }

    /// Only when the posting asks about certifications, and only yours that match what it names (or,
    /// when it names none, what it asks for overall): four unasked-for courses cost the page a role.
    private func certifications(for job: JobRequirements) -> [TailoredResume.Entry] {
        guard !job.certificationAsks.isEmpty else { return [] }
        let named = Set(job.certificationAsks.flatMap { Keywords.terms(in: $0) })
        let wanted = named.isEmpty ? Set((job.musts + job.nices).flatMap { Keywords.terms(in: $0) }) : named
        return master.entries(.certification).compactMap { entry in
            guard case .certification(let certificate) = entry.fields,
                !Keywords.terms(in: certificate.name).isDisjoint(with: wanted)
            else { return nil }
            return TailoredResume.Entry(
                entryID: entry.id, title: certificate.name, dates: entry.start.map { "\($0.year)" },
                period: TailoredResume.Period(entry))
        }
    }

    private func languages() -> String? {
        let spoken = master.entries(.language).compactMap { entry -> String? in
            guard case .language(let language) = entry.fields else { return nil }
            return "\(language.language) (\(language.proficiency.rawValue))"
        }
        return spoken.isEmpty ? nil : spoken.joined(separator: ", ")
    }

    // MARK: - Fitting

    /// Drops the lowest-ranked bullet of an entry that keeps at least one, older entries and later
    /// bullets first on a tie; then whole projects, last first. False when nothing more can go.
    static func dropLowest(_ resume: inout TailoredResume) -> Bool {
        var lowest: (section: Int, entry: Int, bullet: Int, rank: Double)?
        for (section, entries) in [resume.experience, resume.projects].enumerated() {
            for (entryIndex, entry) in entries.enumerated() where entry.bullets.count > 1 {
                for (bulletIndex, bullet) in entry.bullets.enumerated()
                where lowest.map({ bullet.rank <= $0.rank }) ?? true {
                    lowest = (section, entryIndex, bulletIndex, bullet.rank)
                }
            }
        }
        if let lowest {
            if lowest.section == 0 {
                resume.experience[lowest.entry].bullets.remove(at: lowest.bullet)
            } else {
                resume.projects[lowest.entry].bullets.remove(at: lowest.bullet)
            }
            return true
        }
        guard !resume.projects.isEmpty else { return false }
        resume.projects.removeLast()
        return true
    }
}
