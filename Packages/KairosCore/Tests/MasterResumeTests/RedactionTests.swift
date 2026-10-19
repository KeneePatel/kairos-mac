import Foundation
import Testing

@testable import MasterResume

/// The design's sample persona: fixtures only.
private func jordan() -> ResumeHeader {
    var header = ResumeHeader()
    header.fullName = "Jordan Rivera"
    header.email = "jordan.rivera@example.com"
    header.phone = "+14165550123"
    header.linkedInURL = "https://www.linkedin.com/in/jordan-rivera"
    header.gitHubURL = "https://github.com/jrivera"
    header.portfolioURL = "https://jordanrivera.dev"
    header.city = "Toronto"
    header.region = "ON"
    return header
}

private func redact(_ text: String) -> String { ContactRedactor.redact(text, header: jordan()) }

@Suite("Contact redaction")
struct RedactionTests {
    @Test(arguments: [
        // Your own values, however they're written
        ("Jordan Rivera", "[removed]"),
        ("JORDAN RIVERA · Backend developer", "[removed] · Backend developer"),
        ("Rivera, Jordan", "[removed]"),
        ("jordan.rivera@example.com", "[removed]"),
        ("Email: Jordan.Rivera@Example.com", "Email: [removed]"),
        ("+1 (416) 555-0123", "[removed]"),
        ("416-555-0123", "[removed]"),
        ("416.555.0123", "[removed]"),
        ("(416) 555 0123", "[removed]"),
        ("4165550123", "[removed]"),
        ("linkedin.com/in/jordan-rivera", "[removed]"),
        ("https://www.linkedin.com/in/jordan-rivera/", "[removed]"),
        ("github.com/jrivera", "[removed]"),
        ("jordanrivera.dev", "[removed]"),
        ("https://jordanrivera.dev/work", "[removed]"),
        // Anything shaped like contact details, even someone else's
        ("Ref: sam.lee@northline.example", "Ref: [removed]"),
        ("Call 604-555-0199 or +44 20 7946 0958", "Call [removed] or [removed]"),
        ("Profile: https://www.linkedin.com/in/someone-else", "Profile: [removed]"),
        ("Code at github.com/jrivera/dockyard", "Code at [removed]"),
        ("gitlab.com/someone", "[removed]"),
        ("x.com/jrivera and twitter.com/jrivera", "[removed] and [removed]"),
    ])
    func removesContactDetails(input: String, expected: String) {
        #expect(redact(input) == expected)
    }

    @Test(arguments: [
        "Backend Developer II, Northline Freight · Toronto, ON · Mar 2021 – Present",
        "2019 - 2023",
        "2021-03 to 2023-11",
        "Cut p95 latency by 40% and handled 4,200,000 events a day",
        "Saved $1,250,000 a year; 99.95% uptime over 12 months",
        "Built on AWS (us-east-1) with Go 1.22 and PostgreSQL 16",
        "University of Waterloo, BMath, 2015–2019",
        "Read the docs at https://go.dev/doc and https://northline.example/careers",
        "Jordan Valley Logistics",  // not the full name
    ])
    func keepsEverythingElse(_ text: String) {
        #expect(redact(text) == text)
    }

    @Test func aWholeResumeComesOutClean() {
        let resume = """
            JORDAN RIVERA
            Toronto, ON · +1 (416) 555-0123 · jordan.rivera@example.com
            linkedin.com/in/jordan-rivera · github.com/jrivera · jordanrivera.dev

            EXPERIENCE
            Backend Developer II, Northline Freight — Toronto, ON (Mar 2021 – Present)
            • Cut p95 latency of the tracking API by 40%.
            """
        let redacted = redact(resume)
        for value in ["Jordan", "Rivera", "416", "555", "example.com", "linkedin", "github", "jordanrivera"] {
            #expect(!redacted.localizedCaseInsensitiveContains(value), "\(value) survived")
        }
        #expect(redacted.contains("Northline Freight — Toronto, ON (Mar 2021 – Present)"))
        #expect(redacted.contains("Cut p95 latency of the tracking API by 40%."))
    }

    @Test func redactingTwiceChangesNothingMore() {
        let once = redact("Jordan Rivera, 416-555-0123")
        #expect(redact(once) == once)
    }

    @Test func blankContactFieldsAreSafe() {
        #expect(ContactRedactor.redact("Hello world 2024", header: ResumeHeader()) == "Hello world 2024")
    }
}
