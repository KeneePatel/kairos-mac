import Foundation
import MasterResume
import Store
import Testing

@testable import Screening

private let now = Date(timeIntervalSince1970: 1_790_000_000)

private func job(_ title: String) -> Job {
    Job(
        canonicalURL: "https://jobs.example.com/\(title)", sourceID: UUID(), url: "https://jobs.example.com/1",
        dedupKey: "k", company: "Acme", title: title, country: .canada, remoteScope: .onsite, postedAt: now,
        descriptionMarkdown: "Build services.", firstSeenAt: now)
}

private func prefilter(roles: Set<RoleFamily>, titles: [String] = []) -> Prefilter {
    var preferences = SearchPreferences()
    preferences.roles = roles
    preferences.titleInclude = titles
    return Prefilter(
        preferences: preferences, profile: WorkProfile(),
        languages: [EntryFields.Language(language: "English", proficiency: .native)], now: now)
}

/// Job collection v2, J3: the title rule reads your roles, with their usual variants.
@Suite("Role filter")
struct RoleFilterTests {
    /// The Amazon title a literal phrase list dropped on 2026-10-23 passes; look-alikes don't, and
    /// say which roles they missed.
    @Test func rolesDecideTheTitleRule() throws {
        let filter = prefilter(roles: [.software, .devops], titles: ["Technical Writer"])
        #expect(filter.rejection(for: job("Software Development Engineer, Navigator")) == nil)
        #expect(filter.rejection(for: job("SRE II")) == nil)
        #expect(filter.rejection(for: job("Technical Writer")) == nil)
        let rejection = try #require(filter.rejection(for: job("Business Development Manager")))
        #expect(rejection.rule == .titleInclude)
        #expect(
            rejection.reason
                == "The title isn't one of your roles (Software development; DevOps, cloud and SRE) or other titles (Technical Writer)."
        )
        #expect(prefilter(roles: [.data]).rejection(for: job("QA Analyst"))?.reason.hasSuffix("engineering).") == true)
    }

    /// Settings saved before roles existed read as none; roles round-trip.
    @Test func olderSettingsHaveNoRoles() throws {
        let old = try JSONDecoder().decode(SearchPreferences.self, from: Data(#"{"titleInclude":["Developer"]}"#.utf8))
        #expect(old.roles.isEmpty && old.titleInclude == ["Developer"])
        var preferences = SearchPreferences()
        preferences.roles = [.software, .qa]
        let back = try JSONDecoder().decode(SearchPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(back.roles == [.software, .qa])
        #expect(back.roleMatcher == RoleMatcher(families: [.software, .qa]))
    }
}
