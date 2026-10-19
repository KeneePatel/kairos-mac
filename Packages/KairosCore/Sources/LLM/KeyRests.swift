import Foundation
import Synchronization

/// Keys a 429 told to rest, per model, shared by every client built for one provider. The next
/// operation skips a key that used up its quota instead of spending a request to find out again,
/// and Settings can say when it's back. Gemini counts quota per model, so a key out of Flash
/// requests still serves Flash-Lite. Times are on the clients' clock; `SystemClock`s share a start.
public final class KeyRests: Sendable {
    public struct Rest: Sendable, Equatable {
        public let model: String
        public let remaining: Duration
    }

    private struct Slot: Hashable {
        let key: String
        let model: String
    }

    private let slots = Mutex<[Slot: Duration]>([:])

    public init() {}

    func until(key: String, model: String) -> Duration? {
        slots.withLock { $0[Slot(key: key, model: model)] }
    }

    /// Clients call this on a 429; previews use it to show a resting key.
    public func rest(key: String, model: String, until time: Duration) {
        slots.withLock { $0[Slot(key: key, model: model)] = time }
    }

    /// The models `key` is still resting from at `now`, soonest back first.
    public func resting(key: String, at now: Duration) -> [Rest] {
        slots.withLock { slots in
            slots.filter { $0.key.key == key && $0.value > now }
                .map { Rest(model: $0.key.model, remaining: $0.value - now) }
                .sorted { ($0.remaining, $0.model) < ($1.remaining, $1.model) }
        }
    }
}
