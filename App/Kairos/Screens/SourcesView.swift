import JobSources
import Store
import SwiftUI

/// The company watchlist (part of Fetch since polish P3): each board's status, pause or remove one.
struct SourcesTable: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Source.ID?
    @State private var changingAdzuna = false

    var body: some View {
        content.sheet(isPresented: $changingAdzuna) { AdzunaSheet() }
    }

    @ViewBuilder private var content: some View {
        if model.sources.isEmpty {
            ContentUnavailableView {
                Label("No companies yet", systemImage: "antenna.radiowaves.left.and.right")
            } description: {
                Text(
                    "Choose Add company and paste a careers page from Greenhouse, Lever, Ashby, SmartRecruiters, Workable, Recruitee, Personio, BambooHR or Teamtailor."
                )
                .foregroundStyle(Color(.inkSecondary))
            }
        } else {
            Table(model.sources, selection: $selection) {
                TableColumn("Company") { source in
                    Text(source.displayName).font(TypeStyle.headline).foregroundStyle(Color(.ink))
                }
                .width(min: 160, ideal: 220)
                TableColumn("Job board") { source in
                    Text(source.kind.displayName).foregroundStyle(Color(.ink2))
                }
                .width(min: 90, ideal: 120)
                TableColumn("Open roles") { source in
                    Text(source.lastRunAt == nil ? "—" : "\(model.openRoles(for: source))")
                        .monospacedDigit().foregroundStyle(Color(.ink2))
                }
                .width(min: 70, ideal: 90)
                TableColumn("Last checked") { source in
                    Text(source.lastRunAt?.formatted(date: .abbreviated, time: .shortened) ?? "Not yet")
                        .monospacedDigit().foregroundStyle(Color(.inkSecondary))
                }
                .width(min: 110, ideal: 150)
                TableColumn("Status") { source in
                    if source.kind == .adzuna, source.enabled, model.failure(for: source) == nil {
                        AdzunaPlan(used: model.adzunaUsed)
                    } else {
                        SourceStatus(source: source, failure: model.failure(for: source))
                    }
                }
                .width(min: 140, ideal: 220)
            }
            .contextMenu(forSelectionType: Source.ID.self) { ids in
                if let id = ids.first, let source = model.source(id) {
                    Button(source.enabled ? "Pause" : "Resume") {
                        Task { await model.setEnabled(!source.enabled, for: source) }
                    }
                    if source.kind == .adzuna {
                        Button("Change Adzuna keys…") { changingAdzuna = true }
                    }
                    Divider()
                    Button("Remove \(source.displayName)", role: .destructive) {
                        Task { await model.remove(source) }
                    }
                }
            }
        }
    }

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

    var body: some View {
        if !source.enabled {
            dot("Paused by you", Color(.inkSecondary))
        } else if let failure {
            warning("Can't reach", detail: failure)
        } else if source.health == .degraded {
            warning("No jobs in \(source.emptyRuns) checks", detail: "The board may have moved or been emptied.")
        } else if source.lastRunAt == nil {
            dot("Not checked yet", Color(.inkSecondary))
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
                Text("Add a company").font(TypeStyle.title3).foregroundStyle(Color(.ink))
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
                    .font(TypeStyle.title3).foregroundStyle(Color(.ink))
                Text(
                    "Adzuna lists jobs from many employers. Kairos searches it for the job titles in Settings, Search, Canada first, after your company boards."
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
                        "Adzuna sends a snippet of each posting, not the whole text, so its jobs are Maybe at most. Open one to read the rest before you build."
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

/// "Jobs by Adzuna", linked: Adzuna's terms ask every listing shown from it to name it.
struct AdzunaCredit: View {
    var body: some View {
        if let url = URL(string: "https://www.adzuna.ca") {
            Link("Jobs by Adzuna", destination: url).font(TypeStyle.callout)
        }
    }
}
