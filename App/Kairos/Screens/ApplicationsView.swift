import Store
import SwiftUI

/// Applications (T45, story 6): a board of the jobs you applied to, Applied, Screen, Interview,
/// Offer and Closed, after `Applications.dc.html`. Choosing one opens it full width (no side panel,
/// as you asked for jobs in polish P3): its status, timeline, follow-up and notes.
struct ApplicationsView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [Route] = []

    enum Route: Hashable {
        case application(UUID)
        case job(JobID)
    }

    /// The board's columns: the four open steps, then everything closed.
    enum Column: CaseIterable {
        case applied, screen, interview, offer, closed

        var title: String {
            switch self {
            case .applied: "Applied"
            case .screen: "Screen"
            case .interview: "Interview"
            case .offer: "Offer"
            case .closed: "Closed"
            }
        }

        func holds(_ status: ApplicationStatus) -> Bool {
            switch self {
            case .applied: status == .applied
            case .screen: status == .screen
            case .interview: status == .interview
            case .offer: status == .offer
            case .closed: status.isClosed
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Applications")
                .navigationSubtitle(subtitle)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .application(let id): ApplicationScreen(id: id)
                    case .job(let id): JobScreen(id: id)
                    }
                }
        }
    }

    @ViewBuilder private var content: some View {
        if model.applications.isEmpty {
            ContentUnavailableView {
                Label("No applications yet", systemImage: "paperplane")
            } description: {
                Text("When you apply to a job, choose Mark applied on its page or its build. It shows up here.")
                    .foregroundStyle(Color(.inkSecondary))
            }
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Spacing.space4) {
                    ForEach(Column.allCases, id: \.self) { column in
                        self.column(column)
                    }
                }
                .padding(Spacing.space5)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .background(Color(.surface))
        }
    }

    /// "9 active · 3 closed · 2 follow-ups due this week".
    private var subtitle: String {
        let closed = model.applications.filter(\.status.isClosed).count
        let week = Date().addingTimeInterval(7 * 86_400)
        let due = model.applications.filter { !$0.status.isClosed && ($0.nextActionAt.map { $0 <= week } ?? false) }
        var parts = ["\(model.applications.count - closed) active", "\(closed) closed"]
        if !due.isEmpty { parts.append("\(due.count) follow-up\(due.count == 1 ? "" : "s") due this week") }
        return parts.joined(separator: " · ")
    }

    private func column(_ column: Column) -> some View {
        let applications = model.applications.filter { column.holds($0.status) }
        return VStack(alignment: .leading, spacing: Spacing.space3) {
            HStack {
                Text(column.title).font(TypeStyle.headline).foregroundStyle(Color(.ink))
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
        .background(RoundedRectangle(cornerRadius: Radius.row).fill(Color(.surfaceGrouped)))
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

/// One application, full width: where it stands, its timeline, a follow-up and your notes.
struct ApplicationScreen: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    @State private var events: [ApplicationEvent] = []
    @State private var timelineNote = ""
    @State private var followUpDate = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var followUpText = ""
    @State private var notes = ""
    @State private var deleting = false

    private var application: Application? { model.application(id) }

    /// `preview` fills the timeline for snapshots, which have no database.
    init(id: UUID, preview: [ApplicationEvent] = []) {
        self.id = id
        _events = State(initialValue: preview)
    }

    var body: some View {
        Group {
            if let application {
                page(application)
            } else {
                ContentUnavailableView("This application is gone", systemImage: "questionmark.folder")
            }
        }
        .background(Color(.surface))
        .navigationTitle(application.flatMap { model.job($0.jobID)?.title } ?? "Application")
        .navigationSubtitle(application.flatMap { model.job($0.jobID)?.company } ?? "")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    deleting = true
                } label: {
                    Label("Delete application", systemImage: "trash")
                }
                .help("Forgets this application and its timeline. The job goes back to new.")
            }
        }
        .confirmationDialog("Delete this application?", isPresented: $deleting) {
            Button("Delete application", role: .destructive) {
                if let application { Task { await model.delete(application) } }
            }
        } message: {
            Text("Its status, timeline, follow-up and notes are deleted. The job stays.")
        }
        .task(id: application?.statusAt) {
            if let application {
                let loaded = await model.events(for: application)
                if !loaded.isEmpty { events = loaded }  // every application has at least "Applied"
                notes = application.notes
                followUpText = application.nextAction ?? ""
                if let due = application.nextActionAt { followUpDate = due }
            }
        }
    }

    private func page(_ application: Application) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.space6) {
                header(application)
                status(application)
                followUp(application)
                timeline(application)
                notesSection(application)
            }
            .padding(Spacing.space6)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func header(_ application: Application) -> some View {
        let job = model.job(application.jobID)
        return VStack(alignment: .leading, spacing: Spacing.space1) {
            Text(job?.company ?? "A job no longer listed").font(TypeStyle.callout)
                .foregroundStyle(Color(.inkSecondary))
            Text(job?.title ?? "Application").font(TypeStyle.title2).foregroundStyle(Color(.ink))
            HStack(spacing: Spacing.space3) {
                Text(
                    [
                        job.map { $0.location.isEmpty ? $0.placeLabel : $0.location },
                        "Applied \(application.appliedAt.formatted(date: .abbreviated, time: .omitted))"
                            + (application.channel.map { " via \($0)" } ?? ""),
                    ].compactMap { $0 }.joined(separator: " · ")
                )
                .font(TypeStyle.callout).foregroundStyle(Color(.ink2))
                if let job {
                    NavigationLink(value: ApplicationsView.Route.job(job.id)) {
                        Label("Open the job", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.link)
                    .font(TypeStyle.callout)
                    if let url = URL(string: job.url) {
                        Link(destination: url) { Label("Open posting", systemImage: "arrow.up.right.square") }
                            .font(TypeStyle.callout)
                    }
                }
            }
        }
    }

    /// Where it stands, and a menu to move it.
    private func status(_ application: Application) -> some View {
        HStack(alignment: .center, spacing: Spacing.space4) {
            Label(application.status.title, systemImage: application.status.symbol)
                .font(TypeStyle.headline).foregroundStyle(Color(.ink))
            Text("since \(application.statusAt.formatted(date: .abbreviated, time: .omitted))")
                .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            Spacer()
            Menu {
                ForEach(ApplicationStatus.allCases, id: \.self) { status in
                    Button {
                        Task { await model.setStatus(status, for: application) }
                    } label: {
                        Label(status.title, systemImage: status.symbol)
                    }
                    .disabled(status == application.status)
                }
            } label: {
                Label("Move to", systemImage: "arrow.right.circle")
            }
            .fixedSize()
        }
        .padding(Spacing.space4)
        .background(RoundedRectangle(cornerRadius: Radius.row).fill(Color(.surfaceGrouped)))
    }

    private func followUp(_ application: Application) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Text("Follow-up").font(TypeStyle.title3).foregroundStyle(Color(.ink))
            if let due = application.nextActionAt {
                Label(
                    "\(application.nextAction ?? "Follow up") · \(due.formatted(date: .complete, time: .shortened))",
                    systemImage: "bell"
                )
                .font(TypeStyle.body).foregroundStyle(Color(.ink2))
            } else {
                Text("No reminder set. Kairos notifies you at the time you choose, even when it's closed.")
                    .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            }
            HStack(spacing: Spacing.space3) {
                TextField("What to do", text: $followUpText, prompt: Text("Email the recruiter"))
                    .textFieldStyle(.roundedBorder)
                DatePicker("When", selection: $followUpDate, in: Date()...).labelsHidden().fixedSize()
                Button(application.nextActionAt == nil ? "Set reminder" : "Change") {
                    Task { await model.setFollowUp(followUpDate, followUpText, for: application) }
                }
                if application.nextActionAt != nil {
                    Button("Clear") { Task { await model.setFollowUp(nil, nil, for: application) } }
                }
            }
        }
    }

    private func timeline(_ application: Application) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Text("Timeline").font(TypeStyle.title3).foregroundStyle(Color(.ink))
            VStack(alignment: .leading, spacing: Spacing.space3) {
                ForEach(events) { event in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.space3) {
                        Image(systemName: event.symbol).foregroundStyle(Color(.inkSecondary)).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: Spacing.space2) {
                                Text(event.title).font(TypeStyle.headline).foregroundStyle(Color(.ink))
                                Text(event.at.formatted(date: .abbreviated, time: .omitted)).font(TypeStyle.callout)
                                    .foregroundStyle(Color(.inkSecondary))
                            }
                            if let note = event.note {
                                Text(note).font(TypeStyle.body).foregroundStyle(Color(.ink2))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                HStack(spacing: Spacing.space3) {
                    TextField(
                        "Add to the timeline", text: $timelineNote, prompt: Text("Recruiter call, 30 min")
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addNote(application) }
                    Button("Add") { addNote(application) }
                        .disabled(timelineNote.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(Spacing.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.row).fill(Color(.surfaceGrouped)))
        }
    }

    private func notesSection(_ application: Application) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Text("Notes").font(TypeStyle.title3).foregroundStyle(Color(.ink))
            TextEditor(text: $notes)
                .font(TypeStyle.body)
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(Spacing.space2)
                .background(RoundedRectangle(cornerRadius: Radius.row).fill(Color(.surfaceGrouped)))
                // Saved a moment after you stop typing.
                .task(id: notes) {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    await model.setNotes(notes, for: application)
                }
        }
    }

    private func addNote(_ application: Application) {
        let note = timelineNote
        timelineNote = ""
        Task {
            await model.addNote(note, to: application)
            events = await model.events(for: application)
        }
    }
}

extension ApplicationStatus {
    var title: String {
        switch self {
        case .applied: "Applied"
        case .screen: "Screen"
        case .interview: "Interview"
        case .offer: "Offer"
        case .accepted: "Accepted"
        case .rejected: "Not selected"
        case .ghosted: "No reply"
        case .withdrawn: "You withdrew"
        }
    }

    var symbol: String {
        switch self {
        case .applied: "paperplane"
        case .screen: "phone"
        case .interview: "person.2"
        case .offer: "gift"
        case .accepted: "checkmark.seal"
        case .rejected: "xmark.circle"
        case .ghosted: "questionmark.circle"
        case .withdrawn: "arrow.uturn.backward.circle"
        }
    }
}

extension ApplicationEvent {
    var title: String {
        switch kind {
        case .status(let status): status.title
        case .note: "Note"
        }
    }

    var symbol: String {
        switch kind {
        case .status(let status): status.symbol
        case .note: "note.text"
        }
    }
}
