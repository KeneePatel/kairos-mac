import Foundation
import Store

/// Staffing agencies, recruiters and contractor marketplaces (job collection v3, C3): their
/// postings repeat employers' jobs or hide the employer, so the prefilter leaves them out unless
/// Settings, Search says otherwise. Named ones first, then names that say what they are, then
/// postings written for "our client".
public enum Agencies {
    /// Folded names, matched as whole words inside the company's name.
    static let names: [String] = [
        "randstad", "procom", "hays", "robert half", "teksystems", "insight global", "kforce", "akkodis", "modis",
        "experis", "manpower", "manpowergroup", "altis", "s i systems", "si systems", "ignite technical",
        "cleo consulting",
        "maarut", "innosystech", "vtech solution", "zortech", "teckhorizon", "softline technology", "upstaff",
        "jobgether",
        "lensa", "jobot", "apex systems", "aerotek", "adecco", "kelly services", "motion recruitment", "cybercoders",
        "tekwissen", "turing", "toptal", "crossover", "revature", "bairesdev", "andela", "braintrust", "x team",
        "lemon io", "analyst technical solutions", "miratech", "burgeon it services", "quarry consulting",
        "testingxperts",
        "talentburst", "collabera", "diverse lynx", "eteam", "mastech", "artech", "ampcus", "compunnel", "agilus",
        "bevertec", "brainhunter", "david aplin", "tundra technical", "hirequest", "sapphire digital",
        "stratford group",
    ]

    /// Words in a company's name that say what it does.
    static let pattern = try? NSRegularExpression(
        pattern:
            #"\b(staffing|recruit(ing|ment|ers?)?|agenc(y|ies)|headhunt\w*|placements?|workforce|manpower|resourcing|talent (partners|solutions|acquisition|group|network))\b"#,
        options: [.caseInsensitive])

    /// Phrases a posting uses when the employer is someone else.
    static let clientPhrases = [
        "our client", "our clients", "on behalf of a client", "for a client of ours", "client site",
    ]

    /// Whether `company` is an agency by name, or `text` is written for a client.
    public static func isAgency(company: String, text: String?) -> Bool {
        let folded = TextScan.fold(company)
        let words = TextScan.words(folded)
        for name in names {
            let needle = TextScan.words(name)
            guard !needle.isEmpty, needle.count <= words.count else { continue }
            if (0...(words.count - needle.count)).contains(where: { Array(words[$0..<($0 + needle.count)]) == needle })
            {
                return true
            }
        }
        if pattern?.firstMatch(in: company, range: NSRange(company.startIndex..., in: company)) != nil { return true }
        guard let text else { return false }
        let lowered = text.lowercased()
        return clientPhrases.contains { lowered.contains($0) }
    }
}
