import Foundation
import Store

/// Where a posting is, as far as its location text and the board's hints say (SPEC §5.2, step 2).
public struct GeoResult: Equatable, Sendable {
    public var country: Country?
    /// Province or state code: "ON", "NY".
    public var region: String?
    public var city: String?
    public var remoteScope: RemoteScope
    /// Every place the posting names is outside Canada and the US, so the fetch drops it (SPEC §5.4).
    public var outsideCanadaAndUS: Bool

    public init(
        country: Country? = nil, region: String? = nil, city: String? = nil, remoteScope: RemoteScope = .unknown,
        outsideCanadaAndUS: Bool = false
    ) {
        self.country = country
        self.region = region
        self.city = city
        self.remoteScope = remoteScope
        self.outsideCanadaAndUS = outsideCanadaAndUS
    }
}

/// Parses free-text locations ("Toronto, ON (Hybrid)", "Remote (US only)", "London, UK") with the
/// place table in `places.json`. When signals disagree: an explicit country or province/state beats a
/// foreign place name, which beats a bare city name; a state code beats a state name ("Washington,
/// DC"); and "CA" means Canada only next to other Canadian signals, otherwise California.
public enum Geo {
    public static func parse(
        location: String, otherLocations: [String] = [], countryHint: String? = nil, workplace: Workplace? = nil
    ) -> GeoResult {
        var main = Reading(location, places: .shared)
        if main.country == nil && !main.anywhere, let hint = countryHint {
            switch Places.shared.country(named: hint) {
            case .some(let country): main.countries = [country]
            case .none where !key(hint).isEmpty: main.elsewhere = true
            case .none: break
            }
        }
        let others = otherLocations.map { Reading($0, places: .shared) }
        let all = [main] + others
        // Canada first: a posting that lists Toronto anywhere is a Canadian posting.
        let chosen =
            all.first { $0.country == .canada } ?? all.first { $0.country == .unitedStates } ?? main
        let outside = all.allSatisfy { $0.country == nil && !$0.anywhere } && all.contains { $0.elsewhere }

        let mode: Workplace? = chosen.mode ?? main.mode ?? workplace
        let scope: RemoteScope =
            switch mode {
            case .remote: chosen.remoteScope
            case .hybrid: .hybrid
            case .onsite: .onsite
            case nil where chosen.anywhere: chosen.remoteScope
            case nil: chosen.city != nil || chosen.region != nil ? .onsite : .unknown
            }
        return GeoResult(
            country: chosen.country, region: chosen.region?.code, city: chosen.city, remoteScope: scope,
            outsideCanadaAndUS: outside)
    }

    /// Lowercased, accents and dots dropped, whitespace collapsed: "Montréal" → "montreal", "B.C." → "bc".
    static func key(_ text: some StringProtocol) -> String {
        String(text).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en"))
            .lowercased()
            .filter { $0 != "." && $0 != "'" && $0 != "\u{2019}" }
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// One location string, read into the signals it contains.
struct Reading {
    var countries: [Country] = []
    var regionByCode: Region?
    var regionByName: Region?
    var cityMatch: Places.City?
    var unmatched: [String] = []
    var sawCA = false
    var elsewhere = false
    var anywhere = false
    var mode: Workplace?

    private static let separators: Set<Character> = [
        ",", ";", "/", "|", "(", ")", "[", "]", ":", "·", "•", "\u{2013}", "\u{2014}",
    ]
    private static let remotePhrases: [String] = [
        "remote first", "fully remote", "work from home", "work from anywhere", "home based", "home-based", "remote",
        "wfh", "telecommute", "telework", "virtual", "distributed",
    ]
    private static let onsitePhrases: [String] = [
        "on site", "on-site", "onsite", "in office", "in-office", "office based", "in person", "in-person",
    ]
    private static let modePhrases: [(Workplace, [String])] = {
        let remote: [(Workplace, String)] = remotePhrases.map { (Workplace.remote, $0) }
        let hybrid: [(Workplace, String)] = [(Workplace.hybrid, "hybrid")]
        let onsite: [(Workplace, String)] = onsitePhrases.map { (Workplace.onsite, $0) }
        return (remote + hybrid + onsite).map { ($0.0, $0.1.split(separator: " ").map(String.init)) }
    }()
    private static let anywherePhrases = ["anywhere", "worldwide", "global", "globally", "international"]
    private static let northAmericaPhrases = [["north", "america"], ["americas"]]
    private static let filler: Set<String> = [
        "in", "only", "based", "from", "the", "within", "of", "residents", "candidates", "eligible", "position", "role",
        "friendly", "ok", "possible", "option", "optional", "flexible", "or", "and", "&", "-", "*", "+", "time",
        "zones",
        "zone", "timezone", "timezones", "hq", "headquarters", "office", "offices", "location", "locations", "any",
    ]

    init(_ text: String, places: Places) {
        var normalized = String(text.map { Self.separators.contains($0) ? "," : $0 })
        for joiner in [" - ", " or ", " Or ", " & ", " and "] {
            normalized = normalized.replacing(joiner, with: ",")
        }
        for component in normalized.split(separator: ",") {
            read(component, places: places)
        }
        if sawCA {
            let canadian =
                countries.contains(.canada) || regionByCode?.country == .canada || regionByName?.country == .canada
                || cityMatch?.country == .canada
            if canadian {
                countries.append(.canada)
            } else if regionByCode == nil {
                regionByCode = Region(country: .unitedStates, code: "CA")
            }
        }
    }

    private mutating func read(_ component: Substring, places: Places) {
        var words = component.split(whereSeparator: \.isWhitespace).map(String.init)
        var keys = words.map { Geo.key($0) }
        func remove(_ phrase: [String]) -> Bool {
            guard phrase.count <= keys.count else { return false }
            for start in 0...(keys.count - phrase.count) where Array(keys[start..<start + phrase.count]) == phrase {
                keys.removeSubrange(start..<start + phrase.count)
                words.removeSubrange(start..<start + phrase.count)
                return true
            }
            return false
        }
        for (workplace, phrase) in Self.modePhrases where remove(phrase) {
            mode = mode ?? workplace
        }
        for phrase in Self.anywherePhrases where remove([phrase]) {
            anywhere = true
        }
        for phrase in Self.northAmericaPhrases where remove(phrase) {
            anywhere = true
            countries += [.canada, .unitedStates]
        }
        let kept = zip(words, keys).filter { !Self.filler.contains($0.1) }
        guard !kept.isEmpty else { return }
        match(original: kept.map(\.0), places: places)
    }

    /// Matches what's left of one component, trying a trailing code ("Toronto ON") when the whole doesn't match.
    private mutating func match(original words: [String], places: Places) {
        let text = words.joined(separator: " ")
        let key = Geo.key(text)
        if words.count == 1, matchCode(words[0], places: places) { return }
        if let country = places.countryNames[key] {
            countries.append(country)
        } else if let region = places.regionNames[key] {
            regionByName = regionByName ?? region
        } else if let city = places.cities[key] {
            cityMatch = cityMatch ?? city
        } else if places.elsewhere.contains(key) {
            elsewhere = true
            unmatched.append(text)  // still a city name if a province or state follows: "London, ON"
        } else if words.count >= 2, let last = words.last, matchCode(last, places: places) {
            match(original: Array(words.dropLast()), places: places)
        } else if words.count <= 4, text.contains(where: \.isLetter) {
            unmatched.append(text)
        }
    }

    /// Two capital letters, dots allowed: "ON", "B.C.", "U.S.". Lowercase "on" or "in" never counts.
    private mutating func matchCode(_ word: String, places: Places) -> Bool {
        let code = word.filter { $0 != "." }
        guard code.count == 2, code.allSatisfy({ $0.isUppercase && $0.isLetter }) else { return false }
        if code == "CA" {
            sawCA = true
        } else if code == "US" {
            countries.append(.unitedStates)
        } else if let region = places.regionCodes[code] {
            regionByCode = regionByCode ?? region
        } else {
            return false
        }
        return true
    }

    // MARK: - Resolved

    var region: Region? {
        let found = regionByCode ?? regionByName
        guard let found else {
            return cityMatch.flatMap { $0.country == country ? Region(country: $0.country, code: $0.region) : nil }
        }
        return found.country == country ? found : nil
    }

    var country: Country? {
        if !countries.isEmpty { return countries.contains(.canada) ? .canada : .unitedStates }
        if let found = regionByCode ?? regionByName { return found.country }
        if elsewhere { return nil }
        return cityMatch?.country
    }

    /// A known city keeps its name even when the text names another region ("Portland, ME").
    var city: String? {
        if let cityMatch, cityMatch.country == country { return cityMatch.name }
        return region != nil ? unmatched.first : nil
    }

    var remoteScope: RemoteScope {
        if Set(countries).count > 1 { return .remoteAnywhere }
        if country != nil { return .remoteCountry }
        return anywhere ? .remoteAnywhere : .remote
    }
}

struct Region: Equatable, Sendable {
    let country: Country
    let code: String
}

/// The place table, loaded once from `places.json`.
struct Places: Sendable {
    struct City: Equatable, Sendable {
        let name: String
        let country: Country
        let region: String
    }

    var regionCodes: [String: Region] = [:]
    var regionNames: [String: Region] = [:]
    var cities: [String: City] = [:]
    var elsewhere: Set<String> = []
    let countryNames: [String: Country] = [
        "canada": .canada, "united states": .unitedStates, "united states of america": .unitedStates,
        "usa": .unitedStates, "us": .unitedStates,
    ]

    static let shared = Places.load()

    /// A board's country field: a code ("CA") or a name ("Canada"). Here "CA" is Canada, because these
    /// fields hold countries, not states.
    func country(named hint: String) -> Country? {
        let key = Geo.key(hint)
        return key == "ca" ? .canada : countryNames[key]
    }

    private struct File: Decodable {
        let regions: [String: [String: [String]]]
        let cities: [String: [String: String]]
        let elsewhere: [String]
    }

    static func load() -> Places {
        var places = Places()
        guard let url = Bundle.module.url(forResource: "places", withExtension: "json"),
            let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data)
        else { return places }
        for (countryCode, regions) in file.regions {
            guard let country = Country(rawValue: countryCode) else { continue }
            for (code, names) in regions {
                let region = Region(country: country, code: code)
                places.regionCodes[code] = places.regionCodes[code] ?? region
                for name in names { places.regionNames[Geo.key(name)] = region }
            }
        }
        // "CA" is both Canada and California; Reading decides which from context.
        places.regionCodes["CA"] = nil
        for (countryCode, cities) in file.cities {
            guard let country = Country(rawValue: countryCode) else { continue }
            for (name, region) in cities {
                places.cities[Geo.key(name)] = City(name: name, country: country, region: region)
            }
        }
        places.elsewhere = Set(file.elsewhere.map { Geo.key($0) })
        return places
    }
}
