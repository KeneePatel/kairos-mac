import Foundation
import Testing

@testable import Store

/// Places (job collection v3, C3): the cities Google Jobs searches in.
@Suite("Places")
struct PlaceTests {
    @Test func eachCountryHasItsUsualCities() {
        #expect(
            Place.defaults(for: .canada).map(\.displayName) == [
                "Toronto, Ontario", "Vancouver, British Columbia", "Montreal, Quebec", "Ottawa, Ontario",
                "Calgary, Alberta", "Waterloo, Ontario", "Halifax, Nova Scotia",
            ])
        #expect(Place.defaults(for: .unitedStates).count == 5)
        #expect(Place.defaults(for: .canada).last?.googleLocation == "Halifax, Nova Scotia, Canada")
    }

    @Test func aPlaceIsReadFromCityAndRegion() {
        #expect(Place.parse("Halifax, Nova Scotia") == Place(city: "Halifax", region: "Nova Scotia", country: .canada))
        #expect(Place.parse("halifax, ns")?.region == "Nova Scotia")
        #expect(Place.parse("Austin, TX") == Place(city: "Austin", region: "Texas", country: .unitedStates))
        #expect(Place.parse("Québec City, Québec") == nil)  // spelled as the region is listed: Quebec
        #expect(Place.parse("Quebec City, Quebec")?.country == .canada)
        #expect(Place.parse("Halifax") == nil && Place.parse(", Ontario") == nil && Place.parse("Toronto, Mars") == nil)
        #expect(Place(city: "Toronto", region: "Ontario", country: .canada).key == "toronto|ontario|ca")
    }
}
