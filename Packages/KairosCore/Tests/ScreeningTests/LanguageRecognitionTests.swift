import Foundation
import MasterResume
import Store
import Testing

@testable import Screening

// A made-up posting: fixtures only.

private let flags = JobAnalysis.Flags(
    sponsorship: .notMentioned, clearance: .notMentioned, french: .notMentioned, remoteScope: .onsite)

private let posting = Job(
    canonicalURL: "https://jobs.example.com/harbour/software-engineer", sourceID: UUID(),
    url: "https://jobs.example.com/1", dedupKey: "harbour|software engineer|richmond", company: "Harbour Labs",
    title: "Software Engineer", location: "Richmond, BC", region: "BC", country: .canada, remoteScope: .onsite,
    descriptionMarkdown: "English.", firstSeenAt: Date())

private func analysis(_ text: String, match: JobAnalysis.Requirement.Match = .no) -> JobAnalysis {
    JobAnalysis(
        requirements: [.init(text: text, kind: .must, category: .language, match: match, evidence: [])],
        yearsRequired: nil, seniority: nil, domains: [], flags: flags)
}

private func engine(_ languages: [EntryFields.Language]) -> VerdictEngine {
    VerdictEngine(
        preferences: SearchPreferences(), profile: WorkProfile(authorization: [.canada: .workPermit]),
        languages: languages, totalYears: 1)
}

private let english = EntryFields.Language(language: "English", proficiency: .fluent)
private let hindi = EntryFields.Language(language: "Hindi", proficiency: .native)

@Suite struct LanguageRecognitionTests {
    /// 2026-10-22: a posting asking only for English was a No ("Missing English") for someone who
    /// lists English as fluent. A language you list now counts as shown, citing it.
    @Test func aLanguageYouListCountsAsShown() {
        let recognised = analysis("English").recognizingLanguages([hindi, english])
        #expect(recognised.requirements[0].match == .yes)
        #expect(recognised.requirements[0].evidence == ["l2"])

        let decision = engine([hindi, english]).decide(analysis("Fluent written and spoken English"), for: posting)
        #expect(decision.verdict == .yes)
        #expect(decision.coverage.mustCovered == 1)
    }

    @Test func aBasicLevelOrAnUnspokenSecondLanguageIsLeftToTheModel() {
        let basic = EntryFields.Language(language: "English", proficiency: .basic)
        #expect(analysis("English").recognizingLanguages([basic]).requirements[0].match == .no)
        // Bilingual in English and French, and you don't speak French: still not shown.
        #expect(
            analysis("Bilingual in English and French").recognizingLanguages([english]).requirements[0].match == .no)
        // A language you don't list stays as the model read it.
        #expect(analysis("Mandarin").recognizingLanguages([english]).requirements[0].match == .no)
        let partly = analysis("Spanish", match: .partial).recognizingLanguages([english])
        #expect(partly.requirements[0].match == .partial)
    }
}
