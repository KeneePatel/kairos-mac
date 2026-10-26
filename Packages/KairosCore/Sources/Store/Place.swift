import Foundation

/// A city Kairos searches in (job collection v3, C3): Google Jobs works best city by city, so
/// your places drive its searches. Board jobs anywhere in your countries still count.
public struct Place: Codable, Equatable, Hashable, Sendable {
    public var city: String
    /// The province or state, spelled out: "Ontario", "British Columbia", "California".
    public var region: String
    public var country: Country

    public init(city: String, region: String, country: Country) {
        self.city = city
        self.region = region
        self.country = country
    }

    /// "Toronto, Ontario".
    public var displayName: String { "\(city), \(region)" }

    /// What SerpApi's `location` takes: "Toronto, Ontario, Canada".
    public var googleLocation: String { "\(city), \(region), \(country.googleName)" }

    /// One key per place, whatever the case.
    public var key: String { "\(city)|\(region)|\(country.rawValue)".lowercased() }

    /// The usual cities for a country: Canada's seven (the owner's choice, 2026-10-26) or five US
    /// hubs, for anyone who hasn't set their own.
    public static func defaults(for country: Country) -> [Place] {
        switch country {
        case .canada:
            [
                ("Toronto", "Ontario"), ("Vancouver", "British Columbia"), ("Montreal", "Quebec"),
                ("Ottawa", "Ontario"), ("Calgary", "Alberta"), ("Waterloo", "Ontario"), ("Halifax", "Nova Scotia"),
            ].map { Place(city: $0.0, region: $0.1, country: .canada) }
        case .unitedStates:
            [
                ("New York", "New York"), ("San Francisco", "California"), ("Seattle", "Washington"),
                ("Austin", "Texas"), ("Boston", "Massachusetts"),
            ].map { Place(city: $0.0, region: $0.1, country: .unitedStates) }
        }
    }

    /// "Halifax, Nova Scotia" or "Halifax, NS" → the place, with its country from the region.
    /// Nil when the region isn't a province, territory or state.
    public static func parse(_ text: String) -> Place? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, !parts[0].isEmpty else { return nil }
        let given = parts[1].lowercased()
        for country in Country.allCases {
            for (name, code) in regions(of: country) where name.lowercased() == given || code.lowercased() == given {
                return Place(city: parts[0], region: name, country: country)
            }
        }
        return nil
    }

    /// A country's provinces and territories, or states, with their codes.
    public static func regions(of country: Country) -> [(name: String, code: String)] {
        switch country {
        case .canada: provinces
        case .unitedStates: states
        }
    }

    private static let provinces: [(name: String, code: String)] = [
        ("Alberta", "AB"), ("British Columbia", "BC"), ("Manitoba", "MB"), ("New Brunswick", "NB"),
        ("Newfoundland and Labrador", "NL"), ("Nova Scotia", "NS"), ("Northwest Territories", "NT"), ("Nunavut", "NU"),
        ("Ontario", "ON"), ("Prince Edward Island", "PE"), ("Quebec", "QC"), ("Saskatchewan", "SK"), ("Yukon", "YT"),
    ]

    private static let states: [(name: String, code: String)] = [
        ("Alabama", "AL"), ("Alaska", "AK"), ("Arizona", "AZ"), ("Arkansas", "AR"), ("California", "CA"),
        ("Colorado", "CO"), ("Connecticut", "CT"), ("Delaware", "DE"), ("District of Columbia", "DC"),
        ("Florida", "FL"), ("Georgia", "GA"), ("Hawaii", "HI"), ("Idaho", "ID"), ("Illinois", "IL"), ("Indiana", "IN"),
        ("Iowa", "IA"), ("Kansas", "KS"), ("Kentucky", "KY"), ("Louisiana", "LA"), ("Maine", "ME"), ("Maryland", "MD"),
        ("Massachusetts", "MA"), ("Michigan", "MI"), ("Minnesota", "MN"), ("Mississippi", "MS"), ("Missouri", "MO"),
        ("Montana", "MT"), ("Nebraska", "NE"), ("Nevada", "NV"), ("New Hampshire", "NH"), ("New Jersey", "NJ"),
        ("New Mexico", "NM"), ("New York", "NY"), ("North Carolina", "NC"), ("North Dakota", "ND"), ("Ohio", "OH"),
        ("Oklahoma", "OK"), ("Oregon", "OR"), ("Pennsylvania", "PA"), ("Rhode Island", "RI"), ("South Carolina", "SC"),
        ("South Dakota", "SD"), ("Tennessee", "TN"), ("Texas", "TX"), ("Utah", "UT"), ("Vermont", "VT"),
        ("Virginia", "VA"), ("Washington", "WA"), ("West Virginia", "WV"), ("Wisconsin", "WI"), ("Wyoming", "WY"),
    ]
}

extension Country {
    /// The country as Google's location strings name it.
    public var googleName: String { self == .canada ? "Canada" : "United States" }
}
