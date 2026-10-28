import Engine
import Jobs
import Secrets
import Store
import SwiftUI

/// Sources: the company boards Kairos reads and the searches, how each last went, and the source
/// pane with its history. Boards you add are read every fetch; catalog boards rest while they have
/// nothing for you.
struct SourcesView: View {
    enum Scope: String, CaseIterable {
        case yours = "Yours"
        case catalog = "Catalog"
        case searches = "Searches"
        case all = "All"
    }

    struct Row: Identifiable {
        let source: Source
        let open: Int
        let added: Int
        let read: FetchLogEntry?
        var id: UUID { source.id }
        var name: String { source.displayName }
        var system: String { source.kind.displayName }
        var status: String { source.status.rawValue }
        var lastRead: Date { read?.at ?? .distantPast }
    }

    @Environment(AppModel.self) private var model
    @State private var scope = Scope.yours
    @State private var selection: UUID?
    @State private var search = ""
    @State private var open: [UUID: Int] = [:]
    @State private var added: [UUID: Int] = [:]
    @State private var reads: [UUID: FetchLogEntry] = [:]
    @State private var adding = false
    @State private var order = [KeyPathComparator(\Row.open, order: .reverse)]

    var body: some View {
        ListPaneLayout(listWidth: 600) {
            VStack(spacing: 0) {
                ColumnTitle(title: "Sources", line: line)
                Picker("Show", selection: $scope) {
                    ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, Spacing.space6)
                .padding(.bottom, Spacing.space3)
                Table(rows, selection: $selection, sortOrder: $order) {
                    TableColumn("Company", value: \.name) { row in
                        HStack(spacing: Spacing.space2) {
                            if row.source.lastError != nil, row.source.status == .watching {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(.maybe))
                            }
                            Text(row.name).lineLimit(1)
                                .foregroundStyle(row.source.status == .watching ? Color(.ink) : Color(.inkDimmed))
                        }
                    }
                    TableColumn("System", value: \.system).width(110)
                    TableColumn("Open", value: \.open) { row in Text("\(row.open)").monospacedDigit() }.width(50)
                    TableColumn("Last read", value: \.lastRead) { row in
                        Text(row.read.map { "\($0.outcome.rawValue) · \($0.at.shortDay)" } ?? "Not yet")
                            .foregroundStyle(Color(.inkSecondary))
                    }
                    .width(130)
                }
            }
        } pane: {
            if let source = model.sources.first(where: { $0.id == selection }) {
                SourcePane(source: source, open: open[source.id] ?? 0)
            } else {
                SearchesPane()
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Company")
        .toolbar {
            Button {
                adding = true
            } label: {
                Label("Add a board", systemImage: "plus")
            }
        }
        .sheet(isPresented: $adding) { AddBoardSheet() }
        .navigationTitle("Sources")
        .task(id: model.sources) {
            guard let store = model.workspace?.store else { return }
            open = (try? await store.jobs.openListingCounts()) ?? [:]
            added = (try? await store.activity.added(since: Date().addingTimeInterval(-30 * 86_400))) ?? [:]
            reads = (try? await store.activity.lastReads()) ?? [:]
        }
    }

    private var rows: [Row] {
        model.sources.filter { source in
            let inScope =
                switch scope {
                case .yours: source.kind.isBoard && source.origin != .catalog
                case .catalog: source.origin == .catalog
                case .searches: !source.kind.isBoard
                case .all: true
                }
            return inScope && source.status != .removed
                && (search.isEmpty || source.displayName.localizedCaseInsensitiveContains(search))
        }
        .map { Row(source: $0, open: open[$0.id] ?? 0, added: added[$0.id] ?? 0, read: reads[$0.id]) }
        .sorted(using: order)
    }

    private var line: String {
        let watched = model.sources.filter { $0.status == .watching }.count
        let failing = model.sources.filter { $0.status == .watching && $0.lastError != nil }.count
        return "\(watched) watched" + (failing > 0 ? " · \(failing) with a problem" : "")
            + (model.preferences.watchCatalog ? " · catalog on" : "")
    }
}

/// One source: its status and what to do about it, what it lists for you, and its last reads.
struct SourcePane: View {
    let source: Source
    let open: Int
    @Environment(AppModel.self) private var model
    @State private var history: [FetchLogEntry] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.space6) {
                VStack(alignment: .leading, spacing: Spacing.space1) {
                    Text(source.displayName).font(TypeStyle.title1)
                    Text("\(source.kind.displayName) · \(Self.origin(source.origin)) · \(Self.status(source))")
                        .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                }
                HStack {
                    switch source.status {
                    case .watching:
                        Button("Pause") { set(.muted) }
                    case .muted, .gone, .removed:
                        Button("Watch again") { set(.watching) }.buttonStyle(.borderedProminent)
                    }
                    if source.kind.isBoard, source.status != .removed {
                        Button("Remove", role: .destructive) { set(.removed) }
                            .help("Kairos never adds it back, from the catalog or a search.")
                    }
                    if let url = source.board?.pageURL { Link("Open board", destination: url) }
                }
                if let error = source.lastError {
                    Card {
                        Label(error, systemImage: "exclamationmark.triangle.fill").font(TypeStyle.body)
                            .foregroundStyle(Color(.ink))
                    }
                }
                PaneSection(title: "For you", trailing: "\(open) open") {
                    if let rest = source.restUntil, rest > Date() {
                        Text(
                            "Nothing for you lately, so it rests until \(rest.formatted(date: .abbreviated, time: .omitted))."
                        )
                        .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                    }
                }
                PaneSection(title: "Last reads") {
                    ForEach(Array(history.enumerated()), id: \.offset) { _, read in
                        HStack {
                            Text(read.at.formatted(date: .abbreviated, time: .shortened)).font(TypeStyle.callout)
                                .foregroundStyle(Color(.inkSecondary)).frame(width: 150, alignment: .leading)
                            Text(read.outcome.rawValue).font(TypeStyle.callout)
                            Spacer()
                            Text("\(read.items) listed · \(read.added) new").font(TypeStyle.callout).monospacedDigit()
                                .foregroundStyle(Color(.inkSecondary))
                        }
                    }
                    if history.isEmpty {
                        Text("Not read yet.").font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                    }
                }
            }
            .padding(Spacing.space7)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: source) { history = (try? await model.workspace?.store.activity.reads(of: source.id)) ?? [] }
    }

    private func set(_ status: Source.Status) {
        guard let store = model.workspace?.store else { return }
        Task {
            try? await store.sources.setStatus(status, for: source.id)
            await model.reload()
        }
    }

    static func origin(_ origin: Source.Origin) -> String {
        switch origin {
        case .you: "Added by you"
        case .catalog: "From the catalog"
        case .link: "Found behind a search's link"
        case .lead: "Found behind a lead"
        case .search: "A search"
        }
    }

    static func status(_ source: Source) -> String {
        switch source.status {
        case .watching: "Watching"
        case .muted: "Paused"
        case .gone: "Gone: not found three times"
        case .removed: "Removed"
        }
    }
}

/// The searches: Himalayas, Google Jobs through SerpApi, and Adzuna (leads only), with their keys.
struct SearchesPane: View {
    @Environment(AppModel.self) private var model
    @State private var serpAPI = ""
    @State private var adzunaID = ""
    @State private var adzunaKey = ""
    @State private var saved: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.space6) {
                Text("Searches").font(TypeStyle.title1)
                search(.himalayas, "Remote jobs, searched by your roles. No key needed.")
                search(
                    .googleJobs,
                    "Google for Jobs, a few searches each fetch, city by city. Needs a SerpApi key (250 searches a month free)."
                ) {
                    key("SerpApi key", $serpAPI, .serpAPI)
                }
                search(
                    .adzuna,
                    "Adzuna's snippets are leads: Kairos looks up the companies' own boards for the full postings."
                ) {
                    key("App ID", $adzunaID, .adzunaAppID)
                    key("App key", $adzunaKey, .adzunaAppKey)
                }
            }
            .padding(Spacing.space7)
            .frame(maxWidth: Spacing.formWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func search<Extra: View>(
        _ kind: SourceKind, _ line: String, @ViewBuilder extra: () -> Extra = { EmptyView() }
    )
        -> some View
    {
        let source = model.sources.first { $0.kind == kind }
        let extra = extra()
        return Card {
            VStack(alignment: .leading, spacing: Spacing.space2) {
                Toggle(
                    kind.displayName,
                    isOn: Binding(get: { source?.status == .watching }, set: { turn(kind, on: $0) })
                )
                .toggleStyle(.switch)
                .font(TypeStyle.headline)
                Text(line).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).fixedSize(
                    horizontal: false, vertical: true)
                if let error = source?.lastError {
                    Text(error).font(TypeStyle.callout).foregroundStyle(Color(.maybe))
                }
                extra
            }
        }
    }

    private func key(_ label: String, _ text: Binding<String>, _ secret: SecretKey) -> some View {
        var hint: String?
        if let secrets = model.workspace?.secrets, let summary = try? secrets.summary(secret) { hint = summary.hint }
        return HStack {
            SecureField(hint.map { "\(label) (saved: \($0))" } ?? label, text: text)
            Button(saved.contains(secret.name) ? "Saved" : "Save") {
                guard let secrets = model.workspace?.secrets, !text.wrappedValue.isEmpty else { return }
                try? secrets.write(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines), for: secret)
                text.wrappedValue = ""
                saved.insert(secret.name)
            }
            .disabled(text.wrappedValue.isEmpty)
        }
    }

    private func turn(_ kind: SourceKind, on: Bool) {
        guard let store = model.workspace?.store else { return }
        Task {
            do {
                let source = try await store.sources.search(kind)
                try await store.sources.setStatus(on ? .watching : .muted, for: source.id)
            } catch {
                model.notice = AppModel.Notice(title: "\(kind.displayName) couldn't be changed", message: "\(error)")
            }
            await model.reload()
        }
    }
}

/// Add a company's board: paste a link to its careers page or a posting, or name its system and slug.
struct AddBoardSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var name = ""
    @State private var kind = SourceKind.greenhouse
    @State private var slug = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            Text("Add a board").font(TypeStyle.title1)
            Form {
                TextField("A link to the board or a posting", text: $link)
                    .onChange(of: link) { detect() }
                Picker("System", selection: $kind) {
                    ForEach(SourceKind.boards, id: \.self) { Text($0.displayName).tag($0) }
                }
                TextField("Board name in its link (slug)", text: $slug)
                TextField("Company", text: $name)
            }
            .formStyle(.grouped)
            if !slug.isEmpty, !BoardSlug.isValid(slug) {
                Text("A slug has only letters, digits, - and _.").font(TypeStyle.callout).foregroundStyle(Color(.error))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!BoardSlug.isValid(slug))
            }
        }
        .padding(Spacing.space6)
        .frame(width: 520)
    }

    private func detect() {
        if case .board(let detected, let found, _) = ATSDetector.detect(link) {
            kind = detected
            slug = found
            if name.isEmpty { name = found.capitalized }
        }
    }

    private func add() {
        guard let store = model.workspace?.store else { return }
        let board = Board(kind: kind, slug: slug, name: name.isEmpty ? slug : name)
        Task {
            _ = try? await store.sources.addByYou(board)
            await model.reload()
            dismiss()
        }
    }
}
