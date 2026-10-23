import JobSources
import Screening
import Store

extension SourceKind {
    var displayName: String {
        switch self {
        case .greenhouse: "Greenhouse"
        case .lever: "Lever"
        case .ashby: "Ashby"
        case .smartRecruiters: "SmartRecruiters"
        case .workable: "Workable"
        case .recruitee: "Recruitee"
        case .personio: "Personio"
        case .bambooHR: "BambooHR"
        case .teamtailor: "Teamtailor"
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
    /// The name you gave the company, else its board slug; a search says what it searches.
    var displayName: String {
        if kind == .adzuna { return "Your job titles" }
        return BoardConfig.decode(config).map { $0.company ?? $0.slug } ?? kind.displayName
    }
}

extension Country {
    var shortName: String {
        switch self {
        case .canada: "Canada"
        case .unitedStates: "US"
        }
    }

    var displayName: String {
        switch self {
        case .canada: "Canada"
        case .unitedStates: "United States"
        }
    }

    /// "Provinces" or "States", for where you'd work on site.
    var regionsName: String { self == .canada ? "Provinces" : "States" }
}

extension Verdict {
    var title: String {
        switch self {
        case .yes: "Yes"
        case .maybe: "Maybe"
        case .no: "No"
        }
    }

    /// The design's symbols: always shown with the colour and the word.
    var symbol: String {
        switch self {
        case .yes: "checkmark.circle"
        case .maybe: "circle.lefthalf.filled"
        case .no: "minus.circle"
        }
    }
}

extension Seniority {
    var title: String {
        switch self {
        case .intern: "Intern and co-op"
        case .junior: "Junior"
        case .mid: "Intermediate"
        case .senior: "Senior"
        case .lead: "Lead"
        case .staff: "Staff"
        case .principal: "Principal"
        case .manager: "Manager"
        case .director: "Director and up"
        }
    }
}

extension WorkProfile.Status {
    var title: String {
        switch self {
        case .citizen: "Citizen"
        case .permanentResident: "Permanent resident"
        case .workPermit: "Work permit"
        case .needsSponsorship: "Needs visa sponsorship"
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
