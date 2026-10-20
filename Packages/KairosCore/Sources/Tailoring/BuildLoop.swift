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
    /// Stretch mode's cap per role (your setting, 0 to 2).
    public var gapBulletsPerRole: Int
    /// Write a cover letter too (optional per build).
    public var coverLetter: Bool

    public init(
        jobTitle: String, company: String, companyProducts: [String] = [], requirements: JobRequirements,
        locale: SpellingLocale, mode: BuildMode = .strict, pageBudget: Int = 1,
        gapBulletsPerRole: Int = StretchSettings().limit, coverLetter: Bool = false
    ) {
        self.jobTitle = jobTitle
        self.company = company
        self.companyProducts = companyProducts
        self.requirements = requirements
        self.locale = locale
        self.mode = mode
        self.pageBudget = pageBudget
        self.gapBulletsPerRole = gapBulletsPerRole
        self.coverLetter = coverLetter
    }
}

/// Where a build is, for progress.
public enum BuildStep: Sendable, Equatable {
    case selecting, writing, scoring
    case rewriting(MatchScore.Section, pass: Int)
    /// Stretch mode only.
    case gapBullets
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
    /// Bullets dropped to fit the page budget.
    public var dropped: Int
    /// When one was asked for; nil if it still failed its checks after the repair.
    public var coverLetter: CoverLetter?
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

    public typealias Measure = @Sendable (TailoredResume) async throws -> Int

    /// `measure` renders the resume and counts its pages; without it nothing is fitted.
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
        let brief = WriterBrief(jobTitle: request.jobTitle, requirements: request.requirements, locale: request.locale)
        let experienceInput = WriteSectionInput(
            brief: brief, entries: selection.experience, skills: selection.skills, verifier: verifier)
        let projectsInput = WriteSectionInput(
            brief: brief, entries: selection.projects, skills: selection.skills, verifier: verifier)
        let polish = Polish(locale: request.locale)

        progress(.writing)
        async let experienceBullets = section(WriteExperienceTask(), experienceInput, lite: request.mode == .lite)
        async let projectBullets = section(WriteProjectsTask(), projectsInput, lite: request.mode == .lite)
        async let summaryText = summary(
            WriteSummaryInput(
                brief: brief, selection: selection, totalYears: master.header.totalYears, verifier: verifier))
        async let skillGroups = skills(WriteSkillsInput(brief: brief, skills: selection.skills))
        let written = try await (
            experience: experienceBullets, projects: projectBullets, summary: summaryText, skills: skillGroups
        )

        var fellBack: [MatchScore.Section] = []
        if written.experience.fellBack { fellBack.append(.experience) }
        if written.projects.fellBack { fellBack.append(.projects) }
        if written.summary == nil { fellBack.append(.summary) }
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
            education: education(), certifications: certifications(), languages: languages())

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
                    if (candidateScore.score(section) ?? 0) > (score.score(section) ?? 0) {
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

        var pages: Int?
        var dropped = 0
        if let measure {
            pages = try await measure(resume)
            while let count = pages, count > request.pageBudget, Self.dropLowest(&resume) {
                progress(.fitting(pages: count))
                dropped += 1
                pages = try await measure(resume)
            }
        }
        score = MatchScore.score(resume, for: request.requirements, pages: pages, pageBudget: request.pageBudget)

        var letter: CoverLetter?
        if request.coverLetter {
            progress(.coverLetter)
            let input = CoverLetterInput(
                brief: brief, company: request.company, entries: selection.experience + selection.projects,
                skills: selection.skills, totalYears: master.header.totalYears,
                verifier: Verifier(resume: master, companyProducts: request.companyProducts))
            letter = try await coverLetter(input, header: resume.header)
        }
        return BuildOutcome(
            resume: resume, score: score, rewrites: rewrites, fellBack: fellBack, pages: pages, dropped: dropped,
            coverLetter: letter)
    }

    // MARK: - Writers

    /// Every call goes out with your contact details removed from its data.
    private func run<T: LLMTask>(_ task: T, _ input: T.Input) async throws(LLMError) -> LLMResult<T.Output> {
        try await router.run(Redacted(task, header: master.header), input: input, context: context)
    }

    /// The writer's bullets, or your own word for word: in lite mode, or when the writer's reply
    /// still fails its checks after the repair call.
    private func section<T: LLMTask>(_ task: T, _ input: WriteSectionInput, lite: Bool) async throws -> (
        entries: [WrittenEntry], fellBack: Bool
    ) where T.Input == WriteSectionInput, T.Output == SectionOutput {
        guard !input.entries.isEmpty else { return ([], false) }
        guard !lite else { return (Self.originals(input), false) }
        do {
            let result = try await run(task, input)
            return (SectionWriter.written(result.output, input: input), false)
        } catch .invalidOutput {
            return (Self.originals(input), true)
        }
    }

    private func summary(_ input: WriteSummaryInput) async throws -> String? {
        do {
            return try await run(WriteSummaryTask(), input).output.summary
        } catch .invalidOutput {
            return nil
        }
    }

    private func skills(_ input: WriteSkillsInput) async throws -> [SkillGroup]? {
        do {
            let result = try await run(WriteSkillsTask(), input)
            return WriteSkillsTask.groups(result.output, input: input)
        } catch .invalidOutput {
            return nil
        }
    }

    /// Nil when the rewrite fails its checks: the section keeps its current bullets.
    private func rewrite(_ input: RewriteSectionInput) async throws -> SectionOutput? {
        do {
            return try await run(RewriteSectionTask(), input).output
        } catch .invalidOutput {
            return nil
        }
    }

    /// Nil when the reply still fails its checks after the repair: the build has no letter.
    private func coverLetter(_ input: CoverLetterInput, header: TailoredResume.Header) async throws -> CoverLetter? {
        do {
            let result = try await run(CoverLetterTask(), input)
            return CoverLetterTask.letter(result.output, input: input, header: header, date: settings.selector.now)
        } catch .invalidOutput {
            return nil
        }
    }

    /// Nil when the reply still fails its checks after the repair: the build has no gap bullets.
    private func gapBullets(_ input: GapBulletsInput) async throws -> [UUID: [TailoredBullet]]? {
        do {
            let result = try await run(GapBulletsTask(), input)
            return GapBulletsTask.written(result.output, input: input)
        } catch .invalidOutput {
            return nil
        }
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
                    bullets: tailored)
            case .project(let project):
                return TailoredResume.Entry(
                    entryID: chosen.entry.id, title: project.name,
                    organization: project.tech.isEmpty ? nil : project.tech.joined(separator: ", "),
                    dates: DisplayDates.range(chosen.entry), bullets: tailored)
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

    private func education() -> [TailoredResume.Entry] {
        master.entries(.education).compactMap { entry in
            guard case .education(let school) = entry.fields else { return nil }
            let title = [school.credential, school.field].filter { !$0.isEmpty }.joined(separator: ", ")
            return TailoredResume.Entry(
                entryID: entry.id, title: title.isEmpty ? school.institution : title,
                organization: title.isEmpty ? nil : school.institution,
                location: school.location.isEmpty ? nil : school.location,
                dates: DisplayDates.range(entry, monthNames: false))
        }
    }

    private func certifications() -> [TailoredResume.Entry] {
        master.entries(.certification).compactMap { entry in
            guard case .certification(let certificate) = entry.fields else { return nil }
            return TailoredResume.Entry(
                entryID: entry.id, title: certificate.name, dates: entry.start.map { "\($0.year)" })
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
