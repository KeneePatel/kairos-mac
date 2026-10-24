import Foundation
import JobSources
import Store
import Synchronization
import TestSupport
import Testing

@testable import Pipeline

private let day0 = Date(timeIntervalSince1970: 1_790_000_000)
private let snippet =
    "Syndio is looking for a software engineer to build integrations with HR systems across the US and Calgary teams"

private func database() async throws -> Database {
    let db = try Database(path: ":memory:")
    try await Migrator.migrate(db, with: Migrator.bundled())
    return db
}

private func adzunaPosting(_ source: SourceID) -> Posting {
    Posting(
        sourceID: source, url: URL(string: "https://www.adzuna.ca/land/ad/1")!, company: "Syndio",
        title: "Software Engineer, Integrations (US Calgary)", location: "Calgary, Alberta", postedAt: day0,
        descriptionHTML: "<p>\(snippet)…</p>")
}

private func boardPosting(_ source: SourceID, title: String = "Software Engineer, Integrations (US + Calgary)")
    -> Posting
{
    Posting(
        sourceID: source, url: URL(string: "https://job-boards.greenhouse.io/syndio/jobs/7")!, company: "Syndio",
        title: title, location: "Calgary, Alberta, Canada", postedAt: day0,
        descriptionHTML: "<p>\(snippet). You'll own our Workday and BambooHR connectors in Go.</p>")
}

/// An HTTP client only these replies can answer.
private func scripted(_ replies: [String: ScriptedURLProtocol.Reply]) -> (
    URLSessionHTTPClient, ScriptedURLProtocol.Script
) {
    let (configuration, script) = ScriptedURLProtocol.configuration(replies)
    return (URLSessionHTTPClient(configuration: configuration, userAgent: "Kairos-tests"), script)
}

private struct Answer: JobSource {
    let id: SourceID
    let postings: [Posting]
    var listsEverything: Bool
    func fetch(_ query: SourceQuery) async throws -> [Posting] { postings }
}

/// Job collection v2, J6: snippets filled in from companies' own boards.
@Suite("Snippet finder")
struct SnippetFinderTests {
    /// A snippet's opening words found in a posting's text.
    @Test func aSnippetIsFoundInItsPosting() {
        #expect(ListingLedgerContains.check(snippet: snippet, in: "Intro. \(snippet). More."))
        #expect(!ListingLedgerContains.check(snippet: snippet, in: "Something else entirely about sales"))
        #expect(!ListingLedgerContains.check(snippet: "Too short", in: "Too short"))
    }

    /// The finder looks up each company once, finds its board, adds it as a source from a search,
    /// and remembers a miss for a month.
    @Test func itFindsTheBoardAndRemembers() async throws {
        let db = try await database()
        let adzuna = try await SourceRepository(db).add(kind: .adzuna)
        _ = try await ListingLedger(db).record(
            [adzunaPosting(adzuna.id)] + [
                Posting(
                    sourceID: adzuna.id, url: URL(string: "https://www.adzuna.ca/land/ad/2")!, company: "Nowhere Ltd",
                    title: "Backend Developer", location: "Toronto, Ontario", postedAt: day0,
                    descriptionHTML: "<p>Build things.</p>")
            ], from: adzuna.id, kind: .adzuna, complete: false, at: day0)
        let (http, script) = scripted([
            "https://boards-api.greenhouse.io/v1/boards/syndio/jobs": .http(
                status: 200, body: Data(#"{"jobs":[{"title":"x"}]}"#.utf8))
        ])
        let finder = SnippetFinder(
            db: db, probe: BoardProbe(http: http), catalog: BoardCatalog(checked: "", boards: []), now: { day0 })
        let found = await finder.findBoards()
        #expect(found.count == 1 && found.first?.kind == .greenhouse)
        #expect(
            BoardConfig.decode(found.first?.config ?? "")
                == BoardConfig(slug: "syndio", company: "Syndio", origin: "search"))
        let asked = script.requests.count
        #expect(await finder.findBoards().isEmpty && script.requests.count == asked)
        let lookups = try await db.query("SELECT name_key, kind FROM company_lookup ORDER BY name_key")
        #expect(lookups.map { $0.string("name_key") ?? "" } == ["nowhere", "syndio"])
        #expect(lookups.map { $0.string("kind") } == [nil, "greenhouse"])
    }

    /// Job sites that appear as a search's company aren't looked up: their boards repost others' jobs.
    @Test func aggregatorsArentLookedUp() async throws {
        let db = try await database()
        let adzuna = try await SourceRepository(db).add(kind: .adzuna)
        _ = try await ListingLedger(db).record(
            [
                Posting(
                    sourceID: adzuna.id, url: URL(string: "https://www.adzuna.ca/land/ad/3")!, company: "Jobgether",
                    title: "Backend Developer", location: "Toronto, Ontario", postedAt: day0,
                    descriptionHTML: "<p>Remote role.</p>")
            ], from: adzuna.id, kind: .adzuna, complete: false, at: day0)
        let (http, script) = scripted([:])
        let finder = SnippetFinder(
            db: db, probe: BoardProbe(http: http), catalog: BoardCatalog(checked: "", boards: []), now: { day0 })
        #expect(await finder.findBoards().isEmpty && script.requests.isEmpty)
    }

    /// A board's copy of a stored snippet fills it in even when it's older than your "Posted"
    /// limit: it isn't a new job.
    @Test func anOlderCopyStillFillsInTheSnippet() async throws {
        let db = try await database()
        let adzuna = try await SourceRepository(db).add(kind: .adzuna)
        let board = try await SourceRepository(db).add(kind: .greenhouse)
        _ = try await ListingLedger(db).record(
            [adzunaPosting(adzuna.id)], from: adzuna.id, kind: .adzuna, complete: false, at: day0)
        var old = boardPosting(board.id)
        old.postedAt = day0.addingTimeInterval(-30 * 86_400)
        let outcome = try await ListingLedger(db).record(
            [old], from: board.id, kind: .greenhouse, complete: true, at: day0,
            postedAfter: day0.addingTimeInterval(-7 * 86_400), roles: RoleMatcher(families: [.qa]))
        #expect(outcome.upgraded == 1 && outcome.tooOld == 0 && outcome.otherRoles == 0)
    }

    /// In a fetch: Adzuna's snippet, then the finder adds Syndio's board and reads it, and the
    /// board's full posting replaces the snippet, though its title isn't word for word the same.
    @Test func aFetchFillsInTheSnippet() async throws {
        let db = try await database()
        _ = try await SourceRepository(db).add(kind: .adzuna)
        let (http, _) = scripted([
            "https://boards-api.greenhouse.io/v1/boards/syndio/jobs": .http(
                status: 200, body: Data(#"{"jobs":[{"title":"x"}]}"#.utf8))
        ])
        let finder = SnippetFinder(
            db: db, probe: BoardProbe(http: http), catalog: BoardCatalog(checked: "", boards: []), now: { day0 })
        let run = FetchRun(
            db: db, now: { day0 }, finder: finder,
            makeSource: { source in
                source.kind == .adzuna
                    ? (
                        Answer(id: source.id, postings: [adzunaPosting(source.id)], listsEverything: false),
                        SourceQuery()
                    )
                    : (
                        Answer(
                            id: source.id,
                            postings: [boardPosting(source.id, title: "Software Engineer - Integrations")],
                            listsEverything: true), SourceQuery()
                    )
            })
        var last = FetchRun.Progress()
        for await progress in run.start() { last = progress }
        #expect(
            last.boardsFound == 1 && last.upgraded == 1 && last.added == 1,
            "found \(last.boardsFound), upgraded \(last.upgraded), added \(last.added), failures \(last.failures)")
        let job = try #require(try await JobRepository(db).jobs().first)
        #expect(job.descriptionKind == .full && job.descriptionMarkdown?.contains("BambooHR connectors") == true)
        #expect(try await ListingRepository(db).listings(of: job.id).count == 2)
    }
}

/// The ledger's containment check, reached for the tests.
private enum ListingLedgerContains {
    static func check(snippet: String, in full: String) -> Bool { ListingLedger.contains(snippet: snippet, in: full) }
}
