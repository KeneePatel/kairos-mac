import AppKit
import Pipeline
import Store
import SwiftUI

/// The menu bar item's window (UI v2, SPEC R2): what waits for you, what's new, what Kairos is
/// doing, and the two things you'd do from here: find new jobs, or open Kairos.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var inbox: [Job] { model.inboxJobs }

    var body: some View {
        VStack(spacing: Spacing.space3) {
            header
            waiting
            if !newest.isEmpty { newToday }
            running
            Spacer(minLength: 0)
            Button {
                open(nil)
            } label: {
                Text("Open Kairos").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(Spacing.space4)
        .frame(width: 380)
        .frame(minHeight: 420)
    }

    private var header: some View {
        HStack(spacing: Spacing.space2) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 24, height: 24)
                .accessibilityHidden(true)
            Text("Kairos").font(TypeStyle.title2).foregroundStyle(Color(.ink))
            Spacer()
            Button {
                model.fetchNow()
            } label: {
                ActionLabel(title: "Find new jobs", key: "⌘R")
            }
            .disabled(model.isFetching || model.sources.allSatisfy { !$0.enabled })
        }
    }

    /// "247 to decide", today's new ones and the ones waiting, and the verdicts as tiles.
    private var waiting: some View {
        let groups = model.groups(.inbox, query: Inbox.Query())
        func count(_ kind: Inbox.GroupKind) -> Int { groups.first { $0.kind == kind }?.jobs.count ?? 0 }
        let decide = count(.decide)
        var line: [String] = []
        let new = Inbox.newToday(inbox)
        if new > 0 { line.append("\(new) new today") }
        if model.waitingForAI > 0 { line.append("\(model.waitingForAI) waiting for the AI") }
        return card {
            Text("\(decide) to decide").font(TypeStyle.title1).foregroundStyle(Color(.ink)).monospacedDigit()
            if !line.isEmpty {
                Text(line.joined(separator: " · ")).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            }
            HStack(spacing: Spacing.space2) {
                ForEach(Verdict.allCases, id: \.self) { verdict in
                    tile(verdict, inbox.count { $0.verdict == verdict })
                }
            }
        }
    }

    /// A verdict's count on its tint, with the icon and the word: never colour alone.
    private func tile(_ verdict: Verdict, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(verdict.title, systemImage: verdict.symbol).font(TypeStyle.caption)
                .foregroundStyle(verdictColor(verdict))
            Text("\(count)").font(TypeStyle.title2).foregroundStyle(Color(.ink)).monospacedDigit()
        }
        .padding(.horizontal, Spacing.space3)
        .padding(.vertical, Spacing.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(verdictBackground(verdict)))
    }

    private func verdictColor(_ verdict: Verdict) -> Color {
        switch verdict {
        case .yes: Color(.yes)
        case .maybe: Color(.maybe)
        case .no: Color(.no)
        }
    }

    private func verdictBackground(_ verdict: Verdict) -> Color {
        switch verdict {
        case .yes: Color(.yesBg)
        case .maybe: Color(.maybeBg)
        case .no: Color(.noBg)
        }
    }

    /// The three newest jobs seen today, best first.
    private var newest: [Job] {
        let today = inbox.filter { Calendar.current.isDateInToday($0.firstSeenAt) && $0.verdict != .no }
        return Array(Inbox.sorted(today, by: .match, countries: model.searchPreferences.countries).prefix(3))
    }

    private var newToday: some View {
        card {
            HStack(alignment: .firstTextBaseline) {
                Text("New today").font(TypeStyle.headline).foregroundStyle(Color(.ink))
                Spacer()
                Button("See all \(Inbox.newToday(inbox))") { open(nil) }
                    .buttonStyle(.plain).foregroundStyle(Color(.accentText)).font(TypeStyle.callout)
            }
            ForEach(newest) { job in
                Button {
                    open(job.id)
                } label: {
                    HStack(spacing: Spacing.space2) {
                        if let verdict = job.verdict {
                            Image(systemName: verdict.symbol).foregroundStyle(verdictColor(verdict))
                                .accessibilityLabel(verdict.title)
                        }
                        Text(job.title).font(TypeStyle.body).foregroundStyle(Color(.ink)).lineLimit(1)
                        Text("· \(job.company)").font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                            .lineLimit(1)
                        Spacer(minLength: Spacing.space2)
                        Text(model.matchScore(for: job).map(String.init) ?? "—").font(TypeStyle.scoreSmall)
                            .foregroundStyle(Color(.ink))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// What Kairos is doing now, or when it last checked: the same line as the sidebar's footer.
    private var running: some View {
        let status = model.runStatus
        return card {
            HStack(alignment: .firstTextBaseline) {
                Text(status.title).font(TypeStyle.headline).foregroundStyle(Color(.ink)).lineLimit(1)
                Spacer()
                if status.kind == .fetching || status.kind == .screening {
                    Button("Stop") { model.stopFetch() }
                        .buttonStyle(.plain).foregroundStyle(Color(.accentText)).font(TypeStyle.callout)
                }
            }
            if let fraction = status.fraction {
                ProgressMeter(fraction: fraction, stopped: status.kind == .stoppedEarly)
            }
            if let detail = status.detail {
                Text(detail).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).lineLimit(2)
            }
        }
    }

    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space2) { content() }
            .padding(Spacing.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.group).fill(Color(.surface)))
            .overlay(RoundedRectangle(cornerRadius: Radius.group).strokeBorder(Color(.separator), lineWidth: 1))
    }

    /// Brings Kairos to the front, at the Inbox, on `job` when given.
    private func open(_ job: JobID?) {
        if let job { model.selectedJob = job }
        model.section = .inbox
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
