import Engine
import Store
import SwiftUI

/// Applied: every application in a table, scoped Waiting, In progress, Closed or All, and the
/// selected one's pane.
struct AppliedView: View {
    enum Scope: String, CaseIterable {
        case waiting = "Waiting"
        case inProgress = "In progress"
        case closed = "Closed"
        case all = "All"

        func contains(_ status: Application.Status) -> Bool {
            switch self {
            case .waiting: status.isWaiting
            case .inProgress: status.isInProgress
            case .closed: status.isClosed
            case .all: true
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State private var scope = Scope.waiting
    @State private var order = [KeyPathComparator(\Row.applied, order: .reverse)]

    struct Row: Identifiable {
        let application: Application
        let title: String
        let company: String
        var id: UUID { application.id }
        var applied: Date { application.appliedAt }
        var status: String { application.status.title }
        var followUp: Date { application.followUpAt ?? .distantFuture }
    }

    var body: some View {
        @Bindable var model = model
        ListPaneLayout(listWidth: 560) {
            VStack(spacing: 0) {
                ColumnTitle(title: "Applied", line: line)
                Picker("Show", selection: $scope) {
                    ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, Spacing.space6)
                .padding(.bottom, Spacing.space3)
                Table(rows, selection: $model.selectedApplication, sortOrder: $order) {
                    TableColumn("Job", value: \.title) { row in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(row.title).font(TypeStyle.headline).lineLimit(1)
                            Text(row.company).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).lineLimit(1)
                        }
                    }
                    TableColumn("Status", value: \.status).width(90)
                    TableColumn("Applied", value: \.applied) { row in Text(row.applied.shortDay) }.width(80)
                    TableColumn("Follow up", value: \.followUp) { row in
                        if let date = row.application.followUpAt {
                            Label(date.shortDay, systemImage: date <= Date() ? "bell" : "calendar")
                                .foregroundStyle(date <= Date() ? Color(.maybe) : Color(.inkSecondary))
                        }
                    }
                    .width(90)
                }
                .overlay {
                    if rows.isEmpty {
                        EmptyState("Nothing here", "Mark a job applied with A; it shows here until it closes.")
                    }
                }
            }
        } pane: {
            if let application = model.applications.first(where: { $0.id == model.selectedApplication }) {
                ApplicationPane(application: application)
            } else {
                EmptyState("No application selected", "Choose one to move it along, set a follow-up or add notes.")
            }
        }
        .navigationTitle("Applied")
    }

    private var rows: [Row] {
        model.applications.filter { scope.contains($0.status) }.map { application in
            let job = model.summary(application.jobID)
            return Row(application: application, title: job?.title ?? "A job", company: job?.company ?? "")
        }
        .sorted(using: order)
    }

    private var line: String {
        let waiting = model.applications.filter(\.status.isWaiting).count
        let talking = model.applications.filter(\.status.isInProgress).count
        return "\(model.applications.count) applications · \(waiting) waiting · \(talking) in progress"
    }
}

/// Interviews: the board of Screen, Interview and Offer, and the same pane.
struct InterviewsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ColumnTitle(
                    title: "Interviews", line: "\(model.applications.filter(\.status.isInProgress).count) in progress")
                HStack(alignment: .top, spacing: Spacing.space3) {
                    ForEach([Application.Status.screen, .interview, .offer], id: \.self) { status in
                        column(status)
                    }
                }
                .padding(.horizontal, Spacing.space6)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            if let application = model.applications.first(where: { $0.id == model.selectedApplication }),
                application.status.isInProgress
            {
                Divider()
                ApplicationPane(application: application).frame(width: 420)
            }
        }
        .background(Color(.surface))
        .navigationTitle("Interviews")
    }

    private func column(_ status: Application.Status) -> some View {
        let applications = model.applications.filter { $0.status == status }
        return VStack(alignment: .leading, spacing: Spacing.space2) {
            GroupHeader(title: status.title, count: applications.count)
            ForEach(applications) { application in
                let job = model.summary(application.jobID)
                Button {
                    model.selectedApplication = application.id
                } label: {
                    VStack(alignment: .leading, spacing: Spacing.space1) {
                        Text(job?.title ?? "A job").font(TypeStyle.headline).foregroundStyle(Color(.ink)).lineLimit(2)
                        Text(job?.company ?? "").font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                        if let next = application.nextStep, !next.isEmpty {
                            Text(next).font(TypeStyle.callout).foregroundStyle(Color(.ink2)).lineLimit(2)
                        }
                    }
                    .padding(Spacing.space3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.card)
                            .fill(
                                model.selectedApplication == application.id ? Color(.accentTint) : Color(.surfaceRaised)
                            )
                    )
                    .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Color(.separator)))
                    .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
                }
                .buttonStyle(.plain)
            }
            if applications.isEmpty {
                Text("None").font(TypeStyle.callout).foregroundStyle(Color(.inkDimmed))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// One application: its status with Move to, the next step and follow-up, notes, and its timeline.
struct ApplicationPane: View {
    let application: Application
    @Environment(AppModel.self) private var model
    @State private var draft: Application
    @State private var note = ""
    @State private var events: [ApplicationEvent] = []

    init(application: Application) {
        self.application = application
        _draft = State(initialValue: application)
    }

    var body: some View {
        let job = model.summary(application.jobID)
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.space6) {
                VStack(alignment: .leading, spacing: Spacing.space1) {
                    Text(job?.title ?? "A job").font(TypeStyle.title1)
                    Text(
                        [job?.company ?? "", "Applied \(application.appliedAt.shortDay)", application.channel ?? ""]
                            .filter { !$0.isEmpty }.joined(separator: " · ")
                    )
                    .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                }
                HStack {
                    Picker("Move to", selection: $draft.status) {
                        ForEach(Application.Status.allCases) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                    Spacer()
                    Button("Open posting") { model.openPosting(application.jobID) }
                }
                PaneSection(title: "Next") {
                    TextField("Next step", text: Binding(get: { draft.nextStep ?? "" }, set: { draft.nextStep = $0 }))
                    Toggle(
                        "Follow up",
                        isOn: Binding(
                            get: { draft.followUpAt != nil },
                            set: { draft.followUpAt = $0 ? Date().addingTimeInterval(7 * 86_400) : nil }))
                    if let date = draft.followUpAt {
                        DatePicker(
                            "On", selection: Binding(get: { date }, set: { draft.followUpAt = $0 }),
                            displayedComponents: .date)
                    }
                }
                PaneSection(title: "Notes") {
                    TextEditor(text: $draft.notes)
                        .font(TypeStyle.body)
                        .frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                        .padding(Spacing.space2)
                        .background(RoundedRectangle(cornerRadius: Radius.field).fill(Color(.surfaceSunken)))
                }
                PaneSection(title: "Timeline") {
                    HStack {
                        TextField("Add a line: a call, an email, a reply", text: $note)
                            .onSubmit(addNote)
                        Button("Add", action: addNote).disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    ForEach(events.reversed()) { event in
                        HStack(alignment: .firstTextBaseline) {
                            Text(event.at.shortDay).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                                .frame(width: 70, alignment: .leading)
                            Text(
                                event.kind == "note"
                                    ? (event.note ?? "") : Application.Status(rawValue: event.kind)?.title ?? event.kind
                            )
                            .font(TypeStyle.body)
                            if event.kind != "note", let line = event.note, !line.isEmpty {
                                Text(line).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                            }
                        }
                    }
                }
                Button("I didn't apply", role: .destructive) { remove() }
                    .buttonStyle(.plain).foregroundStyle(Color(.error)).font(TypeStyle.callout)
            }
            .padding(Spacing.space7)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Keyed by id: a save that comes back must not reset what you're typing.
        .task(id: application.id) {
            draft = application
            events = (try? await model.workspace?.store.applications.events(of: application.id)) ?? []
        }
        .onChange(of: draft) { save(note: nil) }
    }

    private func addNote() {
        let line = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        note = ""
        save(note: line)
    }

    private func save(note: String?) {
        guard let store = model.workspace?.store, draft != application || note != nil else { return }
        let draft = draft
        Task {
            await model.save(draft, note: note)
            events = (try? await store.applications.events(of: draft.id)) ?? events
        }
    }

    private func remove() {
        guard let store = model.workspace?.store else { return }
        Task {
            try? await store.applications.delete(application.id)
            model.selectedApplication = nil
            await model.reload()
        }
    }
}
