import Pipeline
import SwiftUI

/// The sidebar's footer (UI v2, 2026-10-26): the one place Kairos says what it's doing. One line,
/// a meter while something runs or after a stop, a detail line, and the one button that fits:
/// Stop while a run goes, Resume after an early stop, Find now otherwise. Nothing else in the app
/// announces a run, apart from the resume page for its own build.
struct StatusFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.runStatus
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Divider()
            Text(status.title).font(TypeStyle.callout).foregroundStyle(Color(.ink)).lineLimit(1)
                .monospacedDigit()
            if let fraction = status.fraction {
                ProgressMeter(fraction: fraction, stopped: status.kind == .stoppedEarly)
            }
            // The detail and the button share the second line: the sidebar is too narrow for the
            // button beside a title with a time in it.
            HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
                if let detail = status.detail {
                    Text(detail).font(TypeStyle.caption).foregroundStyle(Color(.inkSecondary)).lineLimit(2)
                }
                Spacer(minLength: 0)
                action(status)
            }
        }
        .padding(.horizontal, Spacing.space3)
        .padding(.vertical, Spacing.space3)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func action(_ status: RunStatus) -> some View {
        switch status.kind {
        case .fetching, .screening:
            Button("Stop") { model.stopFetch() }
                .buttonStyle(.plain).foregroundStyle(Color(.accentText)).font(TypeStyle.caption)
                .help("Stop. Jobs keep what they have; the rest wait for the next run.")
        case .stoppedEarly:
            if model.canAnalyse {
                Button("Resume") { model.screenWaiting() }
                    .buttonStyle(.plain).foregroundStyle(Color(.accentText)).font(TypeStyle.caption)
                    .help("Screen the jobs still waiting, one AI call each.")
            }
        case .building:
            EmptyView()
        case .idle, .never:
            Button("Find now") { model.fetchNow() }
                .buttonStyle(.plain).foregroundStyle(Color(.accentText)).font(TypeStyle.caption)
                .disabled(model.sources.allSatisfy { !$0.enabled })
                .help("Check every enabled board, then screen what's new (⌘R).")
        }
    }
}

/// How far a run is: a 6 pt capsule, the separator track and an accent fill, amber after a stop.
/// Always next to words, so it never rests on colour alone.
struct ProgressMeter: View {
    let fraction: Double
    var stopped = false

    var body: some View {
        Capsule().fill(Color(.separator))
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(stopped ? Color(.maybe) : Color(.accent))
                        .frame(width: proxy.size.width * min(1, max(0, fraction)))
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
    }
}
