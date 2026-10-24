import Foundation
import Store

/// Looks for a company's public job board by its name (job collection v2, J6): a search's company
/// ("Syndio") may have its jobs, in full, on a board Kairos can read. It tries the name's likely
/// slugs on the boards whose lists are cheap and whose empty answers can be told from "not a
/// customer": a board counts as found only when it lists at least one job.
public struct BoardProbe: Sendable {
    let http: any HTTPClient

    public init(http: any HTTPClient) {
        self.http = http
    }

    /// The likely slugs for a company name: "Traction Rec Inc." → "tractionrec", "traction-rec".
    public static func slugs(for name: String) -> [String] {
        let suffixes: Set<String> = [
            "inc", "incorporated", "ltd", "limited", "llc", "corp", "corporation", "co", "company", "technologies",
            "technology", "solutions", "group", "canada", "the",
        ]
        let words = name.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "en"))
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let core = words.filter { !suffixes.contains($0) }
        let kept = core.isEmpty ? words : core
        return [kept.joined(), kept.joined(separator: "-")].reduce(into: []) { slugs, slug in
            if !slug.isEmpty, BoardSlug.isValid(slug), !slugs.contains(slug) { slugs.append(slug) }
        }
    }

    /// The first board that lists jobs under one of the name's slugs, or nil.
    public func find(_ name: String) async -> (kind: SourceKind, slug: String)? {
        for slug in Self.slugs(for: name) {
            for kind in [SourceKind.greenhouse, .lever, .ashby, .workable, .recruitee, .smartRecruiters] {
                let tries = kind == .smartRecruiters ? [slug, slug.prefix(1).uppercased() + slug.dropFirst()] : [slug]
                for attempt in tries where await lists(kind, attempt) { return (kind, attempt) }
            }
        }
        return nil
    }

    /// Whether that board answers with at least one job.
    func lists(_ kind: SourceKind, _ slug: String) async -> Bool {
        let address: String
        switch kind {
        case .greenhouse: address = "https://boards-api.greenhouse.io/v1/boards/\(slug)/jobs"
        case .lever: address = "https://api.lever.co/v0/postings/\(slug)?mode=json&limit=1"
        case .ashby: address = "https://api.ashbyhq.com/posting-api/job-board/\(slug)"
        case .workable: address = "https://apply.workable.com/api/v1/widget/accounts/\(slug)"
        case .recruitee: address = "https://\(slug).recruitee.com/api/offers/"
        case .smartRecruiters: address = "https://api.smartrecruiters.com/v1/companies/\(slug)/postings?limit=1"
        default: return false
        }
        guard let url = URL(string: address),
            let (data, response) = try? await http.data(for: URLRequest(url: url)), response.statusCode == 200,
            response.url?.host() == url.host(),
            let value = try? JSONSerialization.jsonObject(with: data)
        else { return false }
        if let list = value as? [Any] { return !list.isEmpty }
        guard let object = value as? [String: Any] else { return false }
        if let total = object["totalFound"] as? Int { return total > 0 }
        for key in ["jobs", "offers"] {
            if let list = object[key] as? [Any] { return !list.isEmpty }
        }
        return false
    }
}
