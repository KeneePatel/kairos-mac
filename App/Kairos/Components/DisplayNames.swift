import JobSources
import Store

extension SourceKind {
    var displayName: String {
        switch self {
        case .greenhouse: "Greenhouse"
        case .lever: "Lever"
        case .ashby: "Ashby"
        case .adzuna: "Adzuna"
        case .linkedIn: "LinkedIn"
        case .indeedCanada: "Indeed Canada"
        case .indeedUS: "Indeed US"
        case .glassdoor: "Glassdoor"
        case .googleJobs: "Google Jobs"
        case .wellfound: "Wellfound"
        case .jobBank: "Job Bank"
        }
    }
}

extension Source {
    /// The name you gave the company, else its board slug.
    var displayName: String {
        BoardConfig.decode(config).map { $0.company ?? $0.slug } ?? kind.displayName
    }
}

extension Country {
    var shortName: String {
        switch self {
        case .canada: "Canada"
        case .unitedStates: "US"
        }
    }
}

extension Job {
    /// "Toronto, ON", else whatever is most specific.
    var placeLabel: String {
        switch (city, region) {
        case (let city?, let region?): "\(city), \(region)"
        case (let city?, nil): city
        case (nil, let region?): region
        case (nil, nil): country?.shortName ?? (location.isEmpty ? "—" : location)
        }
    }

    var workLabel: String {
        switch remoteScope {
        case .onsite: "On-site"
        case .hybrid: "Hybrid"
        case .remote: "Remote"
        case .remoteCountry: country.map { "Remote · \($0.shortName)" } ?? "Remote"
        case .remoteAnywhere: "Remote · across countries"
        case .unknown: "—"
        }
    }
}
