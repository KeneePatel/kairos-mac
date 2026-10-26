import Store
import SwiftUI

/// Interviews (ADR-016, restyled for UI v2): the applications that moved past Applied, as a board
/// of Screen, Interview and Offer, with the chosen application beside it. Everything you sent,
/// waiting or closed, is in Applied. The board scrolls both ways, so a long column never sets
/// the window's height.
struct InterviewsView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [JobID] = []

    static let columns: [ApplicationStatus] = [.screen, .interview, .offer]

    private var moving: [Application] { model.applications.filter { $0.status.stage == .inProgress } }

    var body: some View {
        NavigationStack(path: $path) {
            ListPaneLayout(listWidth: 680) {
                board
            } pane: {
                if let id = model.selectedApplication, let application = model.application(id),
                    application.status.stage == .inProgress
                {
                    ApplicationPane(id: id) { path.append($0) }
                } else {
                    paneEmpty
                }
            }
            .navigationTitle("Interviews")
            .navigationDestination(for: JobID.self) { JobScreen(id: $0) }
        }
        .task(id: moving.map(\.id)) {
            if model.selectedApplication.flatMap({ model.application($0) }).map({ $0.status.stage != .inProgress })
                ?? true
            {
                model.selectedApplication = moving.first?.id
            }
        }
    }

    private var board: some View {
        VStack(spacing: 0) {
            ColumnTitle(title: "Interviews", line: countLine)
            if moving.isEmpty {
                VStack(spacing: Spacing.space2) {
                    Text("No interviews yet").font(TypeStyle.title2).foregroundStyle(Color(.ink))
                    Text("When a company replies, move its application to Screen, Interview or Offer in Applied.")
                        .font(TypeStyle.body).foregroundStyle(Color(.inkSecondary)).multilineTextAlignment(.center)
                    Button("Open Applied") { model.section = .applied }.padding(.top, Spacing.space2)
                }
                .padding(Spacing.space7)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    HStack(alignment: .top, spacing: Spacing.space3) {
                        ForEach(Self.columns, id: \.self) { status in column(status) }
                    }
                    .padding(Spacing.space4)
                }
                .defaultScrollAnchor(.topLeading)
                .background(Color(.surfaceSunken))
                .clipShape(RoundedRectangle(cornerRadius: Radius.group))
                .padding(.horizontal, Spacing.space6)
                .padding(.bottom, Spacing.space6)
            }
        }
    }

    /// "5 in progress · 1 follow-up due today · 32 waiting in Applied".
    private var countLine: String {
        let now = Date()
        let due = moving.count { $0.nextActionAt.map { Calendar.current.isDateInToday($0) || $0 < now } ?? false }
        var parts = ["\(moving.count) in progress"]
        if due > 0 { parts.append("\(due) follow-up\(due == 1 ? "" : "s") due today") }
        let waiting = model.applications.count { $0.status.stage == .waiting }
        if waiting > 0 { parts.append("\(waiting) waiting in Applied") }
        return parts.joined(separator: " · ")
    }

    private func column(_ status: ApplicationStatus) -> some View {
        let applications = moving.filter { $0.status == status }
        return VStack(alignment: .leading, spacing: Spacing.space2) {
            HStack {
                Label(status.title, systemImage: status.symbol).font(TypeStyle.headline).foregroundStyle(Color(.ink))
                Spacer()
                Text("\(applications.count)").font(TypeStyle.callout).monospacedDigit()
                    .foregroundStyle(Color(.inkSecondary))
            }
            .padding(.bottom, Spacing.space1)
            ForEach(applications) { application in
                Button {
                    model.selectedApplication = application.id
                } label: {
                    ApplicationCard(
                        application: application, job: model.job(application.jobID),
                        selected: model.selectedApplication == application.id)
                }
                .buttonStyle(.plain)
            }
            if applications.isEmpty {
                Text("None").font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            }
        }
        .frame(width: 200, alignment: .topLeading)
    }

    private var paneEmpty: some View {
        VStack(spacing: Spacing.space1) {
            Text("Nothing selected").font(TypeStyle.title2).foregroundStyle(Color(.ink))
            Text("Choose a card on the board.").font(TypeStyle.body).foregroundStyle(Color(.inkSecondary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One application on the board: company, role, and where it stands or what's due. A hairline
/// card on the board's ground; the chosen one carries the accent outline.
private struct ApplicationCard: View {
    let application: Application
    let job: Job?
    var selected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(job?.company ?? "A job no longer listed").font(TypeStyle.headline).foregroundStyle(Color(.ink))
                .lineLimit(1)
            Text(job?.title ?? "").font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).lineLimit(2)
            line
        }
        .padding(Spacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Color(.surface)))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card)
                .strokeBorder(selected ? Color(.accent) : Color(.separator), lineWidth: selected ? 2 : 1)
        )
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
