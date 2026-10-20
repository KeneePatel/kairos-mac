import Foundation

/// Progress of one "Fetch now" from start to finish: fetching, then screening (SPEC §5.2).
public enum PipelineEvent: Sendable, Equatable {
    case fetching(FetchRun.Progress)
    case screening(ScreeningRun.Progress)
}

/// The whole pipeline: a fetch, then screening of every job still without a verdict, the new ones
/// and any left over from an earlier run. Stopping the stream cancels whichever part is running.
public struct PipelineRun: Sendable {
    let fetch: FetchRun
    let screening: ScreeningRun

    public init(fetch: FetchRun, screening: ScreeningRun) {
        self.fetch = fetch
        self.screening = screening
    }

    public func start() -> AsyncStream<PipelineEvent> {
        AsyncStream { continuation in
            let task = Task {
                for await progress in fetch.start() { continuation.yield(.fetching(progress)) }
                if !Task.isCancelled {
                    for await progress in screening.start() { continuation.yield(.screening(progress)) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
