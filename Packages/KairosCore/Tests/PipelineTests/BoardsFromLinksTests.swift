import Foundation
import JobSources
import Store
import Testing

@testable import Pipeline

private let sourceID = UUID(uuidString: "0199f0a0-0000-7000-8000-0000000000aa")!

private func posting(_ company: String, url: String, apply: String? = nil, links: [String] = []) -> Posting {
    Posting(
        sourceID: sourceID, url: URL(string: url)!, company: company, title: "Backend Developer",
        location: "Toronto, ON",
        postedAt: nil, descriptionHTML: "<p>Go.</p>", applyURL: apply.flatMap(URL.init(string:)),
        links: links.compactMap(URL.init(string:)))
}

/// Boards Kairos reads, behind a search's links (job collection v3, C1).
@Suite("Boards from links")
struct BoardsFromLinksTests {
    @Test func boardsAreFoundBehindAddressesApplyLinksAndOptions() {
        let found = BoardsFromLinks.boards(in: [
            posting(
                "Acme Robotics", url: "https://ca.indeed.com/viewjob?jk=1",
                apply: "https://boards.greenhouse.io/acme/jobs/1"),
            posting(
                "Maplepay", url: "https://jobs.lever.co/maplepay/0f3a?lever-source=Google",
                links: ["https://ca.linkedin.com/jobs/view/1", "https://jobs.ashbyhq.com/maplepay/9c1e"]),
            posting("Nordic Bank", url: "https://jobs.eu.lever.co/nordic/aa11"),
            // A second posting at a board already found adds nothing; an aggregator's never counts.
            posting("Acme Robotics", url: "https://boards.greenhouse.io/acme/jobs/2"),
            posting(
                "Jobgether", url: "https://jobgether.com/offer/1", apply: "https://boards.greenhouse.io/stripe/jobs/1"),
            // A company page that embeds its board isn't a board address.
            posting("IXL", url: "https://www.ixl.com/company/jobs?gh_jid=8338231002"),
        ])
        #expect(
            found.map { "\($0.kind.rawValue):\($0.slug):\($0.company):\($0.region ?? "-")" } == [
                "greenhouse:acme:Acme Robotics:-", "lever:maplepay:Maplepay:-", "ashby:maplepay:Maplepay:-",
                "lever:nordic:Nordic Bank:eu",
            ])
    }

    @Test func foundBoardsBecomeSourcesOnceAndRemovedOnesStayRemoved() async throws {
        let db = try Database(path: ":memory:")
        try await Migrator.migrate(db, with: Migrator.bundled())
        let sources = SourceRepository(db)
        let gone = try await sources.add(kind: .lever, config: BoardConfig(slug: "maplepay", origin: "catalog").json)
        _ = try await sources.tombstone(gone.id)
        let found = BoardsFromLinks.boards(in: [
            posting("Acme Robotics", url: "https://boards.greenhouse.io/acme/jobs/1"),
            posting("Maplepay", url: "https://jobs.lever.co/maplepay/0f3a"),
        ])
        let added = try await BoardsFromLinks.add(found, via: .googleJobs, to: db)
        #expect(added.count == 1 && added.first?.kind == .greenhouse)
        let config = try #require(added.first.flatMap { BoardConfig.decode($0.config) })
        #expect(config.slug == "acme" && config.company == "Acme Robotics" && config.origin == "google_jobs")
        // Again: nothing new.
        #expect(try await BoardsFromLinks.add(found, via: .googleJobs, to: db).isEmpty)
        #expect(try await sources.sources().map(\.kind) == [.greenhouse])
    }
}
