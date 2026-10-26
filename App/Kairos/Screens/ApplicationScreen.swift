import Store
import SwiftUI

/// Where Applied and the Interviews board go from a row or a card when a job opens full width.
enum ApplicationRoute: Hashable {
    case application(UUID)
    case job(JobID)
}

/// One application (UI v2): the pane beside the Applied table and the Interviews board. Where it
/// stands with Move to, the follow-up, the timeline, your notes, and the job it came from.
struct ApplicationPane: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    /// Full width: the same pane with room.
    var full = false
    /// Opens the job full width (the list's navigation stack owns the path).
    var openJob: (JobID) -> Void = { _ in }
    @State private var events: [ApplicationEvent] = []
    @State private var timelineNote = ""
    @State private var followUpDate = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var followUpText = ""
    @State private var editingFollowUp = false
    @State private var notes = ""
    @State private var deleting = false

    /// `preview` fills the timeline for snapshots, which have no database.
    init(id: UUID, full: Bool = false, preview: [ApplicationEvent] = [], openJob: @escaping (JobID) -> Void = { _ in })
    {
        self.id = id
        self.full = full
        self.openJob = openJob
        _events = State(initialValue: preview)
    }

    private var application: Application? { model.application(id) }

    var body: some View {
        Group {
            if let application {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.space6) {
                        header(application)
                        status(application)
                        timeline(application)
                        notesSection(application)
                    }
                    .padding(.horizontal, Spacing.space7)
                    .padding(.vertical, Spacing.space6)
                    .frame(maxWidth: full ? 920 : .infinity, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            } else {
                ContentUnavailableView("This application is gone", systemImage: "questionmark.folder")
            }
        }
        .background(Color(.surface))
        .confirmationDialog("Delete this application?", isPresented: $deleting) {
            Button("Delete application", role: .destructive) {
                if let application { Task { await model.delete(application) } }
            }
        } message: {
            Text("Its status, timeline, follow-up and notes are deleted. The job stays, as new.")
        }
        .task(id: "\(id.uuidString)-\(application?.statusAt.timeIntervalSince1970 ?? 0)") {
            if let application {
                let loaded = await model.events(for: application)
                if !loaded.isEmpty { events = loaded }  // every application has at least "Applied"
                notes = application.notes
                followUpText = application.nextAction ?? ""
                if let due = application.nextActionAt { followUpDate = due }
                editingFollowUp = false
            }
        }
    }

    // MARK: - Header and actions

    private func header(_ application: Application) -> some View {
        let job = model.job(application.jobID)
        return VStack(alignment: .leading, spacing: Spacing.space1) {
            Text(
                job.map { $0.company + (model.source($0.sourceID).map { " · via \($0.kind.displayName)" } ?? "") }
                    ?? "A job no longer listed"
            )
            .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            Text(job?.title ?? "Application").font(TypeStyle.title1).foregroundStyle(Color(.ink))
            Text(
                [
                    job.map { $0.location.isEmpty ? $0.placeLabel : $0.location },
                    "Applied \(application.appliedAt.formatted(date: .abbreviated, time: .omitted))"
                        + (application.channel.map { " via \($0)" } ?? ""),
                    application.buildID.map { _ in "with a tailored resume" },
                ].compactMap { $0 }.filter { $0 != "—" }.joined(separator: " · ")
            )
            .font(TypeStyle.callout).foregroundStyle(Color(.ink2))
            HStack(spacing: Spacing.space2) {
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
                    Label(application.status.title, systemImage: application.status.symbol)
                }
                .menuStyle(.button)
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .help("Move this application to another step")
                if let job {
                    Button {
                        openJob(job.id)
                    } label: {
                        ActionLabel(title: "Open job", key: "↩")
                    }
                    .help("The job with its verdict and requirements")
                    Button {
                        model.openPosting(job)
                    } label: {
                        ActionLabel(title: "Open posting", key: "O")
                    }
                    if let build = application.buildID ?? model.latestBuild(for: job)?.id {
                        Button("Resume") { model.showResume(build) }
                            .help("The resume you sent")
                    }
                }
                Menu {
                    Button("Delete application…", role: .destructive) { deleting = true }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.top, Spacing.space3)
        }
    }

    // MARK: - Status and follow-up

    /// Where it stands since when, and the follow-up: due in amber with a bell, with Done, Change
    /// and Clear; or a plain Set reminder.
    private func status(_ application: Application) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            HStack(alignment: .firstTextBaseline) {
                Label(application.status.title, systemImage: application.status.symbol)
                    .font(TypeStyle.headline).foregroundStyle(Color(.ink))
                Text("since \(application.statusAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                Spacer()
                if application.status == .applied, application.isSilent(at: Date()) {
                    Label("\(daysSince(application.statusAt)) days, no reply", systemImage: "clock")
                        .font(TypeStyle.callout).foregroundStyle(Color(.maybe))
                }
            }
            if editingFollowUp || (application.nextActionAt == nil && !application.status.isClosed && editingFollowUp) {
                followUpEditor(application)
            } else if let due = application.nextActionAt {
                let today = Calendar.current.isDateInToday(due) || due < Date()
                HStack(spacing: Spacing.space2) {
                    Label(
                        "\(application.nextAction ?? "Follow up") · \(today ? "due today" : due.formatted(.dateTime.weekday(.abbreviated).month().day().hour().minute()))",
                        systemImage: "bell"
                    )
                    .font(TypeStyle.callout).foregroundStyle(today ? Color(.maybe) : Color(.ink2))
                    Spacer()
                    Button("Done") { Task { await model.setFollowUp(nil, nil, for: application) } }
                        .buttonStyle(.plain).foregroundStyle(Color(.accentText)).font(TypeStyle.callout)
                    Button("Change") { editingFollowUp = true }
                        .buttonStyle(.plain).foregroundStyle(Color(.accentText)).font(TypeStyle.callout)
                }
            } else if !application.status.isClosed {
                Button("Set a follow-up reminder…") { editingFollowUp = true }
                    .buttonStyle(.plain).foregroundStyle(Color(.accentText)).font(TypeStyle.callout)
            }
        }
        .padding(Spacing.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Color(.surfaceRaised)))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Color(.separator), lineWidth: 1))
    }

    private func followUpEditor(_ application: Application) -> some View {
        HStack(spacing: Spacing.space2) {
            TextField("What to do", text: $followUpText, prompt: Text("Email the recruiter"))
                .textFieldStyle(.roundedBorder)
            DatePicker("When", selection: $followUpDate, in: Date()...).labelsHidden().fixedSize()
            Button(application.nextActionAt == nil ? "Set" : "Save") {
                Task { await model.setFollowUp(followUpDate, followUpText, for: application) }
                editingFollowUp = false
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel") { editingFollowUp = false }
        }
    }

    private func daysSince(_ date: Date) -> Int { max(0, Int(Date().timeIntervalSince(date) / 86_400)) }

    // MARK: - Timeline and notes

    private func timeline(_ application: Application) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            HStack(alignment: .firstTextBaseline) {
                Text("Timeline").font(TypeStyle.title2).foregroundStyle(Color(.ink))
                Spacer()
                Text("\(events.count) step\(events.count == 1 ? "" : "s")").font(TypeStyle.callout)
                    .foregroundStyle(Color(.inkSecondary)).monospacedDigit()
            }
            ForEach(events) { event in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
                    Image(systemName: event.symbol).foregroundStyle(Color(.inkSecondary)).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            "\(event.title) · \(event.at.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))"
                        )
                        .font(TypeStyle.body).foregroundStyle(Color(.ink))
                        if let note = event.note {
                            Text(note).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            HStack(spacing: Spacing.space2) {
                TextField("Add to the timeline", text: $timelineNote, prompt: Text("Recruiter call, 30 min"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addNote(application) }
                Button("Add") { addNote(application) }
                    .disabled(timelineNote.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func notesSection(_ application: Application) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Text("Notes").font(TypeStyle.title2).foregroundStyle(Color(.ink))
            TextEditor(text: $notes)
                .font(TypeStyle.body)
                .frame(minHeight: 96)
                .scrollContentBackground(.hidden)
                .padding(Spacing.space2)
                .background(RoundedRectangle(cornerRadius: Radius.card).fill(Color(.surfaceRaised)))
                .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Color(.separator), lineWidth: 1))
                // Saved a moment after you stop typing.
                .task(id: notes) {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, notes != application.notes else { return }
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

/// An application full width: the pane with room, where Interviews' cards and Applied's rows
/// used to go.
struct ApplicationScreen: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    private let preview: [ApplicationEvent]

    init(id: UUID, preview: [ApplicationEvent] = []) {
        self.id = id
        self.preview = preview
    }

    var body: some View {
        ApplicationPane(id: id, full: true, preview: preview) { job in
            model.selectedJob = job
            model.section = .inbox
        }
        .navigationTitle(model.application(id).flatMap { model.job($0.jobID)?.title } ?? "Application")
        .navigationSubtitle(model.application(id).flatMap { model.job($0.jobID)?.company } ?? "")
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
