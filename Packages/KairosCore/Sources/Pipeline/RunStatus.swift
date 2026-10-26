import Foundation

/// The one line the app shows about what Kairos is doing (UI v2, 2026-10-26): finding jobs,
/// screening them, building resumes, a run that stopped early, or when it last checked. The
/// sidebar's footer draws it; the menu bar item will too. Pure, so every wording is tested.
public struct RunStatus: Equatable, Sendable {
    public enum Kind: Sendable, Equatable {
        case fetching, screening, building, stoppedEarly, idle, never
    }

    public var kind: Kind
    /// "Finding jobs · 212 of 821", "Checked 7:58 AM · 14 new".
    public var title: String
    /// The second line, when there's something to say.
    public var detail: String?
    /// How far the run is, 0 to 1; after an early stop, how far it got. Nil when nothing runs.
    public var fraction: Double?

    /// Everything the line is made from.
    public struct Input: Sendable, Equatable {
        public var fetching = false
        public var fetch: FetchRun.Progress?
        public var screening: ScreeningRun.Progress?
        /// Resumes being built right now, and the ones queued behind them.
        public var building = 0
        public var queued = 0
        /// When the last fetch finished, and how many jobs it added.
        public var lastChecked: Date?
        public var newLastTime = 0
        /// Jobs that passed the filters and still wait for a verdict.
        public var waiting = 0
        public var hasSources = true

        public init() {}
    }

    public init(kind: Kind, title: String, detail: String? = nil, fraction: Double? = nil) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.fraction = fraction
    }

    /// The line for the app's state now. `time` turns the last check's date into "7:58 AM".
    public static func current(
        _ input: Input, time: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
    ) -> RunStatus {
        if input.fetching, let screening = input.screening, screening.phase == .running {
            let progress = screening.total > 0 ? " · \(screening.done) of \(screening.total)" : ""
            return RunStatus(
                kind: .screening, title: "Screening jobs\(progress)",
                detail: screening.done > 0
                    ? "\(screening.yes) Yes · \(screening.maybe) Maybe so far"
                    : "Reading each posting against your resume",
                fraction: screening.total > 0 ? Double(screening.done) / Double(screening.total) : 0)
        }
        if input.fetching {
            let fetch = input.fetch
            let progress =
                (fetch?.sourcesTotal ?? 0) > 0 ? " · \(fetch?.sourcesDone ?? 0) of \(fetch?.sourcesTotal ?? 0)" : ""
            var detail = (fetch?.added ?? 0) > 0 ? "\(fetch?.added ?? 0) new so far" : "Nothing new yet"
            if let failed = fetch?.failures.count, failed > 0 {
                detail += " · \(failed) board\(failed == 1 ? "" : "s") failed"
            }
            return RunStatus(
                kind: .fetching, title: "Finding jobs\(progress)", detail: detail,
                fraction: (fetch?.sourcesTotal ?? 0) > 0
                    ? Double(fetch?.sourcesDone ?? 0) / Double(fetch?.sourcesTotal ?? 1) : 0)
        }
        if input.building > 0 {
            return RunStatus(
                kind: .building, title: "Building \(input.building) resume\(input.building == 1 ? "" : "s")",
                detail: input.queued > 0 ? "\(input.queued) more queued" : nil)
        }
        if let screening = input.screening, screening.stopped != nil || screening.phase == .cancelled, input.waiting > 0
        {
            return RunStatus(
                kind: .stoppedEarly, title: "Screening stopped · \(input.waiting) waiting",
                detail: screening.stopped ?? "You stopped it. Resume picks up where it left off.",
                fraction: screening.total > 0 ? Double(screening.done) / Double(screening.total) : nil)
        }
        if let checked = input.lastChecked {
            let new = input.newLastTime > 0 ? "\(input.newLastTime.formatted()) new" : "nothing new"
            return RunStatus(
                kind: .idle, title: "Checked \(time(checked)) · \(new)",
                detail: input.waiting > 0 ? "\(input.waiting) waiting for the AI" : nil)
        }
        return input.hasSources
            ? RunStatus(kind: .never, title: "Not checked yet", detail: "Find new jobs checks every board")
            : RunStatus(kind: .never, title: "No companies yet", detail: "Add a company in Sources")
    }
}
