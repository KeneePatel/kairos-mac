import Screening
import Store
import SwiftUI

/// A job full width (UI v2): what Return opens from a list, and what Applied, Filtered out and
/// Improve open for a job. The pane with room, plus Previous and Next through the list it came
/// from.
struct JobScreen: View {
    @Environment(AppModel.self) private var model
    let id: JobID
    private let preview: StoredAnalysis?
    private let listings: [Listing]
    private let history: [JobEvent]

    init(id: JobID, preview: StoredAnalysis? = nil, listings: [Listing] = [], history: [JobEvent] = []) {
        self.id = id
        self.preview = preview
        self.listings = listings
        self.history = history
    }

    private var job: Job? { model.job(id) }

    /// Where this job sits in the list it came from, for Previous and Next.
    private var position: (index: Int, count: Int)? {
        guard let index = model.visibleJobs.firstIndex(of: id) else { return nil }
        return (index, model.visibleJobs.count)
    }

    var body: some View {
        JobPane(id: id, full: true, preview: preview, listings: listings, history: history)
            .navigationTitle(job?.title ?? "Job")
            .navigationSubtitle(job?.company ?? "")
            .toolbar {
                if let position {
                    ToolbarItemGroup(placement: .navigation) {
                        Text("\(position.index + 1) of \(position.count)").font(TypeStyle.callout)
                            .foregroundStyle(Color(.inkSecondary)).monospacedDigit()
                        Button {
                            model.selectNeighbour(-1)
                        } label: {
                            Label("Previous", systemImage: "chevron.up")
                        }
                        .disabled(position.index == 0)
                        .keyboardShortcut(.upArrow, modifiers: .command)
                        Button {
                            model.selectNeighbour(1)
                        } label: {
                            Label("Next", systemImage: "chevron.down")
                        }
                        .disabled(position.index + 1 >= position.count)
                        .keyboardShortcut(.downArrow, modifiers: .command)
                    }
                }
            }
    }
}
