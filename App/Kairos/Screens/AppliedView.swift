import AppKit
import Store
import SwiftUI

/// Applied (ADR-016): every job you applied to, in a table you sort by any column and search by
/// company or role. Waiting, In progress and Closed show each stage apart. Select several to move
/// them together, or open one for its timeline, follow-up and notes. Applications still waiting a
/// month after they went out can be closed as No reply in one step, after you confirm.
struct AppliedView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [ApplicationRoute] = []
    @State private var scope = Scope.all
    @State private var search = ""
    @State private var selection: Set<UUID> = []
    @State private var sortOrder = [KeyPathComparator(\AppliedRow.appliedAt, order: .reverse)]
    @State private var closingSilent = false

    enum Scope: CaseIterable, Identifiable {
        case all, waiting, inProgress, closed
        var id: Self { self }

        var title: String {
            switch self {
            case .all: "All"
            case .waiting: "Waiting"
            case .inProgress: "In progress"
            case .closed: "Closed"
            }
        }

        func holds(_ status: ApplicationStatus) -> Bool {
            switch self {
            case .all: true
            case .waiting: status.stage == .waiting
            case .inProgress: status.stage == .inProgress
            case .closed: status.stage == .closed
            }
        }
    }

    /// Everything a row shows, read from the model here and not in the table's cells: cells that
    /// read the model made SwiftUI abort when the screen changed (2026-10-26).
    private var rows: [AppliedRow] {
        let now = Date()
        return model.applications.compactMap { application in
            guard scope.holds(application.status) else { return nil }
            let job = model.job(application.jobID)
            let row = AppliedRow(
                application: application, company: job?.company ?? "A job no longer listed", title: job?.title ?? "",
                silent: application.isSilent(at: now))
            return row.matches(search) ? row : nil
        }
        .sorted(using: sortOrder)
    }

    private var silent: [Application] { model.applications.filter { $0.isSilent(at: Date()) } }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Applied")
                .navigationSubtitle(subtitle)
                .searchable(text: $search, placement: .toolbar, prompt: "Company or role")
                .toolbar {
                    ToolbarItem(placement: .principal) { scopePicker }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            closingSilent = true
                        } label: {
                            Label("Close silent…", systemImage: "clock.badge.xmark").labelStyle(.titleAndIcon)
                        }
                        .disabled(silent.isEmpty)
                        .help(
                            "Moves applications with no reply \(Application.silentAfterDays) days after you sent them to No reply. You can move any of them back."
                        )
                    }
                }
                .navigationDestination(for: ApplicationRoute.self) { route in
                    switch route {
                    case .application(let id): ApplicationScreen(id: id)
                    case .job(let id): JobScreen(id: id)
                    }
                }
        }
        .confirmationDialog(
            "Close \(silent.count) silent application\(silent.count == 1 ? "" : "s")?", isPresented: $closingSilent,
            titleVisibility: .visible
        ) {
            Button("Move \(silent.count) to No reply") {
                Task { await model.setStatus(.ghosted, for: silent) }
            }
        } message: {
            Text(
                "\(silent.count == 1 ? "It has" : "They have") waited \(Application.silentAfterDays) days or more without a reply. Few replies come after two weeks. If a company writes later, open the application and move it on."
            )
        }
    }

    @ViewBuilder private var content: some View {
        if model.applications.isEmpty {
            ContentUnavailableView {
                Label("No applications yet", systemImage: "paperplane")
            } description: {
                Text("When you apply to a job, choose Mark applied on its page or its resume. It shows up here.")
                    .foregroundStyle(Color(.inkSecondary))
            }
        } else if rows.isEmpty, !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            table
        }
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Company", value: \.company) { row in
                Text(row.company).font(TypeStyle.headline).foregroundStyle(Color(.ink)).lineLimit(1)
            }
            .width(min: 140, ideal: 200)
            TableColumn("Role", value: \.title) { row in
                Text(row.title).foregroundStyle(Color(.ink2)).lineLimit(1)
            }
            .width(min: 180, ideal: 320)
            TableColumn("Applied", value: \.appliedAt) { row in
                Text(row.appliedAt.formatted(date: .abbreviated, time: .omitted)).monospacedDigit()
                    .foregroundStyle(Color(.ink2))
            }
            .width(min: 90, ideal: 110)
            TableColumn("Status", value: \.statusOrder) { row in
                Label(row.status.title, systemImage: row.status.symbol).foregroundStyle(Color(.ink))
            }
            .width(min: 110, ideal: 130)
            TableColumn("Last change", value: \.statusAt) { row in
                if row.silent {
                    Label("\(row.days) days, no reply", systemImage: "clock").foregroundStyle(Color(.maybe))
                } else {
                    Text(row.lastChange).foregroundStyle(Color(.inkSecondary))
                }
            }
            .width(min: 110, ideal: 140)
            TableColumn("Follow-up", value: \.followUpOrder) { row in
                if let due = row.followUp {
                    let today = Calendar.current.isDateInToday(due) || due < Date()
                    Label(
                        today ? "Today" : due.formatted(.dateTime.weekday(.abbreviated).month().day()),
                        systemImage: "bell"
                    )
                    .foregroundStyle(today ? Color(.maybe) : Color(.inkSecondary))
                } else {
                    Text("—").foregroundStyle(Color(.inkSecondary))
                }
            }
            .width(min: 90, ideal: 110)
            TableColumn("Via", value: \.channel) { row in
                Text(row.channel).foregroundStyle(Color(.inkSecondary)).lineLimit(1)
            }
            .width(min: 80, ideal: 110)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first { path.append(.application(id)) }
        }
    }

    /// Open one, its job or its posting; move every chosen row to a status.
    @ViewBuilder private func menu(for ids: Set<UUID>) -> some View {
        let chosen = model.applications.filter { ids.contains($0.id) }
        if chosen.count == 1, let application = chosen.first {
            Button("Open") { path.append(.application(application.id)) }
            if let job = model.job(application.jobID) {
                Button("Open the job") { path.append(.job(job.id)) }
                if let url = URL(string: job.url) {
                    Button("Open posting") { NSWorkspace.shared.open(url) }
                }
            }
            Divider()
        }
        if !chosen.isEmpty {
            Menu(chosen.count == 1 ? "Move to" : "Move \(chosen.count) to") {
                ForEach(ApplicationStatus.allCases, id: \.self) { status in
                    Button {
                        Task { await model.setStatus(status, for: chosen) }
                    } label: {
                        Label(status.title, systemImage: status.symbol)
                    }
                }
            }
        }
    }

    private var scopePicker: some View {
        Picker("Show", selection: $scope) {
            ForEach(Scope.allCases) { scope in
                Text("\(scope.title) \(model.applications.count { scope.holds($0.status) })").tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .monospacedDigit()
        .fixedSize()
    }

    /// "13 sent today · 36 this week · 36 in all".
    private var subtitle: String {
        let calendar = Calendar.current
        let today = model.applications.count { calendar.isDateInToday($0.appliedAt) }
        let week = model.applications.count { $0.appliedAt > Date().addingTimeInterval(-7 * 86_400) }
        return "\(today) sent today · \(week) this week · \(model.applications.count) in all"
    }
}

/// One row of Applied: an application and what its cells show, sortable by each column.
struct AppliedRow: Identifiable {
    let application: Application
    let company: String
    let title: String
    /// Still Applied a month after it went out.
    let silent: Bool

    var id: UUID { application.id }
    var status: ApplicationStatus { application.status }
    var appliedAt: Date { application.appliedAt }
    var statusAt: Date { application.statusAt }
    var followUp: Date? { application.nextActionAt }
    var channel: String { application.channel ?? "" }
    /// The steps in order, Applied first and the closed ones last.
    var statusOrder: Int { ApplicationStatus.allCases.firstIndex(of: status) ?? 0 }
    /// Rows without a follow-up sort after every date.
    var followUpOrder: Date { followUp ?? .distantFuture }
    var days: Int { max(0, Int(Date().timeIntervalSince(statusAt) / 86_400)) }

    /// "Today", "Yesterday", "12 days ago".
    var lastChange: String {
        if Calendar.current.isDateInToday(statusAt) { return "Today" }
        if Calendar.current.isDateInYesterday(statusAt) { return "Yesterday" }
        return "\(max(2, days)) days ago"
    }

    /// The company or the role holds every word you typed, ignoring case and accents.
    func matches(_ search: String) -> Bool {
        let words = search.split(whereSeparator: \.isWhitespace)
        let text = "\(company) \(title)"
        return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
