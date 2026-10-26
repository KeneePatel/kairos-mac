import AppKit
import Store
import SwiftUI

/// Applied (ADR-016, restyled for UI v2): every job you applied to, in a table you sort by any
/// column and search by company or role, with the chosen application beside it. Waiting, In
/// progress and Closed show each stage apart. Select several to move them together. Applications
/// still waiting a month after they went out can be closed as No reply in one step, after you
/// confirm.
struct AppliedView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [JobID] = []
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
            ListPaneLayout(listWidth: 640) {
                list
            } pane: {
                if let id = model.selectedApplication, model.application(id) != nil {
                    ApplicationPane(id: id) { path.append($0) }
                } else {
                    paneEmpty
                }
            }
            .navigationTitle("Applied")
            .searchable(text: $search, placement: .toolbar, prompt: "Company or role")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    scopePicker
                    Menu {
                        Button("Close \(silent.count) silent application\(silent.count == 1 ? "" : "s")…") {
                            closingSilent = true
                        }
                        .disabled(silent.isEmpty)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .help("Close applications with no reply for \(Application.silentAfterDays) days")
                }
            }
            .navigationDestination(for: JobID.self) { JobScreen(id: $0) }
        }
        .onChange(of: selection) { _, ids in
            if ids.count == 1, let id = ids.first { model.selectedApplication = id }
        }
        .task(id: model.applications.map(\.id)) {
            if model.selectedApplication.map({ model.application($0) == nil }) ?? true {
                model.selectedApplication = rows.first?.id
            }
            if let id = model.selectedApplication, selection != [id] { selection = [id] }
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

    // MARK: - The table

    private var list: some View {
        VStack(spacing: 0) {
            ColumnTitle(title: "Applied", line: countLine)
            if model.applications.isEmpty {
                empty("No applications yet", "Press A on a resume, or Mark applied on a job, and it shows up here.")
            } else if rows.isEmpty {
                empty(
                    search.isEmpty ? "Nothing \(scope.title.lowercased())" : "No matches",
                    search.isEmpty ? "Choose another scope above." : "Nothing here matches the search.")
            } else {
                table
            }
            Divider()
            Text("↑↓ move · ↩ open the job · O posting · select several, then Move to in the menu")
                .font(TypeStyle.caption).foregroundStyle(Color(.inkSecondary)).lineLimit(1)
                .padding(.horizontal, Spacing.space6).padding(.vertical, Spacing.space3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Company", value: \.company) { row in
                Text(row.company).font(TypeStyle.headline).foregroundStyle(ink(row)).lineLimit(1)
            }
            .width(min: 120, ideal: 160)
            TableColumn("Role", value: \.title) { row in
                Text(row.title).foregroundStyle(ink2(row)).lineLimit(1)
            }
            .width(min: 140, ideal: 220)
            TableColumn("Applied", value: \.appliedAt) { row in
                Text(row.appliedAt.formatted(.dateTime.month(.abbreviated).day())).monospacedDigit()
                    .foregroundStyle(ink2(row))
            }
            .width(min: 56, ideal: 64)
            TableColumn("Status", value: \.statusOrder) { row in
                Label(row.status.title, systemImage: row.status.symbol).foregroundStyle(ink(row)).lineLimit(1)
            }
            .width(min: 96, ideal: 112)
            TableColumn("Follow-up", value: \.followUpOrder) { row in
                if let due = row.followUp {
                    let today = Calendar.current.isDateInToday(due) || due < Date()
                    Label(
                        today ? "Today" : due.formatted(.dateTime.weekday(.abbreviated).month().day()),
                        systemImage: "bell"
                    )
                    .foregroundStyle(today ? Color(.maybe) : Color(.inkSecondary)).lineLimit(1)
                } else if row.silent {
                    Label("\(row.days) days, no reply", systemImage: "clock").foregroundStyle(Color(.maybe))
                        .lineLimit(1)
                } else {
                    Text("—").foregroundStyle(Color(.inkSecondary))
                }
            }
            .width(min: 88, ideal: 112)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first, let job = model.application(id).flatMap({ model.job($0.jobID) }) {
                path.append(job.id)
            }
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "oO")) { _ in
            guard let id = model.selectedApplication, let job = model.application(id).flatMap({ model.job($0.jobID) })
            else { return .ignored }
            model.openPosting(job)
            return .handled
        }
    }

    private func ink(_ row: AppliedRow) -> Color { row.status.isClosed ? Color(.inkDimmed) : Color(.ink) }
    private func ink2(_ row: AppliedRow) -> Color { row.status.isClosed ? Color(.inkDimmed) : Color(.ink2) }

    /// Open one, its job or its posting; move every chosen row to a status.
    @ViewBuilder private func menu(for ids: Set<UUID>) -> some View {
        let chosen = model.applications.filter { ids.contains($0.id) }
        if chosen.count == 1, let application = chosen.first, let job = model.job(application.jobID) {
            Button("Open the job") { path.append(job.id) }
            Button("Open posting") { model.openPosting(job) }
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

    /// "38 applications · 32 waiting · 3 in progress · 3 closed".
    private var countLine: String {
        let all = model.applications
        let waiting = all.count { $0.status.stage == .waiting }
        let progress = all.count { $0.status.stage == .inProgress }
        let closed = all.count { $0.status.stage == .closed }
        let today = all.count { Calendar.current.isDateInToday($0.appliedAt) }
        var parts = ["\(all.count) application\(all.count == 1 ? "" : "s")"]
        if today > 0 { parts.append("\(today) today") }
        parts.append("\(waiting) waiting")
        if progress > 0 { parts.append("\(progress) in progress") }
        if closed > 0 { parts.append("\(closed) closed") }
        return parts.joined(separator: " · ")
    }

    private func empty(_ title: String, _ line: String) -> some View {
        VStack(spacing: Spacing.space2) {
            Text(title).font(TypeStyle.title2).foregroundStyle(Color(.ink))
            Text(line).font(TypeStyle.body).foregroundStyle(Color(.inkSecondary)).multilineTextAlignment(.center)
        }
        .padding(Spacing.space7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var paneEmpty: some View {
        VStack(spacing: Spacing.space1) {
            Text("Nothing selected").font(TypeStyle.title2).foregroundStyle(Color(.ink))
            Text("Choose an application in the table.").font(TypeStyle.body).foregroundStyle(Color(.inkSecondary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
