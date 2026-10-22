import Store
import Tailoring

/// "Build resumes for every Yes" (or Maybe): which jobs get a build, which are skipped, and about
/// how many AI calls it takes. A job is skipped when it has a resume, or one waiting or being built;
/// a job whose last build failed is built again. A build needs an analysis from the current prompt,
/// so a job without one is counted, not queued.
public struct BulkBuild: Sendable, Equatable {
    /// The jobs to build, in the list's order.
    public let jobs: [JobID]
    public let alreadyBuilt: Int
    public let notAnalysed: Int

    /// `latest` is each job's newest build status, by job id; `analysed`, the jobs the current
    /// prompt analysed.
    public init(candidates: [JobID], latest: [String: BuildStatus], analysed: Set<JobID>) {
        var jobs: [JobID] = []
        var alreadyBuilt = 0
        var notAnalysed = 0
        for job in candidates {
            if let status = latest[job.rawValue], status != .failed {
                alreadyBuilt += 1
            } else if !analysed.contains(job) {
                notAnalysed += 1
            } else {
                jobs.append(job)
            }
        }
        self.jobs = jobs
        self.alreadyBuilt = alreadyBuilt
        self.notAnalysed = notAnalysed
    }

    /// About how many AI calls one build makes (BuildLoop): a writer for experience, projects and
    /// skills, and the summary when the template has one; outside Lite, up to the rewrite passes
    /// over experience and projects; Stretch's gap bullets; the cover letter. A reply that fails
    /// its checks costs one more call to repair, which isn't counted.
    public static func calls(mode: BuildMode, coverLetter: Bool, summary: Bool) -> ClosedRange<Int> {
        let writers = (mode == .lite ? 1 : 3) + (summary ? 1 : 0)
        let least = writers + (coverLetter ? 1 : 0)
        let rewrites = mode == .lite ? 0 : 2 * BuildLoop.Settings().maxPasses
        return least...(least + rewrites + (mode == .stretch ? 1 : 0))
    }

    /// The whole run's calls.
    public func calls(mode: BuildMode, coverLetter: Bool, summary: Bool) -> ClosedRange<Int> {
        let one = Self.calls(mode: mode, coverLetter: coverLetter, summary: summary)
        return (one.lowerBound * jobs.count)...(one.upperBound * jobs.count)
    }
}
