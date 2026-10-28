import Foundation
import KairosKit
import TestKit
import Testing

@Suite("HTML entities")
struct HTMLEntitiesTests {
    @Test(arguments: [
        ("plain text", "plain text"),
        ("&lt;p&gt;Tom &amp;amp; Jerry&lt;/p&gt;", "<p>Tom &amp; Jerry</p>"),  // one level only
        ("caf&eacute; &#233; &#xE9; &#XE9;", "café é é é"),
        ("5 &lt; 6 &amp;&amp; 7 &gt; 3", "5 < 6 && 7 > 3"),
        ("AT&T and R&D", "AT&T and R&D"),
        ("&bogus; &#xZZ; &#0; &#;", "&bogus; &#xZZ; &#0; &#;"),
        ("&amp", "&amp"),
        ("trailing &", "trailing &"),
        ("&quot;quoted&quot; &apos;single&apos; a&nbsp;b", "\"quoted\" 'single' a\u{00A0}b"),
        ("emoji &#128640;", "emoji 🚀"),
    ])
    func decodesOneLevelOfReferences(input: String, expected: String) {
        #expect(HTMLEntities.decode(input) == expected)
    }
}

@Suite("HTML to Markdown")
struct HTMLToMarkdownTests {
    @Test func convertsAGreenhouseStylePosting() {
        let html = """
            <div class="content-intro"><p>We&#39;re building <strong>warehouse robots</strong> &amp; their software.</p></div>
            <h3>What you&rsquo;ll do</h3>
            <ul><li><p>Design services in <em>Go</em></p></li><li>Own on-call<ul><li>Nested item</li></ul></li></ul>
            <ol><li>First</li><li>Second</li></ol>
            <p>Apply <a href="https://acme.example/apply?x=1">here</a>, or <a href="javascript:alert(1)">not here</a>.</p>
            <script>alert("x")</script><style>p { color: red }</style>
            <p>Line one<br>Line two</p>
            """
        let expected = """
            We're building **warehouse robots** & their software.

            ### What you\u{2019}ll do

            - Design services in *Go*
            - Own on-call
              - Nested item

            1. First
            2. Second

            Apply [here](https://acme.example/apply?x=1), or not here.

            Line one
            Line two
            """
        #expect(HTMLToMarkdown.convert(html) == expected)
    }

    @Test(arguments: [
        ("", ""),
        ("plain words", "plain words"),
        ("<p>  lots   of\n\n spaces </p>", "lots of spaces"),
        ("<b></b>empty bold", "empty bold"),
        ("<a href=\"https://x.example\"></a>empty link", "empty link"),
        ("5 < 6 and <unclosed", "5 < 6 and"),
        ("<!-- a comment --><p>after</p>", "after"),
        ("<p>a</p><p></p><p></p><p>b</p>", "a\n\nb"),
        ("<h1>Title</h1><h5>Small</h5>", "# Title\n\n### Small"),
        ("<p>Spot&nbsp;on</p>", "Spot on"),
        ("<a href='https://x.example/a b'>spaced</a>", "spaced"),  // a URL that would break the link syntax
        ("<table><tr><td>Salary</td><td>$100k</td></tr></table>", "Salary $100k"),
    ])
    func handlesEdgeCases(html: String, expected: String) {
        #expect(HTMLToMarkdown.convert(html) == expected)
    }

    @Test func blocksComeBackOutForViews() {
        let html =
            "<h2>About</h2><p>We build.</p><ul><li>Go</li><li>Rust<ul><li>async</li></ul></li></ul><hr><ol><li>One</li></ol>"
        #expect(
            MarkdownBlock.parse(HTMLToMarkdown.convert(html)) == [
                .heading(level: 2, text: "About"), .paragraph("We build."),
                .item(marker: "•", depth: 0, text: "Go"), .item(marker: "•", depth: 0, text: "Rust"),
                .item(marker: "•", depth: 1, text: "async"), .rule, .item(marker: "1.", depth: 0, text: "One"),
            ])
    }

    @Test(arguments: [
        ("#hashtag", [MarkdownBlock.paragraph("#hashtag")]),
        ("1999. A year", [.paragraph("1999. A year")]),
        ("-dash", [.paragraph("-dash")]),
        ("", [MarkdownBlock]()),
    ])
    func leavesLookalikesAsText(markdown: String, expected: [MarkdownBlock]) {
        #expect(MarkdownBlock.parse(markdown) == expected)
    }
}

@Suite("Text helpers")
struct TextHelperTests {
    @Test func wordsKeepTechNames() {
        #expect("Node.js, C++ and C# — on .NET!".words == ["node.js", "c++", "and", "c#", "on", "net"])
        #expect("Montréal / Toronto".words == ["montreal", "toronto"])
    }

    @Test func wholeWordsOnly() {
        #expect("Go and Rust".containsWords("go"))
        #expect(!"Google Cloud".containsWords("go"))
        #expect("Senior Software Engineer".containsWords("software engineer"))
        #expect(!"".containsWords("x"))
    }

    @Test func truncatesAtAWord() {
        #expect("one two three".truncated(to: 9) == "one two…")
        #expect("short".truncated(to: 10) == "short")
    }

    @Test func tidiesAndFolds() {
        #expect("  a \n b\tc ".tidied == "a b c")
        #expect("ÉCOLE".folded == "ecole")
        #expect([3, 1, 3, 2, 1].uniqued() == [3, 1, 2])
    }
}

@Suite("Dates and JSON")
struct DatesAndJSONTests {
    @Test(arguments: [
        ("2026-10-02T11:31:50-04:00", 1_790_955_110_000),
        ("2026-10-17T13:05:12.250Z", 1_792_242_312_250),
        ("2026-10-20 11:28:23 UTC", 1_792_495_703_000),
        ("2026-10-20", 1_792_454_400_000),
    ])
    func readsTheDateFormsBoardsUse(text: String, milliseconds: Int64) throws {
        #expect(try #require(ISODate.parse(text)).milliseconds == milliseconds)
    }

    @Test func rejectsWhatIsntADate() {
        #expect(ISODate.parse("yesterday") == nil)
    }

    @Test func describesDecodingErrorsByPath() {
        struct Page: Decodable {
            struct Job: Decodable { let title: String }
            let jobs: [Job]
        }
        do {
            _ = try JSONDecoder().decode(Page.self, from: Data(#"{"jobs":[{"name":"x"}]}"#.utf8))
            Issue.record("expected a decoding error")
        } catch let error as DecodingError {
            #expect(describe(error) == "jobs[0].title: missing")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func jsonValuesRoundTripWithSortedKeys() throws {
        let value: JSONValue = ["b": [1, 2.5, "x"], "a": true, "c": nil]
        #expect(value.text == #"{"a":true,"b":[1,2.5,"x"],"c":null}"#)
        #expect(try JSONValue(parsing: value.text) == value)
        #expect(value["b"]?.arrayValue?.count == 3)
    }
}

@Suite("Identifiers")
struct IdentifierTests {
    @Test func uuidV7HasItsVersionVariantAndTime() {
        var generator = UUIDv7Generator()
        var random = SystemRandomNumberGenerator()
        let id = generator.next(milliseconds: 0x0190_1234_5678, using: &random)
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        #expect(bytes[6] >> 4 == 7)
        #expect(bytes[8] >> 6 == 0b10)
        #expect(id.lowercased.hasPrefix("01901234-5678-7"))
    }

    @Test func idsFromOneMillisecondSortInOrder() {
        var generator = UUIDv7Generator()
        var random = SystemRandomNumberGenerator()
        let ids = (0..<500).map { _ in generator.next(milliseconds: 1_000, using: &random).lowercased }
        #expect(ids == ids.sorted())
        #expect(Set(ids).count == 500)
    }

    @Test func stableIDsAreSixteenBytesOfHex() {
        let id = StableID.of("https://job-boards.greenhouse.io/acme/jobs/1")
        #expect(id.count == 32 && id.allSatisfy(\.isHexDigit))
        #expect(id == StableID.of("https://job-boards.greenhouse.io/acme/jobs/1"))
        #expect(id != StableID.of("https://job-boards.greenhouse.io/acme/jobs/2"))
    }
}

@Suite("Concurrency gate")
struct ConcurrencyGateTests {
    @Test func runsAtMostTheLimitPerKey() async throws {
        let gate = ConcurrencyGate(limit: 2)
        let peak = Locked([String: (now: Int, max: Int)]())
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                let key = index.isMultiple(of: 2) ? "a.example" : "b.example"
                group.addTask {
                    try await gate.run(key) {
                        peak.withLock { counts in
                            var entry = counts[key] ?? (0, 0)
                            entry.now += 1
                            entry.max = max(entry.max, entry.now)
                            counts[key] = entry
                        }
                        try await Task.sleep(for: .milliseconds(5))
                        peak.withLock { $0[key]?.now -= 1 }
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(peak.value["a.example"]?.max == 2)
        #expect(peak.value["b.example"]?.max == 2)
    }
}

@Suite("Fake HTTP")
struct FakeHTTPTests {
    @Test func unscriptedRequestsFail() async throws {
        let http = FakeHTTP()
        let url = try #require(URL(string: "https://example.com/x"))
        await #expect(throws: HTTPError.self) { _ = try await http.send(.json(url)) }
    }
}
