import Testing

@testable import Tailoring

@Suite struct TechVocabularyTests {
    /// Improve counts "K8s" and "Kubernetes" as one ask, keeping the posting's spelling.
    @Test func synonymsShareACanonicalNameAndKeepTheirSpelling() {
        let named = TechVocabulary.technologies(in: "Run services on K8s and Postgres, with DataDog")
        #expect(named.map(\.canonical) == ["kubernetes", "postgresql", "datadog"])
        #expect(named.map(\.written) == ["K8s", "Postgres", "DataDog"])
        // "go live" isn't the language.
        #expect(TechVocabulary.technologies(in: "Help us go live").isEmpty)
    }

    @Test func broaderTermsListWhatTheyStandFor() {
        let concepts = TechVocabulary.concepts(in: "Experience with cloud platforms and CI/CD")
        #expect(concepts.map(\.concept) == ["ci/cd", "cloud"])
        #expect(concepts.first { $0.concept == "cloud" }?.members.contains("gcp") == true)
        #expect(TechVocabulary.concepts(in: "Strong communication").isEmpty)
    }
}
