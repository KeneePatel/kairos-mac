import Foundation
import TestSupport
import Testing

@testable import JobSources

private let sourceID = UUID(uuidString: "0199f0a0-0000-7000-8000-0000000000cc")!
private let greenhouse = "https://boards-api.greenhouse.io/v1/boards/acmerobotics/jobs?content=true"
private let lever = "https://api.lever.co/v0/postings/acmerobotics?mode=json"
private let leverEU = "https://api.eu.lever.co/v0/postings/acmerobotics?mode=json"
private let ashby = "https://api.ashbyhq.com/posting-api/job-board/acmerobotics"

/// Job collection v2: a board that hasn't changed since its last ETag answers 304 with nothing,
/// so watching hundreds of boards costs a tiny request each (2026-10-23: 0 bytes instead of 2 MB).
@Suite("Conditional board fetches")
struct ConditionalFetchTests {
    /// The first answer brings its ETag; asking again with it, an unchanged board says so.
    @Test(arguments: ["greenhouse", "lever", "ashby"])
    func anUnchangedBoardSaysSo(_ kind: String) async throws {
        let (url, fixture) =
            switch kind {
            case "greenhouse": (greenhouse, "greenhouse_jobs.json")
            case "lever": (lever, "lever_postings.json")
            default: (ashby, "ashby_job_board.json")
            }
        let body = try ScriptedURLProtocol.fixture(fixture)
        func source(_ http: URLSessionHTTPClient) -> any JobSource {
            switch kind {
            case "greenhouse": GreenhouseSource(id: sourceID, boardToken: "acmerobotics", http: http)
            case "lever": LeverSource(id: sourceID, slug: "acmerobotics", http: http)
            default: AshbySource(id: sourceID, organization: "acmerobotics", http: http)
            }
        }
        let (fresh, firstScript) = ScriptedURLProtocol.client([
            url: .http(status: 200, headers: ["ETag": #"W/"v1""#], body: body)
        ])
        let first = try await source(fresh).fetch(SourceQuery(), since: nil)
        guard case .postings(let postings, let memo) = first else {
            Issue.record("expected postings")
            return
        }
        #expect(!postings.isEmpty && memo == FetchMemo(etag: #"W/"v1""#))
        #expect(firstScript.requests.first?.value(forHTTPHeaderField: "If-None-Match") == nil)

        let (same, script) = ScriptedURLProtocol.client([url: .http(status: 304)])
        #expect(try await source(same).fetch(SourceQuery(), since: memo) == .unchanged)
        #expect(script.requests.first?.value(forHTTPHeaderField: "If-None-Match") == #"W/"v1""#)
        #expect(source(same).listsEverything)
    }

    /// Lever writes "on-site" (its docs, 2026-10-23); a company on Lever's EU instance is asked
    /// there, and a pasted EU address says so.
    @Test func leverOnSiteAndTheEUInstance() async throws {
        let body = Data(
            #"[{"text":"Engineer","hostedUrl":"https://jobs.eu.lever.co/acmerobotics/1","createdAt":1791566108174,"categories":{"location":"Toronto"},"workplaceType":"on-site"}]"#
                .utf8)
        let (http, script) = ScriptedURLProtocol.client([leverEU: .http(status: 200, body: body)])
        let postings = try await LeverSource(id: sourceID, slug: "acmerobotics", region: "eu", http: http)
            .fetch(SourceQuery())
        #expect(postings.first?.workplace == .onsite)
        #expect(script.requests.first?.url?.absoluteString == leverEU)
        #expect(
            ATSDetector.detect("https://jobs.eu.lever.co/acmerobotics") == .detected(kind: .lever, slug: "acmerobotics")
        )
        #expect(ATSDetector.leverRegion("https://jobs.eu.lever.co/acmerobotics") == "eu")
        #expect(ATSDetector.leverRegion("https://jobs.lever.co/acmerobotics") == nil)
        let config = BoardConfig(slug: "acmerobotics", region: "eu")
        #expect(BoardConfig.decode(config.json) == config)
    }

    /// A search lists matches, not everything a company has open, and has no ETag to ask with.
    @Test func aSearchNeverClaimsToListEverything() async throws {
        let (http, _) = ScriptedURLProtocol.client([:])
        let adzuna = AdzunaSource(id: sourceID, credentials: .init(appID: "a", appKey: "k"), http: http)
        #expect(!adzuna.listsEverything)
    }
}
