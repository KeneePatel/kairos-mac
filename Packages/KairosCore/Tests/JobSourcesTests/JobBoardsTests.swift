import Foundation
import Testing

@testable import JobSources

/// Job boards and aggregators (job collection v3, C1): known by host, their tracking dropped, and
/// an apply option trusted only when it names the company or the site the posting came from.
@Suite("Job boards")
struct JobBoardsTests {
    @Test func boardsAreKnownByHostAndParentDomain() {
        #expect(JobBoards.isJobBoard("ca.indeed.com") && JobBoards.isJobBoard("www.linkedin.com"))
        #expect(JobBoards.isJobBoard("ca.jooble.org") && JobBoards.isJobBoard("www.google.com"))
        #expect(!JobBoards.isJobBoard("jobs.scotiabank.com") && !JobBoards.isJobBoard("boards.greenhouse.io"))
        #expect(!JobBoards.isJobBoard("notindeed.com"))
    }

    @Test func trackingParametersAreDropped() {
        let tracked = URL(string: "https://acme.example/jobs/1?utm_source=google_jobs_apply&ref=x&id=7")!
        #expect(JobBoards.stripped(tracked).absoluteString == "https://acme.example/jobs/1?id=7")
        let bare = URL(string: "https://acme.example/jobs/1?utm_campaign=g")!
        #expect(JobBoards.stripped(bare).absoluteString == "https://acme.example/jobs/1")
        let plain = URL(string: "https://acme.example/jobs/1/")!
        #expect(JobBoards.stripped(plain) == plain)
    }

    @Test func anOptionNamesTheCompanyOrTheSource() {
        #expect(JobBoards.names("Scotiabank", company: "Scotiabank", via: "Scotiabank"))
        #expect(JobBoards.names("Softline", company: "Softline Technology", via: "Indeed"))
        #expect(JobBoards.names("Intuit Careers", company: "Intuit", via: "Intuit Careers"))
        #expect(JobBoards.names("Randstad", company: "Randstad Canada", via: "Randstad"))
        #expect(JobBoards.names("MyProcom", company: "Procom", via: "MyProcom"))
        #expect(!JobBoards.names("Workday", company: "Scotiabank", via: "Scotiabank"))
        #expect(!JobBoards.names("OceanMD - JazzHR", company: "Scotiabank", via: "Scotiabank"))
        #expect(!JobBoards.names("Jobs Straight From The Employer", company: "Cohere", via: "LinkedIn"))
        // Filler words alone never match.
        #expect(!JobBoards.names("The Company Careers", company: "Acme Technologies Inc", via: nil))
    }
}
