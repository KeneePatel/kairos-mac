import Store
import SwiftUI

/// Interviews (ADR-016; T45's Applications board until 2026-10-26): the applications that moved
/// past Applied, as a board of Screen, Interview and Offer after `Applications.dc.html`. Everything
/// you sent, waiting or closed, is in Applied. Choosing a card opens it full width. The board
/// scrolls both ways, so a long column never sets the window's height: the five-column board's
/// Applied column of 36 cards asked for a window 3,409 points tall.
struct InterviewsView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [ApplicationRoute] = []

    static let columns: [ApplicationStatus] = [.screen, .interview, .offer]

    private var moving: [Application] { model.applications.filter { $0.status.stage == .inProgress } }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Interviews")
                .navigationSubtitle(subtitle)
                .navigationDestination(for: ApplicationRoute.self) { route in
                    switch route {
                    case .application(let id): ApplicationScreen(id: id)
                    case .job(let id): JobScreen(id: id)
                    }
                }
        }
    }

    @ViewBuilder private var content: some View {
        if moving.isEmpty {
            ContentUnavailableView {
                Label("No interviews yet", systemImage: "person.2")
            } description: {
                Text(
                    "When a company replies, find the job in Applied and move it to Screen, Interview or Offer. It shows up here."
                )
                .foregroundStyle(Color(.inkSecondary))
            } actions: {
                Button("Open Applied") { model.section = .applied }
            }
        } else {
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: Spacing.space4) {
                    ForEach(Self.columns, id: \.self) { status in column(status) }
                }
                .padding(Spacing.space5)
            }
            .defaultScrollAnchor(.topLeading)
            .background(Color(.surface))
        }
    }

    /// "3 in progress · 1 follow-up due this week".
    private var subtitle: String {
        let week = Date().addingTimeInterval(7 * 86_400)
        let due = moving.count { $0.nextActionAt.map { $0 <= week } ?? false }
        var parts = ["\(moving.count) in progress"]
        if due > 0 { parts.append("\(due) follow-up\(due == 1 ? "" : "s") due this week") }
        return parts.joined(separator: " · ")
    }

    private func column(_ status: ApplicationStatus) -> some View {
        let applications = moving.filter { $0.status == status }
        return VStack(alignment: .leading, spacing: Spacing.space3) {
            HStack {
                Label(status.title, systemImage: status.symbol).font(TypeStyle.headline).foregroundStyle(Color(.ink))
                Spacer()
                Text("\(applications.count)").font(TypeStyle.callout).monospacedDigit()
                    .foregroundStyle(Color(.inkSecondary))
            }
            ForEach(applications) { application in
                Button {
                    path.append(.application(application.id))
                } label: {
                    ApplicationCard(application: application, job: model.job(application.jobID))
                }
                .buttonStyle(.plain)
            }
            if applications.isEmpty {
                Text("None").font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            }
        }
        .frame(width: 250, alignment: .topLeading)
    }
}

/// One application on the board: company, role, and where it stands or what's due.
private struct ApplicationCard: View {
    let application: Application
    let job: Job?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            Text(job?.company ?? "A job no longer listed").font(TypeStyle.headline).foregroundStyle(Color(.ink))
                .lineLimit(1)
            Text(job?.title ?? "").font(TypeStyle.callout).foregroundStyle(Color(.ink2)).lineLimit(2)
            line
        }
        .padding(Spacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Color(.surfaceRaised)))
        .contentShape(Rectangle())
    }

    /// A due follow-up first, with its icon and word, never colour alone; otherwise the status.
    @ViewBuilder private var line: some View {
        if let due = application.nextActionAt, !application.status.isClosed {
            let today = Calendar.current.isDateInToday(due) || due < Date()
            Label(
                today ? "Follow up today" : "Follow up \(due.formatted(.dateTime.weekday(.abbreviated).month().day()))",
                systemImage: "bell"
            )
            .font(TypeStyle.callout).foregroundStyle(today ? Color(.maybe) : Color(.inkSecondary))
        } else {
            Text("\(application.status.title) · \(application.statusAt.formatted(.dateTime.month().day()))")
                .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
        }
    }
}
