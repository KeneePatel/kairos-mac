import AI
import Foundation
import Resume

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
    /// You allow a second page when the posting's evidence needs it.
    public var twoPagesWhenNeeded: Bool
    /// Characters a line of the template's bullets holds.
    public var lineCharacters: Int
    /// Stretch mode's cap per role, 0 to 2.
    public var gapBulletsPerRole: Int
    public var coverLetter: Bool
    /// Off for a template that doesn't print a summary (Harvard), so no call is spent on one.
    public var summary: Bool

    public init(
        jobTitle: String, company: String, companyProducts: [String] = [], requirements: JobRequirements,
        locale: SpellingLocale, mode: BuildMode = .strict, pageBudget: Int = 1, twoPagesWhenNeeded: Bool = false,
        lineCharacters: Int = 100, gapBulletsPerRole: Int = 1, coverLetter: Bool = false, summary: Bool = false
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

/// Where a build is, for progress.
public enum BuildStep: Sendable, Equatable {
    case selecting, writing, gapBullets, shortening
    case fitting(pages: Int)
    case coverLetter
}

/// Why a build has no letter though one was asked for.
public enum CoverLetterProblem: Sendable, Equatable, Codable {
    /// Its reply still failed the checks after the repair; what they found.
    case checks(String)
    /// No model in the chain answered; the last one's reason.
    case unavailable(String)

    public var message: String {
        switch self {
        case .checks(let found):
            "The cover letter didn't pass its checks after a second try, so it was left out. What the checks found: \(found.prefix(300))"
        case .unavailable(let reason): "The cover letter was left out because no model could write it: the last one \(reason)."
        }
    }
}

public struct BuildOutcome: Sendable, Equatable {
    public var resume: TailoredResume
    public var score: MatchScore
    /// Sections whose writer failed even after its repair, so they use your master resume's words.
    public var fellBack: [MatchScore.Section]
    public var layout: PageLayout?
    /// Bullets cut to fit the page budget.
    public var dropped: Int
    public var coverLetter: CoverLetter?
    public var coverLetterProblem: CoverLetterProblem?

    public var pages: Int? { layout?.pages }
}

/// One build: select from the master resume, write the sections in parallel, add Stretch mode's gap
/// bullets, shorten bullets that waste a line, fit the page budget, and write the letter if asked.
/// Every bullet a writer returns has passed the verifier. A writer that fails falls back to your
/// bullets word for word, and a failed optional step is skipped: only stopping the build or the
/// budget running out ends it.
///
/// There's no rewrite loop: the first Kairos's rewrites cost two to four calls a build and often
/// made sections thinner, so the match score is a report, not a trigger.
public struct Tailor: Sendable {
    public typealias Measure = @Sendable (TailoredResume) async throws -> PageLayout

    public let router: AIRouter
    public let master: MasterResume
    public let selector: Selector
    public let context: AIContext

    public init(router: AIRouter, master: MasterResume, selector: Selector = Selector(), context: AIContext = AIContext()) {
        self.router = router
        self.master = master
        self.selector = selector
        self.context = context
    }

    /// `measure` renders the resume and measures how it fills its pages; without it nothing is fitted.
    public func run(_ request: BuildRequest, measure: Measure? = nil, progress: @Sendable (BuildStep) -> Void = { _ in })
        async throws -> BuildOutcome
    {
        progress(.selecting)
        let selection = selector.select(from: master, for: request.requirements)
        let verifier = Verifier(
            resume: master, mode: request.mode == .stretch ? .stretch : .strict, hiringCompany: request.company,
            companyProducts: request.companyProducts)
        let brief = WriterBrief(
            jobTitle: request.jobTitle, requirements: request.requirements, locale: request.locale,
            lineCharacters: request.lineCharacters)
        let experienceInput = WriteSectionInput(brief: brief, entries: selection.experience, skills: selection.skills, verifier: verifier)
        let projectsInput = WriteSectionInput(brief: brief, entries: selection.projects, skills: selection.skills, verifier: verifier)
        let polish = Polish(locale: request.locale)
        let lite = request.mode == .lite

        progress(.writing)
        async let experienceBullets = section(WriteExperienceTask(), experienceInput, lite: lite)
        async let projectBullets = section(WriteProjectsTask(), projectsInput, lite: lite)
        let summaryInput = WriteSummaryInput(brief: brief, selection: selection, totalYears: master.header.totalYears, verifier: verifier)
        async let summaryText = request.summary ? optional(WriteSummaryTask(), summaryInput)?.summary : nil
        let skillsInput = WriteSkillsInput(brief: brief, skills: selection.skills)
        async let skillGroups = optional(WriteSkillsTask(), skillsInput).map { WriteSkillsTask.groups($0, input: skillsInput) }
        let written = try await (experience: experienceBullets, projects: projectBullets, summary: summaryText, skills: skillGroups)

        var fellBack: [MatchScore.Section] = []
        if written.experience.fellBack { fellBack.append(.experience) }
        if written.projects.fellBack { fellBack.append(.projects) }
        if request.summary, written.summary == nil { fellBack.append(.summary) }
        if written.skills == nil { fellBack.append(.skills) }

        let ranks = Dictionary(
            (selection.experience + selection.projects).flatMap(\.bullets).map { ($0.bullet.id, $0.score) }, uniquingKeysWith: max)
        var resume = TailoredResume(
            header: TailoredResume.Header(master.header), summary: written.summary.map(polish.text),
            skills: written.skills ?? [SkillGroup(label: "Skills", skills: selection.skills.map(\.name))],
            experience: entries(written.experience.entries, from: selection.experience, polish: polish, ranks: ranks),
            projects: entries(written.projects.entries, from: selection.projects, polish: polish, ranks: ranks),
            education: education(), certifications: certifications(for: request.requirements),
            languages: request.requirements.asksForLanguages ? languages() : nil)

        if request.mode == .stretch {
            let input = GapBulletsInput(brief: brief, written: resume, master: master, perRole: request.gapBulletsPerRole, verifier: verifier)
            if !input.isEmpty {
                progress(.gapBullets)
                if let added = try await optional(GapBulletsTask(), input).map({ GapBulletsTask.written($0, input: input) }) {
                    resume.experience = resume.experience.map { Self.adding(added[$0.entryID] ?? [], to: $0, polish: polish) }
                }
            }
        }

        // Bullets a few words past a line cost the page a line each: one call cuts them to a line
        // fewer, keeping every number and claim, before the fitter decides what stays.
        if let measure, !lite {
            let input = ShortenBulletsInput(
                resume, layout: try await measure(resume), lineCharacters: request.lineCharacters, locale: request.locale,
                verifier: verifier)
            if !input.items.isEmpty {
                progress(.shortening)
                if let output = try await optional(ShortenBulletsTask(), input) {
                    resume = ShortenBulletsTask.applying(output, input: input, to: resume, polish: polish)
                }
            }
        }

        var layout: PageLayout?
        var dropped = 0
        var budget = request.pageBudget
        if let measure {
            let fitted = try await PageFitter(budget: request.pageBudget, allowingTwo: request.twoPagesWhenNeeded, measure: measure)
                .fit(resume, progress: progress)
            resume = fitted.resume
            layout = fitted.layout
            dropped = fitted.dropped
            budget = fitted.budget
        }
        let score = MatchScore.score(resume, for: request.requirements, pages: layout?.pages, pageBudget: budget)

        var letter: CoverLetter?
        var problem: CoverLetterProblem?
        if request.coverLetter {
            progress(.coverLetter)
            let input = CoverLetterInput(
                brief: brief, company: request.company, entries: selection.experience + selection.projects,
                skills: selection.skills, totalYears: master.header.totalYears,
                verifier: Verifier(resume: master, companyProducts: request.companyProducts))
            do {
                let result = try await router.run(Redacted(CoverLetterTask(), header: master.header), input: input, context: context)
                letter = CoverLetterTask.letter(result.output, input: input, header: resume.header, date: selector.now)
            } catch {
                if error.stopsEverything { throw error }
                if case .invalidOutput(let found) = error { problem = .checks(found) } else { problem = .unavailable(error.reason) }
            }
        }
        return BuildOutcome(
            resume: resume, score: score, fellBack: fellBack, layout: layout, dropped: dropped, coverLetter: letter,
            coverLetterProblem: problem)
    }

    // MARK: - Writers

    /// The writer's bullets, or your own word for word: in lite mode, or when no model gives a reply
    /// that passes its checks.
    private func section<T: AITask>(_ task: T, _ input: WriteSectionInput, lite: Bool) async throws(AIError)
        -> (entries: [WrittenEntry], fellBack: Bool)
    where T.Input == WriteSectionInput, T.Output == SectionOutput {
        guard !input.entries.isEmpty else { return ([], false) }
        guard !lite else { return (Self.originals(input), false) }
        do {
            let result = try await router.run(Redacted(task, header: master.header), input: input, context: context)
            return (SectionWriter.written(result.output, input: input), false)
        } catch {
            if error.stopsEverything { throw error }
            return (Self.originals(input), true)
        }
    }

    /// Nil when no model gave a usable reply: the build goes on without what it would have added.
    private func optional<T: AITask>(_ task: T, _ input: T.Input) async throws(AIError) -> T.Output? {
        do {
            return try await router.run(Redacted(task, header: master.header), input: input, context: context).output
        } catch {
            if error.stopsEverything { throw error }
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

    private func entries(_ written: [WrittenEntry], from selected: [SelectedEntry], polish: Polish, ranks: [UUID: Double])
        -> [TailoredResume.Entry]
    {
        selected.compactMap { chosen in
            guard let entry = written.first(where: { $0.entryID == chosen.entry.id }) else { return nil }
            let texts = entry.verbatim ? entry.bullets.map(\.text) : polish.bullets(entry.bullets.map(\.text))
            let bullets = zip(entry.bullets, texts).map { bullet, text in
                TailoredBullet(text: text, sourceIDs: bullet.sourceIDs, gap: bullet.gap, rank: bullet.sourceIDs.compactMap { ranks[$0] }.max() ?? 0)
            }
            switch chosen.entry.fields {
            case .experience(let role):
                return TailoredResume.Entry(
                    entryID: chosen.entry.id, title: role.title, organization: role.employer,
                    location: role.location.isEmpty ? nil : role.location, dates: DisplayDates.range(chosen.entry),
                    period: TailoredResume.Period(chosen.entry), bullets: bullets)
            case .project(let project):
                return TailoredResume.Entry(
                    entryID: chosen.entry.id, title: project.name,
                    organization: project.tech.isEmpty ? nil : project.tech.joined(separator: ", "),
                    dates: DisplayDates.range(chosen.entry), period: TailoredResume.Period(chosen.entry), bullets: bullets)
            default:
                return nil
            }
        }
    }

    /// Gap bullets go after a role's own, polished so none opens on a verb the role already used.
    static func adding(_ gaps: [TailoredBullet], to entry: TailoredResume.Entry, polish: Polish) -> TailoredResume.Entry {
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

    /// Your degrees, each with its honours after it.
    private func education() -> [TailoredResume.Entry] {
        master.entries(.education).compactMap { entry in
            guard case .education(let school) = entry.fields else { return nil }
            let title = [school.credential, school.field, school.honours].filter { !$0.isEmpty }.joined(separator: ", ")
            return TailoredResume.Entry(
                entryID: entry.id, title: title.isEmpty ? school.institution : title,
                organization: title.isEmpty ? nil : school.institution, location: school.location.isEmpty ? nil : school.location,
                dates: DisplayDates.range(entry, monthNames: false), period: TailoredResume.Period(entry))
        }
    }

    /// Only when the posting asks about certifications, and only yours that match what it names:
    /// four unasked-for courses cost the page a role.
    private func certifications(for job: JobRequirements) -> [TailoredResume.Entry] {
        guard !job.certificationAsks.isEmpty else { return [] }
        let named = Set(job.certificationAsks.flatMap { Keywords.terms(in: $0) })
        let wanted = named.isEmpty ? Set((job.musts + job.nices).flatMap { Keywords.terms(in: $0) }) : named
        return master.entries(.certification).compactMap { entry in
            guard case .certification(let certificate) = entry.fields, !Keywords.terms(in: certificate.name).isDisjoint(with: wanted)
            else { return nil }
            return TailoredResume.Entry(
                entryID: entry.id, title: certificate.name, dates: entry.start.map { "\($0.year)" },
                period: TailoredResume.Period(entry))
        }
    }

    private func languages() -> String? {
        let spoken = master.languages.map { "\($0.language) (\($0.proficiency.rawValue))" }
        return spoken.isEmpty ? nil : spoken.joined(separator: ", ")
    }

    /// Drops the lowest-ranked bullet of an entry that keeps at least one, older entries and later
    /// bullets first on a tie; then whole projects, last first. False when nothing more can go.
    static func dropLowest(_ resume: inout TailoredResume) -> Bool {
        var lowest: (section: Int, entry: Int, bullet: Int, rank: Double)?
        for (section, entries) in [resume.experience, resume.projects].enumerated() {
            for (entryIndex, entry) in entries.enumerated() where entry.bullets.count > 1 {
                for (bulletIndex, bullet) in entry.bullets.enumerated() where lowest.map({ bullet.rank <= $0.rank }) ?? true {
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
