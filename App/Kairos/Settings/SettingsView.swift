import AI
import AppKit
import Engine
import Jobs
import Screening
import Secrets
import Store
import SwiftUI
import Tailoring

/// Settings: General, Search and AI, each a form of hairline sections at the reading measure.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            // A plain list inside the content: glass belongs to navigation only.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsPage.allCases) { page in
                    Button {
                        model.settingsPage = page
                    } label: {
                        Label(page.title, systemImage: page.symbol)
                            .font(TypeStyle.body)
                            .foregroundStyle(Color(.ink))
                            .padding(.horizontal, Spacing.space3)
                            .frame(maxWidth: .infinity, minHeight: Spacing.sidebarItemHeight, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.field)
                                    .fill(model.settingsPage == page ? Color(.accentTint) : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(Spacing.space3)
            .padding(.top, Spacing.space6)
            .frame(width: 200)
            .background(Color(.surface))
            Divider()
            ScrollView {
                Group {
                    switch model.settingsPage {
                    case .general: GeneralSettings()
                    case .search: SearchSettings(preferences: model.preferences)
                    case .ai: AISettingsView(settings: model.aiSettings)
                    }
                }
                .padding(Spacing.space7)
                .frame(maxWidth: Spacing.formWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(.surface))
        }
        .navigationTitle("Settings")
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space6) {
            Text("General").font(TypeStyle.pageTitle)
            PaneSection(title: "Where you may work") {
                Text("Screening judges sponsorship and clearance against this. It stays on this Mac.")
                    .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                ForEach(Country.allCases, id: \.self) { country in
                    Picker(country.name, selection: authorization(country)) {
                        Text("Not set").tag(WorkProfile.Status?.none)
                        ForEach(WorkProfile.Status.allCases, id: \.self) {
                            Text($0.title).tag(WorkProfile.Status?.some($0))
                        }
                    }
                }
                Toggle("I hold a security clearance", isOn: profile(\.hasClearance)).toggleStyle(.switch)
                Picker("Studies", selection: profile(\.enrolment)) {
                    Text("Not set").tag(WorkProfile.Enrolment?.none)
                    Text("Student").tag(WorkProfile.Enrolment?.some(.student))
                    Text("Graduated").tag(WorkProfile.Enrolment?.some(.graduated))
                }
            }
            PaneSection(title: "Resumes") {
                Toggle("Two pages when the posting's evidence needs it", isOn: pages).toggleStyle(.switch)
                Toggle("Stretch mode", isOn: stretch(\.enabled)).toggleStyle(.switch)
                Text(
                    "Stretch builds may add bullets for Can discuss skills, each listed under Be ready to discuss. Off unless you turn it on."
                )
                .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).fixedSize(
                    horizontal: false, vertical: true)
                if model.stretch.enabled {
                    Stepper(
                        "Up to \(model.stretch.limit) per role", value: stretch(\.perRole),
                        in: 0...StretchSettings.maxPerRole)
                }
            }
            PaneSection(title: "Your data") {
                if let folder = model.workspace?.folder {
                    Text(folder.root.path).font(TypeStyle.mono).foregroundStyle(Color(.inkSecondary)).textSelection(
                        .enabled)
                    HStack {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder.root]) }
                        Button("Back up now") {
                            Task {
                                if let url = try? await model.workspace?.backUp() {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                            }
                        }
                    }
                }
                if let report = model.preparation?.imported {
                    Text(
                        "Imported from the first Kairos: \(report.jobs) jobs, \(report.builds) resumes, \(report.applications) applications."
                    )
                    .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                }
                Text(
                    "Kairos keeps everything on this Mac. Your keys stay in a file only Kairos can read; the AI never sees your name, contact details or work status."
                )
                .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).fixedSize(
                    horizontal: false, vertical: true)
            }
        }
    }

    private func authorization(_ country: Country) -> Binding<WorkProfile.Status?> {
        Binding(
            get: { model.workProfile.authorization[country] },
            set: { status in
                var profile = model.workProfile
                profile.authorization[country] = status
                model.saveSetting(WorkProfile.storageKey, profile)
                Task { await model.reload() }
            })
    }

    private func profile<V>(_ path: WritableKeyPath<WorkProfile, V>) -> Binding<V> {
        Binding(
            get: { model.workProfile[keyPath: path] },
            set: { value in
                var profile = model.workProfile
                profile[keyPath: path] = value
                model.saveSetting(WorkProfile.storageKey, profile)
                Task { await model.reload() }
            })
    }

    private func stretch<V>(_ path: WritableKeyPath<StretchSettings, V>) -> Binding<V> {
        Binding(
            get: { model.stretch[keyPath: path] },
            set: { value in
                var stretch = model.stretch
                stretch[keyPath: path] = value
                model.saveSetting(StretchSettings.storageKey, stretch)
                Task { await model.reload() }
            })
    }

    private var pages: Binding<Bool> {
        Binding(
            get: { model.pages.twoPagesWhenNeeded },
            set: { value in
                model.saveSetting(PageSettings.storageKey, PageSettings(twoPagesWhenNeeded: value))
                Task { await model.reload() }
            })
    }
}

// MARK: - Search

/// What you're looking for: roles, titles, levels, where, limits. Saved as you change it; Re-check
/// judges every job you haven't acted on again with the new settings.
struct SearchSettings: View {
    @Environment(AppModel.self) private var model
    @State private var draft: SearchPreferences

    init(preferences: SearchPreferences) {
        _draft = State(initialValue: preferences)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Search").font(TypeStyle.pageTitle)
                Spacer()
                Button("Re-check jobs") { model.screenNow(.everything) }
                    .disabled(model.activity.isRunning)
                    .help(
                        "Judge every job you haven't acted on again with these settings. Stored analyses are reused: no AI calls for those."
                    )
            }
            PaneSection(title: "Roles") {
                ForEach(RoleFamily.allCases) { family in
                    Toggle(family.title, isOn: member(family, of: \.roles)).toggleStyle(.switch)
                }
                list("Your other titles", \.titleInclude, prompt: "Developer advocate, Solutions engineer")
                list("Titles to skip", \.titleExclude, prompt: "Sales, Recruiter")
            }
            PaneSection(title: "Levels") {
                FlowLayout {
                    ForEach(Seniority.allCases, id: \.self) { level in
                        Toggle(level.title, isOn: member(level, of: \.seniority)).toggleStyle(.checkbox)
                    }
                }
                Picker("Most years a posting may ask", selection: $draft.maxYearsRequired) {
                    Text("Any").tag(Int?.none)
                    ForEach([1, 2, 3, 4, 5, 7, 10], id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                }
            }
            PaneSection(title: "Where") {
                ForEach(Country.allCases, id: \.self) { country in
                    Toggle(
                        country.name,
                        isOn: Binding(
                            get: { draft.countries.contains(country) },
                            set: { on in
                                if on {
                                    draft.countries.append(country)
                                } else {
                                    draft.countries.removeAll { $0 == country }
                                }
                            })
                    ).toggleStyle(.switch)
                }
                Toggle("Remote jobs", isOn: $draft.remoteAllowed).toggleStyle(.switch)
                list(
                    "Google Jobs searches these cities", placesBinding, prompt: "Toronto, ON; Halifax, NS",
                    separators: [";"])
            }
            PaneSection(title: "Limits") {
                Picker("Posted within", selection: $draft.maxAgeDays) {
                    Text("Any time").tag(Int?.none)
                    ForEach([7, 14, 30, 60, 90], id: \.self) { Text("\($0) days").tag(Int?.some($0)) }
                }
                list("Companies to skip", \.blacklist, prompt: "Amazon")
                Toggle("Show staffing agencies", isOn: $draft.showAgencies).toggleStyle(.switch)
                Toggle("Watch Kairos's catalog of boards in your countries", isOn: $draft.watchCatalog).toggleStyle(
                    .switch)
            }
            PaneSection(title: "Verdicts") {
                Stepper(
                    "Yes when the resume shows \(Int(draft.thresholds.yesAt * 100))% of the must-haves",
                    value: $draft.thresholds.yesAt, in: 0.5...1, step: 0.05)
                Stepper(
                    "No below \(Int(draft.thresholds.maybeAt * 100))%", value: $draft.thresholds.maybeAt, in: 0.2...0.8,
                    step: 0.05)
            }
        }
        .onChange(of: draft) { model.savePreferences(draft) }
    }

    private func member<T: Hashable>(_ value: T, of path: WritableKeyPath<SearchPreferences, Set<T>>) -> Binding<Bool> {
        Binding(
            get: { draft[keyPath: path].contains(value) },
            set: { on in
                if on { draft[keyPath: path].insert(value) } else { draft[keyPath: path].remove(value) }
            })
    }

    /// A list edited as one line, items split on commas or semicolons.
    private func list(_ title: String, _ path: WritableKeyPath<SearchPreferences, [String]>, prompt: String)
        -> some View
    {
        list(title, Binding(get: { draft[keyPath: path] }, set: { draft[keyPath: path] = $0 }), prompt: prompt)
    }

    /// `separators`: what splits items; a city list splits on semicolons only ("Toronto, ON").
    private func list(
        _ title: String, _ items: Binding<[String]>, prompt: String, separators: Set<Character> = [",", ";"]
    )
        -> some View
    {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            Text(title).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            TextField(
                prompt,
                text: Binding(
                    get: { items.wrappedValue.joined(separator: "; ") },
                    set: {
                        items.wrappedValue = $0.split(whereSeparator: { separators.contains($0) })
                            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }))
        }
    }

    /// Cities as "City, Region", one list for Google Jobs; empty means your countries' usual cities.
    private var placesBinding: Binding<[String]> {
        Binding(
            get: { (draft.places ?? []).map(\.displayName) },
            set: { draft.places = $0.isEmpty ? nil : $0.compactMap(Place.parse) })
    }
}

// MARK: - AI

/// Providers and their keys, which models each task uses (in order), and the daily budget.
struct AISettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft: AISettings
    @State private var today: [AIRepository.ModelDay] = []
    @State private var newKey: [String: String] = [:]

    init(settings: AISettings) {
        _draft = State(initialValue: settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space6) {
            Text("AI").font(TypeStyle.pageTitle)
            PaneSection(title: "Providers") {
                ForEach($draft.providers) { $provider in
                    Card {
                        VStack(alignment: .leading, spacing: Spacing.space2) {
                            HStack {
                                Text(provider.displayName).font(TypeStyle.headline)
                                Spacer()
                                Button("Remove", role: .destructive) {
                                    draft.providers.removeAll { $0.id == provider.id }
                                }
                                .buttonStyle(.plain).foregroundStyle(Color(.error)).font(TypeStyle.callout)
                            }
                            if provider.preset.needsKey {
                                ForEach(provider.keyNames, id: \.self) { name in
                                    HStack {
                                        Text(name).font(TypeStyle.mono)
                                        Text(hint(name)).font(TypeStyle.mono).foregroundStyle(Color(.inkSecondary))
                                        Spacer()
                                        Button("Remove") { removeKey(name, from: provider.id) }.font(TypeStyle.callout)
                                    }
                                }
                                HStack {
                                    SecureField(
                                        "Add a key",
                                        text: Binding(
                                            get: { newKey[provider.id] ?? "" }, set: { newKey[provider.id] = $0 }))
                                    Button("Add") { addKey(to: provider.id) }.disabled(
                                        (newKey[provider.id] ?? "").isEmpty)
                                }
                            } else {
                                Text("Runs on this Mac: no key, nothing leaves it.").font(TypeStyle.callout)
                                    .foregroundStyle(Color(.inkSecondary))
                            }
                        }
                    }
                }
                Menu("Add a provider") {
                    ForEach(ProviderPreset.all.filter { preset in !draft.providers.contains { $0.id == preset.id } }) {
                        preset in
                        Button(preset.name) {
                            draft.providers.append(AISettings.Provider(id: preset.id, presetID: preset.id))
                        }
                    }
                }
                .fixedSize()
            }
            PaneSection(title: "Models for each task") {
                Text("Each task tries its models in order; a later one takes over when an earlier one fails.")
                    .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                ForEach(TaskID.catalog, id: \.self) { task in
                    TaskRoute(task: task, chain: chainBinding(task), providers: draft.providers)
                }
            }
            PaneSection(title: "Daily budget") {
                Stepper(
                    "Up to \(draft.budget.dailyCalls) calls a day", value: $draft.budget.dailyCalls, in: 20...5_000,
                    step: 20)
            }
            PaneSection(title: "Today") {
                if today.isEmpty {
                    Text("No calls yet today.").font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                }
                ForEach(Array(today.enumerated()), id: \.offset) { _, day in
                    FactRow(
                        label: "\(day.provider)/\(day.model)",
                        value: "\(day.answered) answered · \(day.failed) failed"
                            + (day.averageSeconds.map { " · \(String(format: "%.1f", $0)) s" } ?? ""))
                }
            }
        }
        .onChange(of: draft) { save() }
        .task {
            let start = Calendar.current.startOfDay(for: Date())
            today = (try? await model.workspace?.store.ai.today(since: start)) ?? []
        }
    }

    private func chainBinding(_ task: TaskID) -> Binding<[ModelRef]> {
        Binding(get: { draft.chain(for: task) }, set: { draft.routes[task.rawValue] = $0 })
    }

    private func hint(_ name: String) -> String {
        guard let secrets = model.workspace?.secrets, let summary = try? secrets.summary(SecretKey(name)) else {
            return "missing"
        }
        return summary.hint ?? "saved"
    }

    private func addKey(to provider: String) {
        guard let secrets = model.workspace?.secrets,
            let value = newKey[provider]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty, let index = draft.providers.firstIndex(where: { $0.id == provider })
        else { return }
        let name = "\(provider).\(draft.providers[index].keyNames.count + 1)"
        try? secrets.write(value, for: SecretKey(name))
        draft.providers[index].keyNames.append(name)
        newKey[provider] = nil
    }

    private func removeKey(_ name: String, from provider: String) {
        guard let index = draft.providers.firstIndex(where: { $0.id == provider }) else { return }
        try? model.workspace?.secrets.delete(SecretKey(name))
        draft.providers[index].keyNames.removeAll { $0 == name }
    }

    private func save() {
        model.saveAISettings(draft)
    }
}

/// One task's chain of models.
struct TaskRoute: View {
    let task: TaskID
    @Binding var chain: [ModelRef]
    let providers: [AISettings.Provider]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            Text(Self.title(task)).font(TypeStyle.headline)
            ForEach(Array(chain.enumerated()), id: \.offset) { index, ref in
                HStack {
                    Picker(
                        "Provider",
                        selection: Binding(
                            get: { ref.provider },
                            set: { chain[index] = ModelRef(provider: $0, model: ref.model) })
                    ) {
                        ForEach(providers) { Text($0.displayName).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    TextField(
                        "Model",
                        text: Binding(
                            get: { ref.model }, set: { chain[index] = ModelRef(provider: ref.provider, model: $0) })
                    )
                    .font(TypeStyle.mono)
                    Button {
                        chain.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Add a model") {
                if let provider = providers.first { chain.append(ModelRef(provider: provider.id, model: "")) }
            }
            .buttonStyle(.plain).foregroundStyle(Color(.accentText)).font(TypeStyle.callout)
        }
        .padding(.vertical, Spacing.space1)
    }

    static func title(_ task: TaskID) -> String {
        switch task {
        case .analyzeJob: "Analyse a posting"
        case .suggestEvidence: "Suggest evidence (Improve)"
        case .writeExperience: "Write experience"
        case .writeProjects: "Write projects"
        case .writeSkills: "Write skills"
        case .writeSummary: "Write a summary"
        case .shortenBullets: "Shorten bullets"
        case .gapBullets: "Stretch bullets"
        case .coverLetter: "Write a cover letter"
        case .importResume: "Import a resume"
        case .importGitHubRepo: "Import a GitHub project"
        default: task.rawValue
        }
    }
}
