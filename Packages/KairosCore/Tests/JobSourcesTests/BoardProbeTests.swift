import Foundation
import Store
import TestSupport
import Testing

@testable import JobSources

/// Job collection v2, J6: looking for a company's public board by its name.
@Suite("Board probe")
struct BoardProbeTests {
    /// A name's likely slugs, without company suffixes.
    @Test func slugsFromANameDropTheSuffixes() {
        #expect(BoardProbe.slugs(for: "Traction Rec Inc.") == ["tractionrec", "traction-rec"])
        #expect(BoardProbe.slugs(for: "Syndio") == ["syndio"])
        #expect(BoardProbe.slugs(for: "Geotab Canada Ltd") == ["geotab"])
        #expect(BoardProbe.slugs(for: "Rêve Technologies") == ["reve"])
        #expect(BoardProbe.slugs(for: "Inc.") == ["inc"])
        #expect(BoardProbe.slugs(for: "!!!").isEmpty)
    }

    /// Boards are tried in order; an empty board isn't a find (it can mean "not a customer").
    @Test func theFirstBoardWithJobsIsTheFind() async {
        let (http, script) = ScriptedURLProtocol.client([
            "https://boards-api.greenhouse.io/v1/boards/syndio/jobs": .http(status: 404),
            "https://api.lever.co/v0/postings/syndio?mode=json&limit=1": .http(status: 200, body: Data("[]".utf8)),
            "https://api.ashbyhq.com/posting-api/job-board/syndio": .http(
                status: 200, body: Data(#"{"jobs":[{"title":"Software Engineer"}]}"#.utf8)),
        ])
        let found = await BoardProbe(http: http).find("Syndio")
        #expect(found?.kind == .ashby && found?.slug == "syndio")
        #expect(script.requests.count == 3)
    }

    /// SmartRecruiters answers 200 with nothing for any name, so only a count above zero counts;
    /// its ids are tried as written and capitalised.
    @Test func smartRecruitersNeedsAJob() async {
        let (http, _) = ScriptedURLProtocol.client([
            "https://api.smartrecruiters.com/v1/companies/maplepay/postings?limit=1": .http(
                status: 200, body: Data(#"{"totalFound":0,"content":[]}"#.utf8)),
            "https://api.smartrecruiters.com/v1/companies/Maplepay/postings?limit=1": .http(
                status: 200, body: Data(#"{"totalFound":3,"content":[{}]}"#.utf8)),
        ])
        let found = await BoardProbe(http: http).find("MaplePay")
        #expect(found?.kind == .smartRecruiters && found?.slug == "Maplepay")
        let (nothing, _) = ScriptedURLProtocol.client([:])
        #expect(await BoardProbe(http: nothing).find("Nobody Anywhere") == nil)
    }
}
