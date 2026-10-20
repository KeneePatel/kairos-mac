import SwiftUI

/// The run's button: the view's one primary action, or the run's progress and a way to stop it.
struct RunControls: ToolbarContent {
    let model: AppModel
    var title = "Run now"

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.isFetching {
                ProgressView(value: model.runFraction)
                    .frame(width: 120)
                    .accessibilityLabel(model.screening == nil ? "Fetching boards" : "Screening jobs")
                Button {
                    model.stopFetch()
                } label: {
                    Label("Stop", systemImage: "stop.fill").labelStyle(.titleAndIcon)
                }
            } else {
                Button {
                    model.fetchNow()
                } label: {
                    Label(title, systemImage: "arrow.clockwise").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.sources.allSatisfy { !$0.enabled })
                .help(
                    model.sources.isEmpty ? "Add a company in Fetch first" : "Check every enabled board, then screen")
            }
        }
    }
}
