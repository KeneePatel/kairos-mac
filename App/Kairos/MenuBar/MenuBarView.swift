import Engine
import Screening
import Store
import SwiftUI

/// The menu bar item: what waits for you, what's new since you looked, a running build, and
/// Find new jobs and Open Kairos.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Kairos").font(TypeStyle.title2)
                Spacer()
                Text(status).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: Spacing.space1) {
                Text("\(model.count(.inbox) ?? 0) to decide").font(TypeStyle.title1).monospacedDigit()
                if model.newSinceLooked > 0 {
                    Text("\(model.newSinceLooked) new since you looked").font(TypeStyle.callout)
                        .foregroundStyle(Color(.inkSecondary))
                }
            }
            HStack(spacing: Spacing.space2) {
                tile(.yes, model.counts.yes)
                tile(.maybe, model.counts.maybe)
                tile(.no, model.counts.no)
            }
            if let build = model.builds.first(where: { !$0.status.isFinished }) {
                Card(padding: Spacing.space3) {
                    VStack(alignment: .leading, spacing: Spacing.space1) {
                        Text("Building for \(model.summary(build.jobID)?.company ?? "a job")").font(TypeStyle.headline)
                        Text(model.liveBuilds[build.id]?.step.map(BuildPage.describe) ?? "Waiting for a worker")
                            .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                    }
                }
            }
            if case .fetching(let progress) = model.activity {
                ProgressMeter(fraction: progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total))
            }
            HStack {
                Button("Find new jobs") { model.findNewJobs() }
                    .disabled(model.activity.isRunning)
                Spacer()
                Button("Open Kairos") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(Spacing.space5)
        .frame(width: 340)
    }

    private var status: String {
        switch model.activity {
        case .fetching: "Finding jobs…"
        case .screening: "Screening…"
        case .idle: model.lastFetch?.finishedAt.map { "Checked \($0.formatted(.relative(presentation: .named)))" } ?? ""
        }
    }

    private func tile(_ verdict: Verdict, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(verdict.title, systemImage: verdict.symbol).font(TypeStyle.caption).foregroundStyle(verdict.color)
            Text("\(count)").font(TypeStyle.scoreSmall).foregroundStyle(Color(.ink))
        }
        .padding(Spacing.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(verdict.background))
    }
}
