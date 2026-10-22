import Foundation
import MasterResume
import Store

/// Everything screening reads about you, loaded once per run: your preferences (synced), your work
/// profile (this Mac only), your master resume's skills, languages and years, and the jobs you've
/// applied to.
public struct ScreeningContext: Sendable {
    public var preferences: SearchPreferences
    public var profile: WorkProfile
    public var skills: [Skill]
    public var languages: [EntryFields.Language]
    public var totalYears: Double?
    public var applied: [AppliedJob]
    /// Your master resume as the evidence `analyzeJob` matches against (contact details redacted).
    public var evidence: ScreeningProfile
    /// Sources whose descriptions are snippets (Adzuna): their jobs can't be a Yes.
    public var snippetSources: Set<UUID> = []
    /// Jobs you brought back from Filtered out: the filters never drop them again.
    public var broughtBack: Set<JobID> = []

    /// Where `broughtBack` is kept (a synced setting: job ids only).
    public static let broughtBackKey = "screening.broughtBack"

    /// `resume` gives `analyzeJob` your whole master resume to match against; without it, only
    /// your skill names and languages.
    public init(
        preferences: SearchPreferences = SearchPreferences(), profile: WorkProfile = WorkProfile(),
        skills: [Skill] = [],
        languages: [EntryFields.Language] = [], totalYears: Double? = nil, applied: [AppliedJob] = [],
        resume: MasterResume? = nil
    ) {
        self.preferences = preferences
        self.profile = profile
        self.skills = skills
        self.languages = languages
        self.totalYears = totalYears
        self.applied = applied
        evidence =
            resume.map(ScreeningProfile.init)
            ?? ScreeningProfile(skills: skills, languages: languages, totalYears: totalYears)
    }

    public static func load(from db: Database) async throws -> ScreeningContext {
        let resume = try await MasterResumeRepository(db).load()
        let applied = try await JobRepository(db).jobs(matching: JobFilter(states: [.applied]))
        var context = ScreeningContext(
            preferences: try await SettingsRepository(db).value(
                SearchPreferences.storageKey, as: SearchPreferences.self)
                ?? SearchPreferences(),
            profile: try await PrivateSettingsRepository(db).value(WorkProfile.storageKey, as: WorkProfile.self)
                ?? WorkProfile(),
            skills: resume.skills,
            languages: resume.entries.compactMap { entry in
                if case .language(let language) = entry.fields { language } else { nil }
            },
            totalYears: resume.header.totalYears,
            applied: applied.map { AppliedJob(company: $0.company, title: $0.title) }, resume: resume)
        context.snippetSources = Set(try await SourceRepository(db).sources().filter { $0.kind == .adzuna }.map(\.id))
        context.broughtBack = Set(
            (try await SettingsRepository(db).value(Self.broughtBackKey, as: [String].self) ?? []).map(
                JobID.init(rawValue:)))
        return context
    }

    /// Whether `job`'s description is only a search's snippet.
    public func isSnippet(_ job: Job) -> Bool { snippetSources.contains(job.sourceID) }

    public func prefilter(now: Date) -> Prefilter {
        Prefilter(preferences: preferences, profile: profile, languages: languages, applied: applied, now: now)
    }

    public func verdictEngine() -> VerdictEngine {
        VerdictEngine(preferences: preferences, profile: profile, languages: languages, totalYears: totalYears)
    }

    public func analysisInput(for job: Job) -> AnalyzeJobTask.Input {
        AnalyzeJobTask.Input(job: job, profile: evidence)
    }

    /// Where a verdict puts the job in Today's list.
    public func rank(_ verdict: Verdict, for job: Job, match: Double) -> Double {
        Ranking.rank(verdict, country: job.country, match: match, countries: preferences.countries)
    }
}
