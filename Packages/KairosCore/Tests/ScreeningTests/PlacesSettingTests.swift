import Foundation
import Store
import Testing

@testable import Screening

/// Your places and the agency switch in the search settings (job collection v3, C3).
@Suite("Places setting")
struct PlacesSettingTests {
    @Test func theUsualCitiesStandInUntilYouSetYourOwn() throws {
        var preferences = SearchPreferences()
        preferences.countries = [.canada]
        #expect(preferences.places == nil)
        #expect(preferences.effectivePlaces == Place.defaults(for: .canada))
        preferences.countries = [.canada, .unitedStates]
        #expect(preferences.effectivePlaces.count == 12 && preferences.effectivePlaces.last?.country == .unitedStates)
        preferences.places = [Place(city: "Halifax", region: "Nova Scotia", country: .canada)]
        #expect(preferences.effectivePlaces.map(\.googleLocation) == ["Halifax, Nova Scotia, Canada"])
        // Older settings without the fields still load: the usual cities, agencies left out.
        let old = Data(#"{"countries":["CA"],"blacklist":["Acme"]}"#.utf8)
        let decoded = try JSONDecoder().decode(SearchPreferences.self, from: old)
        #expect(decoded.places == nil && decoded.showAgencies == false && decoded.blacklist == ["Acme"])
        let again = try JSONDecoder().decode(SearchPreferences.self, from: try JSONEncoder().encode(preferences))
        #expect(again.places == preferences.places)
    }
}
