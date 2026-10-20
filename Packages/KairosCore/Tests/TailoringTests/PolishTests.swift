import Foundation
import Testing

@testable import Tailoring

/// SPEC §5.3, Polish: code, not the model, has the last word on phrasing and spelling.
@Suite("Polish")
struct PolishTests {
    let canada = Polish(locale: .canada)
    let us = Polish(locale: .unitedStates)

    @Test func aiSoundingPhrasesGo() {
        #expect(
            canada.text("Spearheaded the migration, leveraging Kubernetes to seamlessly utilize shared Helm charts.")
                == "Led the migration, using Kubernetes to use shared Helm charts.")
        #expect(canada.text("Utilized Go in order to cut latency.") == "Used Go to cut latency.")
        #expect(canada.text("Played a pivotal role in the migration.") == "Helped with the migration.")
    }

    @Test func openingVerbsDontRepeat() {
        let polished = canada.bullets(["Built the API.", "Built the queue.", "built the CLI.", "Led the team."])
        #expect(polished == ["Built the API.", "Developed the queue.", "Created the CLI.", "Led the team."])
    }

    @Test func spellingFollowsTheJobsCountry() {
        #expect(
            canada.text("Optimized color modeling for the data center; canceled the analog behavior.")
                == "Optimized colour modelling for the data centre; cancelled the analogue behaviour.")
        #expect(
            us.text("Improved the colour of the centre and labelled the catalogue.")
                == "Improved the color of the center and labeled the catalog.")
        #expect(canada.text("Color, COLOR and color") == "Colour, COLOUR and colour")
        // Whole words only.
        #expect(canada.text("Set backgroundColor in Colorado") == "Set backgroundColor in Colorado")
    }

    @Test func bulletsEndCleanAndFitTheLimit() {
        #expect(
            canada.bullets(["Built  the   API", " Cut costs by 40%. "]) == ["Built the API.", "Cut costs by 40%."])
        let long =
            "Built an event pipeline in Go handling 4.2M events a day with p99 under 120 ms; "
            + String(repeating: "worked with the platform team on shared tooling and runbooks, ", count: 4)
        let fitted = canada.bullets([long])[0]
        #expect(fitted.count <= Polish.maxBulletLength)
        #expect(fitted == "Built an event pipeline in Go handling 4.2M events a day with p99 under 120 ms.")
    }

    @Test func polishingTwiceChangesNothingMore() {
        let once = canada.bullets(["Spearheaded the color migration", "Spearheaded the API"])
        #expect(canada.bullets(once) == once)
    }
}
