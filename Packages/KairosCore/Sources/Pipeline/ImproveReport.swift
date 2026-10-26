import Foundation
import MasterResume
import Screening
import Store
import Tailoring

/// Improve (P11, 2026-10-22): what keeps Review's No and Maybe jobs from a Yes, as fixes ranked by
/// how many verdicts each could move. A fix groups what several postings ask for (a technology,
/// a broader term, a kind of work, or years), says where your master resume stands on it, and
/// counts the verdicts that would change if the asks were shown, by running the same verdict code
/// on the stored analyses: an upper bound, and no AI call. Snippets, search settings and reasons no
/// resume changes are kept apart.
public struct ImproveReport: Sendable, Equatable {
    /// One posting's requirement, as it asked it.
    public struct Ask: Sendable, Equatable {
        public let job: JobID
        public let text: String
        public let kind: JobAnalysis.Requirement.Kind
        public let match: JobAnalysis.Requirement.Match
    }

    public enum Kind: Sendable, Equatable {
        /// A technology, or a broader term such as "cloud".
        case technology
        /// A kind of work: distributed systems, testing, security…
        case theme
        case years
        /// An ask nothing else groups with.
        case other
    }

    /// Where your master resume stands on a fix.
    public enum Standing: Sendable, Equatable {
        /// In your Skills as Proven, spelled as you spell it.
        case proven(String)
        case canDiscuss(String)
        /// Named in a role or project (its heading), but not in your Skills.
        case mentioned(String)
        case absent
    }

    public struct Fix: Sendable, Equatable, Identifiable {
        /// "tech:kubernetes", "concept:cloud", "theme:testing", "years", "other:…".
        public let id: String
        public let title: String
        public let kind: Kind
        public let standing: Standing
        /// In the jobs' order.
        public let asks: [Ask]
        public let jobs: [JobID]
        /// Verdicts that would become Yes, and No that would become Maybe, if the asks were shown.
        public let toYes: Int
        public let toMaybe: Int
    }

    /// Your Total years against the months your dated roles cover.
    public struct Years: Sendable, Equatable {
        public let stated: Double?
        /// Each month counted once, however many roles overlap it.
        public let datedMonths: Int
    }

    /// A title your list leaves out that's close to one in it: adding it lets these jobs through
    /// all your filters.
    public struct TitleMiss: Sendable, Equatable, Identifiable {
        public var id: String { phrase }
        public let phrase: String
        public let jobs: [JobID]
    }

    /// Jobs a reason no resume changes decided: your level setting, sponsorship, French…
    public struct Held: Sendable, Equatable, Identifiable {
        public var id: VerdictRule { rule }
        public let rule: VerdictRule
        public let jobs: [JobID]

        public init(rule: VerdictRule, jobs: [JobID]) {
            self.rule = rule
            self.jobs = jobs
        }
    }

    /// No and Maybe jobs the AI analysed.
    public let analysed: Int
    /// Of those, decided by how much of the posting your resume shows, or by years.
    public let considered: Int
    /// Ranked.
    public let fixes: [Fix]
    /// Asked by one posting, for something nowhere on your resume, or grouped with nothing.
    public let oneOffs: [Fix]
    public let years: Years
    public let titleMisses: [TitleMiss]
    /// No because they ask for more years than your limit in Settings, Search.
    public let yearsLimit: [JobID]
    public let held: [Held]

    /// `jobs`: Review's No and Maybe jobs. `analyses`: the current prompt's, by job.
    /// `filteredByTitle`: jobs your title list dropped.
    public init(
        jobs: [Job], screenings: [String: ScreeningRecord], analyses: [JobID: JobAnalysis], filteredByTitle: [Job],
        resume: MasterResume, preferences: SearchPreferences, profile: WorkProfile, now: Date = Date()
    ) {
        let languages = resume.entries(.language).compactMap { entry -> EntryFields.Language? in
            guard case .language(let language) = entry.fields else { return nil }
            return language
        }
        let stated = resume.header.totalYears
        let engine = VerdictEngine(
            preferences: preferences, profile: profile, languages: languages, totalYears: stated)
        let datedMonths = Self.datedMonths(resume, now: now)
        years = Years(stated: stated, datedMonths: datedMonths)

        var analysed = 0
        var yearsLimit: [JobID] = []
        var held: [VerdictRule: [JobID]] = [:]
        var considered: [(job: Job, analysis: JobAnalysis, verdict: Verdict)] = []
        for job in jobs where job.verdict != .yes {
            guard let record = screenings[job.id.rawValue], record.stage == .analysis,
                let rule = record.ruleID.flatMap(VerdictRule.init(rawValue:))
            else { continue }
            analysed += 1
            switch rule {
            // Before v3, a snippet's Maybe; such jobs are archived now (ADR-018).
            case .snippetOnly: break
            case .seniority, .workAuthorization, .remoteScope, .clearance, .french, .enrolment:
                held[rule, default: []].append(job.id)
            case .yearsRequired: yearsLimit.append(job.id)
            case .noRequirements, .strongMatch: break
            case .weakMatch, .partialMatch, .yearsAboveYours:
                guard let analysis = analyses[job.id]?.recognizingLanguages(languages) else { continue }
                considered.append((job, analysis, engine.decide(analysis, for: job).verdict))
            }
        }
        self.analysed = analysed
        self.considered = considered.count
        self.yearsLimit = yearsLimit
        self.held = VerdictRule.allCases.compactMap { rule in held[rule].map { Held(rule: rule, jobs: $0) } }

        // Group each unmet requirement; a requirement naming two things counts toward both.
        var groups: [String: Group] = [:]
        var order: [String] = []
        for (index, entry) in considered.enumerated() {
            for (position, requirement) in entry.analysis.requirements.enumerated()
            where requirement.counts && [.no, .partial].contains(requirement.effectiveMatch) {
                for key in Self.keys(requirement.text) {
                    if groups[key.id] == nil {
                        groups[key.id] = Group(key: key)
                        order.append(key.id)
                    }
                    groups[key.id]?.add(
                        Ask(
                            job: entry.job.id, text: requirement.text, kind: requirement.kind,
                            match: requirement.effectiveMatch),
                        job: index, requirement: position, written: key.written)
                }
            }
        }
        // Jobs held at Maybe or No by years alone, with no years line among their requirements.
        for (index, entry) in considered.enumerated() {
            guard let required = entry.analysis.yearsRequired, let stated, Double(required) > stated,
                groups["years"]?.requirements[index] == nil
            else { continue }
            if groups["years"] == nil {
                groups["years"] = Group(key: Key(id: "years", kind: .years, written: nil))
                order.append("years")
            }
            groups["years"]?.add(
                Ask(job: entry.job.id, text: "\(required)+ years of experience", kind: .must, match: .no), job: index,
                requirement: nil, written: nil)
        }

        let datedYears = Double(datedMonths) / 12
        let shown = Evidence(resume)
        var fixes: [Fix] = []
        var oneOffs: [Fix] = []
        for id in order {
            guard let group = groups[id] else { continue }
            var toYes = 0
            var toMaybe = 0
            for (index, positions) in group.requirements {
                let entry = considered[index]
                var analysis = entry.analysis
                var judge = engine
                if group.key.kind == .years {
                    // Only what your dated roles really cover: an ask for more stays unmet.
                    judge = VerdictEngine(
                        preferences: preferences, profile: profile, languages: languages,
                        totalYears: max(stated ?? 0, datedYears))
                    for position in positions
                    where Self.yearsAsked(analysis.requirements[position].text).map({ $0 <= datedYears }) ?? false {
                        analysis.requirements[position].match = .yes
                    }
                } else {
                    for position in positions { analysis.requirements[position].match = .yes }
                }
                let after = judge.decide(analysis, for: entry.job).verdict
                if after == .yes, entry.verdict != .yes { toYes += 1 }
                if after == .maybe, entry.verdict == .no { toMaybe += 1 }
            }
            let standing = shown.standing(of: group.key, written: group.written)
            let fix = Fix(
                id: id, title: Self.title(group, standing: standing), kind: group.key.kind, standing: standing,
                asks: group.asks, jobs: group.jobs, toYes: toYes, toMaybe: toMaybe)
            let oneOff = fix.kind == .other || (fix.kind != .years && fix.standing == .absent && fix.jobs.count < 2)
            if oneOff { oneOffs.append(fix) } else { fixes.append(fix) }
        }
        let rank: (Fix, Fix) -> Bool = {
            ($0.toYes, $0.toMaybe, $0.jobs.count, $1.title) > ($1.toYes, $1.toMaybe, $1.jobs.count, $0.title)
        }
        self.fixes = fixes.sorted(by: rank)
        self.oneOffs = oneOffs.sorted(by: rank)
        titleMisses = Self.titleMisses(
            filteredByTitle, preferences: preferences, profile: profile, languages: languages, now: now)
    }

    // MARK: - Grouping

    struct Key: Sendable, Equatable {
        let id: String
        let kind: Kind
        /// For a technology: its canonical name; for a broader term: the technologies it stands for.
        var members: [String] = []
        /// The words as the requirement wrote them.
        let written: String?
    }

    private struct Group {
        let key: Key
        var asks: [Ask] = []
        var jobs: [JobID] = []
        /// By considered job: the requirements this group covers.
        var requirements: [Int: [Int]] = [:]
        var written: String?

        mutating func add(_ ask: Ask, job: Int, requirement: Int?, written: String?) {
            asks.append(ask)
            if !jobs.contains(ask.job) { jobs.append(ask.job) }
            requirements[job, default: []] += requirement.map { [$0] } ?? []
            if self.written == nil { self.written = written }
        }
    }

    /// Years first, then technologies, else broader terms, else a kind of work, else the ask itself.
    static func keys(_ text: String) -> [Key] {
        var keys: [Key] = []
        if yearsAsked(text) != nil { keys.append(Key(id: "years", kind: .years, written: nil)) }
        let named = TechVocabulary.technologies(in: text)
        keys += named.map {
            Key(id: "tech:\($0.canonical)", kind: .technology, members: [$0.canonical], written: $0.written)
        }
        if named.isEmpty {
            let concepts = TechVocabulary.concepts(in: text)
            keys += concepts.map {
                Key(id: "concept:\($0.concept)", kind: .technology, members: $0.members, written: nil)
            }
            if concepts.isEmpty, keys.isEmpty {
                let folded = fold(text)
                if let theme = themes.first(where: { folded.range(of: $0.pattern, options: .regularExpression) != nil })
                {
                    keys.append(Key(id: "theme:\(theme.name)", kind: .theme, written: nil))
                } else {
                    keys.append(Key(id: "other:\(folded.prefix(80))", kind: .other, written: text))
                }
            }
        }
        return keys
    }

    /// Broader terms whose plain capitalization reads wrong.
    static let conceptNames = ["ci/cd": "CI/CD", "nosql": "NoSQL", "frontend": "Front-end frameworks"]

    /// Kinds of work postings ask for without naming a tool, in the order they're tried.
    static let themes: [(name: String, pattern: String)] = [
        ("Distributed systems", #"distributed"#),
        (
            "Production and scale",
            #"production|at scale|large[- ]scale|scalab|high[- ]availab|fault[- ]toleran|performance|reliab"#
        ),
        ("Testing", #"\btest(s|ing|ed)?\b|\bqa\b"#),
        (
            "Security and identity",
            #"secur|cryptograph|authenticat|authoriz|oauth|\boidc\b|\bsso\b|\biam\b|identity (and|&) access|identity management"#
        ),
        ("System design", #"system design|architect"#),
        ("APIs and back end", #"\bapis?\b|back[- ]?end|server[- ]side|microservice"#),
        ("Front end and web", #"front[- ]?end|browser|\bweb\b|\bui\b"#),
        ("Data and machine learning", #"\bdata\b|machine learning|\bml\b|\bai\b|\bllms?\b"#),
        ("Mobile", #"mobile|\bios\b|android"#),
    ]

    /// "2+ years", "1.5+ years", "3–5 years": the least asked. Nil when the text asks for no years.
    static func yearsAsked(_ text: String) -> Double? {
        let pattern = #"(\d+(?:\.\d+)?)\s*\+?\s*(?:(?:-|–|to)\s*\d+(?:\.\d+)?\s*)?\+?\s*(?:years?|yrs?)\b"#
        guard let range = fold(text).range(of: pattern, options: .regularExpression) else { return nil }
        let found = fold(text)[range]
        return found.split(whereSeparator: { !$0.isNumber && $0 != "." }).first.flatMap { Double($0) }
    }

    private static func title(_ group: Group, standing: Standing) -> String {
        switch group.key.kind {
        case .years: return "Years of experience"
        case .theme: return String(group.key.id.dropFirst("theme:".count))
        case .other: return group.written ?? group.asks.first?.text ?? ""
        case .technology:
            // A broader term keeps its own name ("Observability"), even when a skill of yours is
            // one of the technologies it stands for.
            if group.key.id.hasPrefix("concept:") {
                let concept = String(group.key.id.dropFirst("concept:".count))
                return conceptNames[concept] ?? concept.prefix(1).uppercased() + concept.dropFirst()
            }
            switch standing {
            case .proven(let name), .canDiscuss(let name): return name
            case .mentioned, .absent: return group.written ?? group.asks.first?.text ?? ""
            }
        }
    }

    // MARK: - Your resume

    /// What your master resume names: skills by level, and the technologies and words in each
    /// role and project.
    private struct Evidence {
        let skills: [(canonical: Set<String>, name: String, level: SkillLevel)]
        let entries: [(heading: String, text: String, technologies: Set<String>)]

        init(_ resume: MasterResume) {
            skills = resume.skills.map { skill in
                (Set(TechVocabulary.technologies(in: skill.name).map(\.canonical)), skill.name, skill.level)
            }
            entries = (resume.entries(.experience) + resume.entries(.project)).compactMap { entry in
                let heading: String
                var texts = entry.bullets.map(\.text)
                switch entry.fields {
                case .experience(let role):
                    heading = [role.title, role.employer].filter { !$0.isEmpty }.joined(separator: " · ")
                case .project(let project):
                    heading = project.name
                    texts += project.tech
                default: return nil
                }
                let text = texts.joined(separator: "\n")
                return (heading, fold(text), Set(TechVocabulary.technologies(in: text).map(\.canonical)))
            }
        }

        func standing(of key: Key, written: String?) -> Standing {
            switch key.kind {
            case .technology:
                let members = Set(key.members)
                for level in [SkillLevel.proven, .canDiscuss] {
                    if let skill = skills.first(where: { $0.level == level && !$0.canonical.isDisjoint(with: members) })
                    {
                        return level == .proven ? .proven(skill.name) : .canDiscuss(skill.name)
                    }
                }
                return entries.first { !$0.technologies.isDisjoint(with: members) }.map { .mentioned($0.heading) }
                    ?? .absent
            case .theme:
                let name = String(key.id.dropFirst("theme:".count))
                guard let pattern = themes.first(where: { $0.name == name })?.pattern else { return .absent }
                return entries.first { $0.text.range(of: pattern, options: .regularExpression) != nil }
                    .map { .mentioned($0.heading) } ?? .absent
            case .years, .other:
                return .absent
            }
        }
    }

    /// Months your dated roles cover, each once; a current role runs to `now`.
    static func datedMonths(_ resume: MasterResume, now: Date) -> Int {
        var months: Set<Int> = []
        for entry in resume.entries(.experience) {
            guard let start = entry.start else { continue }
            let end = entry.isCurrent ? YearMonth.containing(now) : entry.end ?? start
            let first = start.year * 12 + start.month - 1
            let last = end.year * 12 + end.month - 1
            if first <= last { months.formUnion(first...last) }
        }
        return months.count
    }

    // MARK: - Search

    /// Dropped titles with every word of one of your title phrases, just not together ("Software
    /// Development Engineer" for "Software Engineer"), that would pass all your filters with
    /// their own title added. By title, most jobs first.
    static func titleMisses(
        _ jobs: [Job], preferences: SearchPreferences, profile: WorkProfile, languages: [EntryFields.Language],
        now: Date
    ) -> [TitleMiss] {
        let phrases = preferences.titleInclude.map(words).filter { !$0.isEmpty }
        var found: [String: (phrase: String, jobs: [JobID])] = [:]
        var order: [String] = []
        for job in jobs {
            let phrase = core(job.title)
            let titleWords = Set(words(phrase))
            guard !phrase.isEmpty, phrases.contains(where: { titleWords.isSuperset(of: $0) }) else { continue }
            var widened = preferences
            widened.titleInclude.append(phrase)
            let filter = Prefilter(preferences: widened, profile: profile, languages: languages, now: now)
            guard filter.rejection(for: job) == nil else { continue }
            let key = fold(phrase)
            if found[key] == nil {
                found[key] = (phrase, [])
                order.append(key)
            }
            found[key]?.jobs.append(job.id)
        }
        return order.compactMap { found[$0].map { TitleMiss(phrase: $0.phrase, jobs: $0.jobs) } }
            .sorted { ($0.jobs.count, $1.phrase) > ($1.jobs.count, $0.phrase) }
    }

    /// The title before a team or place: "Software Development Engineer, Payments" is
    /// "Software Development Engineer".
    static func core(_ title: String) -> String {
        var core = Substring(title)
        for separator in [",", " - ", " – ", " — ", "(", "|", ":", "/"] {
            if let range = core.range(of: separator) { core = core[..<range.lowerBound] }
        }
        return core.trimmingCharacters(in: .whitespaces)
    }

    private static func words(_ text: String) -> [String] {
        fold(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func fold(_ text: String) -> String {
        text.lowercased().folding(
            options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
