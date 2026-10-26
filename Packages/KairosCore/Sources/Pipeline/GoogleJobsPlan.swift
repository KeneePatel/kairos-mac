import Foundation
import JobSources
import Store

/// Which Google Jobs searches a fetch makes (job collection v3, C3): every role phrase in every
/// place, plus remote in each country, the least recently searched first, as many as the plan's
/// share allows. On SerpApi's free plan (8 a day) each pair comes round about every five days.
public struct GoogleJobsPlan: Sendable {
    let db: Database

    public init(_ db: Database) { self.db = db }

    /// Every turn the settings call for, in a stable order.
    public static func turns(phrases: [String], places: [Place], countries: [Country]) -> [SearchTurn] {
        var turns: [SearchTurn] = []
        for phrase in phrases {
            for place in places { turns.append(SearchTurn(phrase: phrase, place: place, country: place.country)) }
            for country in countries {
                turns.append(SearchTurn(phrase: phrase, place: nil, country: country, remote: true))
            }
        }
        return turns
    }

    /// The `count` turns least recently searched for `source`: never searched first, then the
    /// oldest, ties in the plan's order.
    public func due(for source: SourceID, among turns: [SearchTurn], count: Int) async throws -> [SearchTurn] {
        guard count > 0, !turns.isEmpty else { return [] }
        var last: [String: Int64] = [:]
        for row in try await db.query(
            "SELECT key, last_at FROM search_turn WHERE source_id = ?", [.text(source.lowercased)])
        {
            if let key = row.string("key"), let at = row.int64("last_at") { last[key] = at }
        }
        return Array(
            turns.enumerated().sorted { a, b in
                let (la, lb) = (last[a.element.key] ?? -1, last[b.element.key] ?? -1)
                return la != lb ? la < lb : a.offset < b.offset
            }.prefix(count).map(\.element))
    }

    /// Remembers that `turns` were searched now.
    public func mark(_ turns: [SearchTurn], for source: SourceID, at: Date) async throws {
        for turn in turns {
            try await db.execute(
                """
                INSERT INTO search_turn (source_id, key, last_at) VALUES (?, ?, ?)
                ON CONFLICT (source_id, key) DO UPDATE SET last_at = excluded.last_at
                """, [.text(source.lowercased), .text(turn.key), SQLValue(at)])
        }
    }
}
