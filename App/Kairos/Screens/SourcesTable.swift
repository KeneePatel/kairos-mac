import JobSources
import Store
import SwiftUI

/// The companies and boards Kairos watches (UI v2): the table on the left of Sources. Its scope
/// (Yours · Catalog · All) and search come from the section's toolbar; the chosen row's board
/// shows beside it.
struct SourcesTable: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Source.ID?
    var scope = Scope.yours
    var search = ""

    enum Scope: String, CaseIterable, Identifiable {
        case yours = "Yours"
        case catalog = "Catalog"
        case all = "All"
        var id: Self { self }
    }

    private var shown: [Source] {
        model.sources.filter { source in
            let catalog = source.isFromCatalog
            let inScope = scope == .all || (scope == .catalog) == catalog
            return inScope && (search.isEmpty || source.displayName.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        // Read here, once, not in each row: rows reading the model made SwiftUI abort when you
        // left Find jobs for Review (2026-10-26).
        let open = model.openRoles
        let failures = model.failures
        let adzunaUsed = model.adzunaUsed
        if shown.isEmpty {
            VStack(spacing: Spacing.space2) {
                Text(model.sources.isEmpty ? "No companies yet" : "No matches").font(TypeStyle.title2)
                    .foregroundStyle(Color(.ink))
                Text(
                    model.sources.isEmpty
                        ? "Choose Add, then paste a careers page from Greenhouse, Lever, Ashby, SmartRecruiters, Workable, Recruitee, Personio, BambooHR or Teamtailor."
                        : "Nothing in this scope matches the search."
                )
                .font(TypeStyle.body).foregroundStyle(Color(.inkSecondary)).multilineTextAlignment(.center)
            }
            .padding(Spacing.space7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(shown, selection: $selection) {
                TableColumn("Company") { source in
                    Text(source.displayName).font(TypeStyle.headline)
                        .foregroundStyle(source.enabled ? Color(.ink) : Color(.inkDimmed)).lineLimit(1)
                }
                .width(min: 140, ideal: 200)
                TableColumn("Board") { source in
                    Text(source.kind.displayName).foregroundStyle(Color(.ink2)).lineLimit(1)
                }
                .width(min: 80, ideal: 110)
                TableColumn("Open roles") { source in
                    Text(source.lastRunAt == nil ? "—" : "\(open[source.id, default: 0])")
                        .monospacedDigit().foregroundStyle(Color(.ink2))
                }
                .width(min: 64, ideal: 76)
                TableColumn("Checked") { source in
                    Text(source.lastRunAt.map(Self.checked) ?? "Not yet")
                        .monospacedDigit().foregroundStyle(Color(.inkSecondary)).lineLimit(1)
                }
                .width(min: 72, ideal: 90)
                TableColumn("Status") { source in
                    if source.kind == .adzuna, source.enabled, failures[source.id] == nil {
                        AdzunaPlan(used: adzunaUsed)
                    } else {
                        SourceStatus(
                            source: source, failure: failures[source.id],
                            quiet: source.isQuiet(openRoles: open[source.id, default: 0]))
                    }
                }
                .width(min: 120, ideal: 170)
            }
            .contextMenu(forSelectionType: Source.ID.self) { ids in
                if let id = ids.first, let source = model.source(id) {
                    Button(source.enabled ? "Pause" : "Resume") {
                        Task { await model.setEnabled(!source.enabled, for: source) }
                    }
                    Divider()
                    // A catalog company you stop watching isn't added back.
                    Button(
                        source.isFromCatalog ? "Stop watching \(source.displayName)" : "Remove \(source.displayName)",
                        role: .destructive
                    ) {
                        Task { await model.remove(source) }
                    }
                }
            }
        }
    }

    /// "12:39 AM" today, else "Oct 24".
    static func checked(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened) : date.formatted(.dateTime.month(.abbreviated).day())
    }
}

extension Source {
    /// Added from Kairos's board catalog rather than by you (J5).
    var isFromCatalog: Bool { BoardConfig.decode(config)?.origin == "catalog" }

    /// A catalog board with no open job for you: checked every few days, not every fetch (J5).
    func isQuiet(openRoles: Int) -> Bool { isFromCatalog && openRoles == 0 && lastRunAt != nil }
}

/// What's left of Adzuna's free plan today, as Kairos spends it (job collection v2, J4): a bar
/// and the words, with the month under it.
private struct AdzunaPlan: View {
    let used: (today: Int, month: Int)

    var body: some View {
        let budget = AdzunaSource.Budget.standard
        let left = max(0, budget.day - used.today)
        VStack(alignment: .leading, spacing: 3) {
            Meter(left: Double(left) / Double(budget.day)).frame(width: 120)
            Text(
                "\(left) of \(budget.day) searches left today · \(used.month) of \(budget.month.formatted()) this month"
            )
            .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .help("Adzuna's free plan allows 250 searches a day and 2,500 a month; Kairos keeps under 200 and 2,400.")
    }
}

/// A dot or a warning, always with words: never colour alone.
private struct SourceStatus: View {
    let source: Source
    let failure: String?
    var quiet = false

    var body: some View {
        if !source.enabled {
            dot("Paused by you", Color(.inkSecondary))
        } else if source.health == .gone {
            warning(
                "Gone", detail: "The board answered \"not found\" three times. Resume it to try again.")
        } else if let failure {
            warning("Can't reach", detail: failure)
        } else if source.health == .degraded {
            warning("No jobs in \(source.emptyRuns) checks", detail: "The board may have moved or been emptied.")
        } else if source.lastRunAt == nil {
            dot("Not checked yet", Color(.inkSecondary))
        } else if quiet {
            dot("Quiet: nothing for you, checked every 3 days", Color(.inkSecondary))
        } else {
            dot("Active", Color(.yes))
        }
    }

    private func dot(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(text).foregroundStyle(Color(.ink))
        }
    }

    private func warning(_ text: String, detail: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(Color(.error))
            .help(detail)
    }
}

/// Paste a careers page; Kairos says which board it found before you add it. Labels sit above
/// full-width bordered fields, so each one reads as a box to type or paste into.
struct AddCompanySheet: View {
    private enum Field { case careersURL, name }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var careersURL = ""
    @State private var name = ""
    @State private var error: String?
    @State private var saving = false
    @FocusState private var focus: Field?

    private var detection: ATSDetection? {
        careersURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : ATSDetector.detect(careersURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space5) {
            VStack(alignment: .leading, spacing: Spacing.space1) {
                Text("Add a company").font(TypeStyle.title2).foregroundStyle(Color(.ink))
                Text("Kairos checks the company's job board for new postings.")
                    .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            }

            VStack(alignment: .leading, spacing: Spacing.space2) {
                Text("Careers page").font(TypeStyle.headline).foregroundStyle(Color(.ink))
                TextField("Careers page", text: $careersURL, prompt: Text("Paste a link, like jobs.lever.co/company"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($focus, equals: .careersURL)
                    .onSubmit(submit)
                detectionNote
            }

            VStack(alignment: .leading, spacing: Spacing.space2) {
                HStack(spacing: Spacing.space1) {
                    Text("Company name").font(TypeStyle.headline).foregroundStyle(Color(.ink))
                    Text("Optional").font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                }
                TextField("Company name", text: $name, prompt: Text("As you'd like it shown"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($focus, equals: .name)
                    .onSubmit(submit)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(TypeStyle.callout).foregroundStyle(Color(.error))
            }

            HStack(spacing: Spacing.space2) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add company", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || !isDetected)
            }
            .controlSize(.large)
        }
        .padding(Spacing.space6)
        .frame(width: 520)
        .onAppear { focus = .careersURL }
    }

    /// Under the field: which board was found, or why not yet. Colour always comes with an icon and words.
    @ViewBuilder private var detectionNote: some View {
        Group {
            switch detection {
            case .detected(let kind, let slug)?:
                Label("Found the \(kind.displayName) board “\(slug)”", systemImage: "checkmark.circle")
                    .foregroundStyle(Color(.yes))
            case .notDetected(let reason)?:
                Label(reason, systemImage: "info.circle").foregroundStyle(Color(.inkSecondary))
            case nil:
                Text(
                    "Greenhouse, Lever, Ashby, SmartRecruiters, Workable, Recruitee, Personio, BambooHR and Teamtailor boards work."
                )
                .foregroundStyle(Color(.inkSecondary))
            }
        }
        .font(TypeStyle.callout)
    }

    private var isDetected: Bool {
        if case .detected? = detection { return true }
        return false
    }

    private func submit() {
        guard isDetected, !saving else { return }
        Task { await add() }
    }

    private func add() async {
        saving = true
        defer { saving = false }
        if let problem = await model.addCompany(careersURL: careersURL, name: name) {
            error = problem
        } else {
            dismiss()
        }
    }
}

/// Your Adzuna app ID and key (free from developer.adzuna.com). Kairos searches Adzuna for the
/// titles in Settings, Search, Canada first. Adzuna's terms ask that its listings name it, linked.
struct AdzunaSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var appID = ""
    @State private var appKey = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space5) {
            VStack(alignment: .leading, spacing: Spacing.space1) {
                Text(model.adzunaSource == nil ? "Search Adzuna" : "Change your Adzuna keys")
                    .font(TypeStyle.title2).foregroundStyle(Color(.ink))
                Text(
                    "Adzuna lists jobs from many employers. Kairos searches it for your roles to learn which companies are hiring, finds their public boards, and reads the full postings there."
                )
                .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                .fixedSize(horizontal: false, vertical: true)
            }

            field("App ID") {
                TextField("App ID", text: $appID, prompt: Text("8 characters, like 1a2b3c4d")).onSubmit(submit)
            }
            field("App key") {
                SecureField("App key", text: $appKey, prompt: Text("32 characters")).onSubmit(submit)
            }

            VStack(alignment: .leading, spacing: Spacing.space2) {
                Label {
                    Text(
                        "Adzuna sends a snippet of each posting, not the whole text, so its results never become jobs: they are leads, company names Kairos looks up on boards it can read in full."
                    )
                } icon: {
                    Image(systemName: "text.badge.minus")
                }
                Label {
                    Text(
                        "Your keys stay on this Mac. The free plan allows 250 searches a day and 2,500 a month; Kairos pages through every new posting for your roles but stays under 200 a day and 2,400 a month, at most 80 a fetch."
                    )
                } icon: {
                    Image(systemName: "lock")
                }
            }
            .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Spacing.space2) {
                if let url = URL(string: "https://developer.adzuna.com/signup") {
                    Link("Get a free key", destination: url).font(TypeStyle.callout)
                }
                Text("·").foregroundStyle(Color(.inkSecondary))
                AdzunaCredit()
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(TypeStyle.callout).foregroundStyle(Color(.error))
            }

            HStack(spacing: Spacing.space2) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || appID.isEmpty || appKey.isEmpty)
            }
            .controlSize(.large)
        }
        .padding(Spacing.space6)
        .frame(width: 520)
    }

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Text(title).font(TypeStyle.headline).foregroundStyle(Color(.ink))
            content().labelsHidden().textFieldStyle(.roundedBorder).controlSize(.large)
        }
    }

    private func submit() {
        guard !saving, !appID.isEmpty, !appKey.isEmpty else { return }
        Task {
            saving = true
            defer { saving = false }
            if let problem = await model.saveAdzuna(appID: appID, appKey: appKey) {
                error = problem
            } else {
                dismiss()
            }
        }
    }
}

/// Himalayas (remote jobs, a key optional) or Google Jobs through SerpApi (your key needed), the
/// optional searches of job collection v2, J7. Laid out like the Adzuna sheet.
struct SearchSourceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let kind: SourceKind
    @State private var key = ""
    @State private var error: String?
    @State private var saving = false

    private var isGoogle: Bool { kind == .googleJobs }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            Text(isGoogle ? "Search Google Jobs" : "Search Himalayas").font(TypeStyle.title2).foregroundStyle(
                Color(.ink))
            Text(
                isGoogle
                    ? "Google for Jobs gathers postings from LinkedIn, Indeed, Workday career sites and more, which Kairos can't read itself. SerpApi asks Google for you with your key: its free plan allows 250 searches a month, and Kairos uses 8 a day, each of your roles in each of your places in turn (Settings, Search)."
                    : "Himalayas lists remote jobs and says which countries can apply. Kairos searches it for your roles in your countries, with each job's full text. A free key lifts its limits; it works without one."
            )
            .font(TypeStyle.body).foregroundStyle(Color(.ink2)).fixedSize(horizontal: false, vertical: true)
            LabeledField(title: isGoogle ? "SerpApi key" : "Himalayas key (optional)") {
                SecureField(
                    "Key", text: $key, prompt: Text(isGoogle ? "Paste the key" : "Leave empty to use it without one")
                )
                .textFieldStyle(.roundedBorder)
            }
            if let url = URL(string: isGoogle ? "https://serpapi.com/users/sign_up" : "https://himalayas.app/api") {
                Link(isGoogle ? "Get a free SerpApi key" : "About Himalayas's API and keys", destination: url)
                    .font(TypeStyle.callout)
            }
            Label(
                isGoogle
                    ? "SerpApi queries Google on your behalf. Each job keeps the page Google took it from; Apply goes to the employer's own page when Google lists one."
                    : "Its jobs say \"via Himalayas\" and open on Himalayas, with its apply link, as its terms ask.",
                systemImage: "info.circle"
            )
            .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).fixedSize(horizontal: false, vertical: true)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(TypeStyle.callout)
                    .foregroundStyle(Color(.error))
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(model.source(of: kind) == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(saving || (isGoogle && key.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(Spacing.space6)
        .frame(width: 480)
    }

    private func save() {
        saving = true
        Task {
            if let problem = await model.saveSearch(kind, key: key) {
                error = problem
            } else {
                dismiss()
            }
            saving = false
        }
    }
}

/// "Jobs by Adzuna", linked: Adzuna's terms ask every listing shown from it to name it.
struct AdzunaCredit: View {
    var body: some View {
        if let url = URL(string: "https://www.adzuna.ca") {
            Link("Jobs by Adzuna", destination: url).font(TypeStyle.callout)
        }
    }
}
