import Foundation
import Testing

@testable import Jobs

struct GeoCase: Sendable, CustomTestStringConvertible {
    let text: String
    var others: [String] = []
    var hint: String? = nil
    var workplace: Workplace? = nil
    let expected: GeoResult

    var testDescription: String {
        ([text] + others).joined(separator: " + ") + (hint.map { " [hint \($0)]" } ?? "")
            + (workplace.map { " [\($0)]" } ?? "")
    }
}

private func ca(_ region: String?, _ city: String?, _ scope: RemoteScope) -> GeoResult {
    GeoResult(country: .canada, region: region, city: city, remoteScope: scope)
}

private func us(_ region: String?, _ city: String?, _ scope: RemoteScope) -> GeoResult {
    GeoResult(country: .unitedStates, region: region, city: city, remoteScope: scope)
}

private func outside(_ scope: RemoteScope = .unknown) -> GeoResult {
    GeoResult(remoteScope: scope, outsideCanadaAndUS: true)
}

private func nowhere(_ scope: RemoteScope) -> GeoResult { GeoResult(remoteScope: scope) }

/// The place table of the first Kairos, kept whole: each line is a decision made on real postings.
@Suite("Geography")
struct GeoTests {
    static let cases: [GeoCase] = [
        // Canadian cities, provinces and their spellings
        GeoCase(text: "Toronto, ON", expected: ca("ON", "Toronto", .onsite)),
        GeoCase(text: "Toronto, Ontario, Canada", expected: ca("ON", "Toronto", .onsite)),
        GeoCase(text: "Toronto ON", expected: ca("ON", "Toronto", .onsite)),
        GeoCase(text: "Toronto, Canada", expected: ca("ON", "Toronto", .onsite)),
        GeoCase(text: "Toronto, ON, CA", expected: ca("ON", "Toronto", .onsite)),
        GeoCase(text: "Vancouver, BC", expected: ca("BC", "Vancouver", .onsite)),
        GeoCase(text: "Vancouver, B.C.", expected: ca("BC", "Vancouver", .onsite)),
        GeoCase(text: "Vancouver, CA", expected: ca("BC", "Vancouver", .onsite)),
        GeoCase(text: "Montréal, QC", expected: ca("QC", "Montréal", .onsite)),
        GeoCase(text: "Montreal, Quebec, Canada", expected: ca("QC", "Montréal", .onsite)),
        GeoCase(text: "Calgary, AB", expected: ca("AB", "Calgary", .onsite)),
        GeoCase(text: "Ottawa", expected: ca("ON", "Ottawa", .onsite)),
        GeoCase(text: "Kitchener, ON", expected: ca("ON", "Kitchener", .onsite)),
        GeoCase(text: "Oshawa, ON", expected: ca("ON", "Oshawa", .onsite)),
        GeoCase(text: "Halifax, Nova Scotia", expected: ca("NS", "Halifax", .onsite)),
        GeoCase(text: "Charlottetown, PEI", expected: ca("PE", "Charlottetown", .onsite)),
        GeoCase(text: "London, ON", expected: ca("ON", "London", .onsite)),
        GeoCase(text: "Victoria, BC", expected: ca("BC", "Victoria", .onsite)),
        GeoCase(text: "Ottawa, ON / Montréal, QC", expected: ca("ON", "Ottawa", .onsite)),
        // Work arrangement words
        GeoCase(text: "Toronto, ON (Hybrid)", expected: ca("ON", "Toronto", .hybrid)),
        GeoCase(text: "Hybrid - Vancouver, BC", expected: ca("BC", "Vancouver", .hybrid)),
        GeoCase(text: "Mississauga, Ontario (Hybrid)", expected: ca("ON", "Mississauga", .hybrid)),
        GeoCase(text: "Toronto (On-site)", expected: ca("ON", "Toronto", .onsite)),
        GeoCase(text: "In-office - Calgary", expected: ca("AB", "Calgary", .onsite)),
        GeoCase(text: "Remote - Toronto", expected: ca("ON", "Toronto", .remoteCountry)),
        // Remote, Canada
        GeoCase(text: "Remote - Canada", expected: ca(nil, nil, .remoteCountry)),
        GeoCase(text: "Remote \u{2013} Canada", expected: ca(nil, nil, .remoteCountry)),
        GeoCase(text: "Remote (Canada)", expected: ca(nil, nil, .remoteCountry)),
        GeoCase(text: "Canada (Remote)", expected: ca(nil, nil, .remoteCountry)),
        GeoCase(text: "Remote in Canada", expected: ca(nil, nil, .remoteCountry)),
        GeoCase(text: "Remote, Canada residents only", expected: ca(nil, nil, .remoteCountry)),
        GeoCase(text: "Canada", expected: ca(nil, nil, .unknown)),
        // United States
        GeoCase(text: "New York, NY", expected: us("NY", "New York", .onsite)),
        GeoCase(text: "NYC", expected: us("NY", "NYC", .onsite)),
        GeoCase(text: "Brooklyn, New York", expected: us("NY", "Brooklyn", .onsite)),
        GeoCase(text: "San Francisco, CA", expected: us("CA", "San Francisco", .onsite)),
        GeoCase(text: "San Francisco Bay Area", expected: us("CA", "San Francisco Bay Area", .onsite)),
        GeoCase(text: "Seattle, Washington", expected: us("WA", "Seattle", .onsite)),
        GeoCase(text: "Austin, Texas", expected: us("TX", "Austin", .onsite)),
        GeoCase(text: "Atlanta, GA", expected: us("GA", "Atlanta", .onsite)),
        GeoCase(text: "Washington, D.C.", expected: us("DC", nil, .onsite)),
        GeoCase(text: "Portland, ME", expected: us("ME", "Portland", .onsite)),
        GeoCase(text: "Indiana", expected: us("IN", nil, .onsite)),
        // Remote, United States ("CA" alone is California)
        GeoCase(text: "Remote (US only)", expected: us(nil, nil, .remoteCountry)),
        GeoCase(text: "US Remote", expected: us(nil, nil, .remoteCountry)),
        GeoCase(text: "Remote, USA", expected: us(nil, nil, .remoteCountry)),
        GeoCase(text: "Remote, CA", expected: us("CA", nil, .remoteCountry)),
        GeoCase(text: "Bay Area or Remote (US)", expected: us("CA", "Bay Area", .remoteCountry)),
        GeoCase(text: "United States", expected: us(nil, nil, .unknown)),
        // Across countries
        GeoCase(text: "Remote - North America", expected: ca(nil, nil, .remoteAnywhere)),
        GeoCase(text: "Remote (US or Canada)", expected: ca(nil, nil, .remoteAnywhere)),
        GeoCase(text: "Remote US & Canada", expected: ca(nil, nil, .remoteAnywhere)),
        GeoCase(text: "Remote - Anywhere", expected: nowhere(.remoteAnywhere)),
        GeoCase(text: "Worldwide", expected: nowhere(.remoteAnywhere)),
        GeoCase(text: "Remote", expected: nowhere(.remote)),
        GeoCase(text: "Remote (EST)", expected: nowhere(.remote)),
        GeoCase(text: "", expected: nowhere(.unknown)),
        GeoCase(text: "Multiple Locations", expected: nowhere(.unknown)),
        // Outside Canada and the US
        GeoCase(text: "London", expected: outside()),
        GeoCase(text: "London, United Kingdom", expected: outside()),
        GeoCase(text: "Victoria, Australia", expected: outside()),
        GeoCase(text: "San Jose, Costa Rica", expected: outside()),
        GeoCase(text: "Berlin, Germany", expected: outside()),
        GeoCase(text: "Bengaluru, India", expected: outside()),
        GeoCase(text: "EMEA", expected: outside()),
        // Board hints and further locations
        GeoCase(text: "Remote", hint: "CA", expected: ca(nil, nil, .remoteCountry)),
        GeoCase(text: "Toronto", workplace: .remote, expected: ca("ON", "Toronto", .remoteCountry)),
        GeoCase(text: "Mexico City", hint: "MX", expected: outside()),
        GeoCase(text: "Remote", hint: "GB", expected: outside(.remote)),
        GeoCase(text: "North America", workplace: .remote, expected: ca(nil, nil, .remoteAnywhere)),
        GeoCase(text: "New York, NY", others: ["Toronto, ON"], expected: ca("ON", "Toronto", .onsite)),
        GeoCase(
            text: "Toronto, ON", others: ["Remote (Canada)", "Remote (US)"], hint: "Canada", workplace: .hybrid,
            expected: ca("ON", "Toronto", .hybrid)),
        GeoCase(text: "London, UK", others: ["Remote (Canada)"], expected: ca(nil, nil, .remoteCountry)),
        GeoCase(text: "Paris, France", others: ["Berlin, Germany"], expected: outside()),
    ]

    @Test(arguments: cases)
    func parses(_ geoCase: GeoCase) {
        let result = Geo.parse(
            location: geoCase.text, otherLocations: geoCase.others, countryHint: geoCase.hint,
            workplace: geoCase.workplace)
        #expect(result == geoCase.expected)
    }

    @Test func thePlaceTableLoads() {
        #expect(Places.shared.cities.count > 100 && Places.shared.regionCodes.count > 60)
        #expect(Places.shared.regionCodes["CA"] == nil)  // decided by context, never by lookup
    }

    @Test func placesParseAndKey() {
        #expect(Place.parse("Halifax, NS") == Place(city: "Halifax", region: "Nova Scotia", country: .canada))
        #expect(Place.parse("Austin, Texas")?.country == .unitedStates)
        #expect(Place.parse("Somewhere") == nil && Place.parse("Paris, Île-de-France") == nil)
        #expect(Place.defaults(for: .canada).count == 7)
        #expect(Place(city: "Toronto", region: "Ontario", country: .canada).googleLocation == "Toronto, Ontario, Canada")
    }
}

@Suite("Roles")
struct RoleTests {
    @Test(arguments: [
        ("Senior Software Engineer", true), ("Full-Stack Developer", true), ("SDE II", true),
        ("Business Development Representative", false), ("Developer Advocate", false),
        ("Real Estate Developer", false), ("Site Reliability Engineer", false), ("Sr. Backend Dev", true),
    ])
    func softwareMatchesWholeWords(title: String, expected: Bool) {
        #expect(RoleMatcher(families: [.software]).matches(title) == expected)
    }

    @Test func eachFamilyHasItsOwnTitlesAndLookalikes() {
        let all = RoleMatcher(families: Set(RoleFamily.allCases))
        #expect(all.matches("SRE, Platform") && all.matches("MLOps Engineer") && all.matches("SDET"))
        #expect(!all.matches("QA Technician, Food Safety") && !all.matches("Payroll Specialist"))
        #expect(RoleMatcher(families: [.qa]).matches("Quality Assurance Analyst"))
    }

    @Test func yourOwnPhrasesCountTooAndNothingSetKeepsAll() {
        let custom = RoleMatcher(families: [], extra: ["solutions engineer", "  "])
        #expect(custom.extra == ["solutions engineer"])
        #expect(custom.matches("Senior Solutions Engineer") && !custom.matches("Software Engineer"))
        #expect(RoleMatcher(families: []).matches("Anything at all"))
    }

    @Test func searchesAreOrderedWithoutRepeats() {
        let matcher = RoleMatcher(families: [.qa, .software], extra: ["QA Engineer"])
        #expect(matcher.searches.first == "software engineer")
        #expect(matcher.searches.filter { $0 == "qa engineer" }.count == 1)
        #expect(matcher.googlePhrases == ["software developer", "software engineer", "qa engineer"])
    }
}
