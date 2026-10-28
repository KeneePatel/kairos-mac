import Foundation
import Jobs
import KairosKit
import Store

/// A fixed "now" for store tests: 2026-10-25 12:00 UTC.
let now = Date(timeIntervalSince1970: 1_792_929_600)

func day(_ offset: Double) -> Date { now.addingTimeInterval(.days(offset)) }

func emptyStore() async throws -> KairosStore {
    try await KairosStore.inMemory()
}

/// A listing as a board would give it, normalized.
func listing(
    _ path: String, host: String = "job-boards.greenhouse.io", company: String = "Acme",
    title: String = "Software Engineer",
    city: String? = "Toronto", description: String = "Build services in Swift and Go.", postedAt: Date? = nil,
    textOmitted: Bool = false, isSnippet: Bool = false
) -> Listing {
    let url = "https://\(host)/\(path)"
    return Listing(
        canonicalURL: url, url: url, company: company, title: title, location: city.map { "\($0), ON" } ?? "Remote",
        city: city, region: city == nil ? nil : "ON", country: .canada,
        remoteScope: city == nil ? .remoteCountry : .onsite,
        postedAt: postedAt, description: description, textOmitted: textOmitted, isSnippet: isSnippet)
}

extension KairosStore {
    func board(_ slug: String, _ kind: SourceKind = .greenhouse) async throws -> Source {
        if let source = try await sources.board(kind: kind, slug: slug) { return source }
        return try await sources.addByYou(Board(kind: kind, slug: slug, name: slug.capitalized), at: now)
    }

    func count(_ table: String) async throws -> Int {
        try await db.first("SELECT count(*) AS n FROM \(table)")?.int("n") ?? 0
    }
}
