import Pipeline
import SwiftUI

/// Review's line about screening, pinned above the list whatever the list shows (2026-10-26).
/// While screening runs: how far it is, with Stop. Otherwise, when jobs wait for the AI: how many,
/// what screening them costs or why the last run stopped, and the one button that moves them on.
struct ScreeningBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isScreening, let progress = model.screening {
            running(progress)
        } else if model.waitingForAI > 0 {
            waiting(model.waitingForAI)
        }
    }

    private func running(_ progress: ScreeningRun.Progress) -> some View {
        bar(background: .surfaceRaised) {
            ProgressView(value: model.runFraction)
                .frame(width: 120)
                .accessibilityLabel("Screening jobs")
            lines(
                "Screening \(progress.done) of \(progress.total) job\(progress.total == 1 ? "" : "s")",
                "So far \(progress.yes) Yes, \(progress.maybe) Maybe, \(progress.no) No. You can keep working.")
            Spacer(minLength: Spacing.space4)
            Button("Stop") { model.stopFetch() }
                .help("Stop screening. Jobs keep the verdicts they have; the rest wait for the next run.")
        }
    }

    private func waiting(_ count: Int) -> some View {
        let stoppedEarly = model.screening.map { $0.stopped != nil || $0.phase == .cancelled } ?? false
        return bar(background: stoppedEarly ? .maybeBg : .surfaceRaised) {
            Image(systemName: stoppedEarly ? "pause.circle" : "hourglass")
                .font(TypeStyle.headline).foregroundStyle(Color(.ink2))
                .accessibilityHidden(true)
            lines("\(count) job\(count == 1 ? " is" : "s are") waiting for the AI", detail(count))
            Spacer(minLength: Spacing.space4)
            if model.canAnalyse {
                Button(count == 1 ? "Screen it" : "Screen them") { model.screenWaiting() }
                    .disabled(model.isFetching)
                    .help(
                        model.isFetching
                            ? "Find new jobs is running; it screens them when it's done."
                            : "Analyses the waiting jobs, one AI call each, and leaves every other job as it is.")
            } else {
                Button("Open AI settings") {
                    model.settingsTab = .ai
                    model.section = .settings
                }
            }
        }
        .task(id: model.isFetching) { await model.ai?.refreshUsage() }
    }

    /// Why they wait, or what screening them costs today.
    private func detail(_ count: Int) -> String {
        guard model.canAnalyse else { return "Add an AI key to screen them." }
        if let last = model.screening {
            if last.phase == .cancelled { return "You stopped screening. Screen them to pick up where it left off." }
            if let stopped = last.stopped { return stopped }
            if last.failed > 0 {
                return
                    "\(last.failed) couldn't be analysed last time and \(last.failed == 1 ? "is" : "are") tried again."
            }
        }
        let calls = "It takes up to \(count) AI call\(count == 1 ? "" : "s")"
        guard let ai = model.ai else { return calls + "." }
        let left = max(0, ai.settings.budget.dailyCalls - ai.usedToday)
        if left >= count { return calls + "; you have \(left) of your \(ai.settings.budget.dailyCalls) left today." }
        return calls + ", more than the \(left) left today. The rest wait for tomorrow's budget."
    }

    private func lines(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(TypeStyle.headline).foregroundStyle(Color(.ink)).monospacedDigit()
            Text(detail).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).lineLimit(2)
        }
    }

    private func bar(background: ColorResource, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: Spacing.space3) { content() }
                .padding(.horizontal, Spacing.space4).padding(.vertical, Spacing.space3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(background))
            Divider()
        }
    }
}
