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

    public init(
        preferences: SearchPreferences = SearchPreferences(), profile: WorkProfile = WorkProfile(),
        skills: [Skill] = [],
        languages: [EntryFields.Language] = [], totalYears: Double? = nil, applied: [AppliedJob] = []
    ) {
        self.preferences = preferences
        self.profile = profile
        self.skills = skills
        self.languages = languages
        self.totalYears = totalYears
        self.applied = applied
    }

    public static func load(from db: Database) async throws -> ScreeningContext {
        let resume = try await MasterResumeRepository(db).load()
        let applied = try await JobRepository(db).jobs(matching: JobFilter(states: [.applied]))
        return ScreeningContext(
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
            applied: applied.map { AppliedJob(company: $0.company, title: $0.title) })
    }

    public func prefilter(now: Date) -> Prefilter {
        Prefilter(preferences: preferences, profile: profile, languages: languages, applied: applied, now: now)
    }

    public func verdictEngine() -> VerdictEngine {
        VerdictEngine(preferences: preferences, profile: profile, languages: languages, totalYears: totalYears)
    }

    public func analysisInput(for job: Job) -> AnalyzeJobTask.Input {
        AnalyzeJobTask.Input(job: job, skills: skills, languages: languages)
    }

    /// Where a verdict puts the job in Today's list.
    public func rank(_ verdict: Verdict, for job: Job, match: Double) -> Double {
        Ranking.rank(verdict, country: job.country, match: match, countries: preferences.countries)
    }
}
