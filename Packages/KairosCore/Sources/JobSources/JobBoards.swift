import Foundation

/// Job boards and aggregators: sites that carry other employers' postings (job collection v3,
/// C1). A posting found on one is real, but the employer's own page is the better link to open,
/// and a job board is never a company to watch.
public enum JobBoards {
    /// Hosts, matched as themselves or as a parent domain ("ca.indeed.com" is "indeed.com").
    static let hosts: [String] = [
        "indeed.com", "linkedin.com", "glassdoor.com", "glassdoor.ca", "ziprecruiter.com", "jooble.org", "talent.com",
        "simplyhired.com", "simplyhired.ca", "workopolis.com", "eluta.ca", "jobrapido.com", "bebee.com", "trabajo.org",
        "jobleads.com", "theladders.com", "startup.jobs", "csjobs.ca", "careerbeacon.com", "jobgether.com",
        "remote.com", "remoterocketship.com", "matcha.fm", "flexjobs.com", "lensa.com", "jobot.com", "monster.com",
        "monster.ca", "careerbuilder.com", "dice.com", "neuvoo.com", "jobillico.com", "adzuna.com", "adzuna.ca",
        "google.com", "jobmesh.io", "careers-page.com", "expertini.com", "jobs.ca", "hirify.me", "up2staff.com",
        "unjobs.ru", "remotesource.com", "hireft.com", "onetapapply.com", "remotejobify.app", "katchup.world",
        "remotepilot.dev", "entracareers.com", "recroid.com", "parsejobs.com", "workreap.com", "allibo.com",
        "wellfound.com", "himalayas.app", "remotive.com", "jobbank.gc.ca", "kijiji.ca", "jobspresso.co",
        "weworkremotely.com", "remoteok.com", "builtin.com", "builtincanada.com", "ycombinator.com", "otta.com",
    ]

    public static func isJobBoard(_ url: URL) -> Bool { url.host().map(isJobBoard) ?? false }

    public static func isJobBoard(_ host: String) -> Bool {
        let host = host.lowercased()
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The link without the `utm_*` and `ref` parameters a search adds.
    public static func stripped(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let items = components.queryItems
        else { return url }
        let kept = items.filter { !$0.name.lowercased().hasPrefix("utm_") && $0.name.lowercased() != "ref" }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.url ?? url
    }

    /// Words that don't tell companies apart.
    private static let filler: Set<String> = [
        "the", "inc", "ltd", "llc", "corp", "co", "company", "careers", "jobs", "canada", "group", "technologies",
        "technology", "solutions", "services", "limited", "corporation", "and", "of", "at",
    ]

    /// Whether an apply option's title names the company ("Scotiabank"; "Softline" for "Softline
    /// Technology"; "Intuit Careers" for "Intuit") or the site the posting came from. An option
    /// that names neither can belong to another posting: Google lists some by mistake.
    public static func names(_ title: String, company: String, via: String?) -> Bool {
        if let via, !via.isEmpty, fold(via) == fold(title) { return true }
        let titleWords = Set(words(title))
        let companyWords = Set(words(company))
        return !titleWords.isEmpty && !companyWords.isEmpty && !titleWords.isDisjoint(with: companyWords)
    }

    private static func fold(_ text: String) -> String {
        text.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "en"))
            .filter { $0.isLetter || $0.isNumber || $0 == " " }.trimmingCharacters(in: .whitespaces)
    }

    private static func words(_ text: String) -> [String] {
        fold(text).split(separator: " ").map(String.init).filter { !filler.contains($0) }
    }
}
