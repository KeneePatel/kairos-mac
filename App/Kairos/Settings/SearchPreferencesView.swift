import Screening
import Store
import SwiftUI

/// Settings › Search: what the prefilter and verdict look for (SPEC §5.2; the "Search for" panel in
/// `Sources.dc.html`). Every rule is off until you set it. Changes apply to the next run, or now
/// with "Screen again".
struct SearchPreferencesView: View {
    @Environment(AppModel.self) private var model
    @State private var preferences = SearchPreferences()
    @State private var regions: [Country: String] = [:]
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.space6) {
                FormSection(
                    title: "Job titles",
                    caption: "A title must contain one of these. Leave it empty to see every title."
                ) {
                    PhraseList(items: $preferences.titleInclude, prompt: "Add a job title, such as Backend Developer")
                }
                FormSection(title: "Skip titles containing", caption: "Skipped before any AI runs.") {
                    PhraseList(items: $preferences.titleExclude, prompt: "Add a word, such as Manager")
                }
                FormSection(
                    title: "Levels",
                    caption: "A title naming a level you've turned off is skipped. Most titles name none."
                ) {
                    FlowLayout(spacing: Spacing.space3) {
                        ForEach(Seniority.allCases, id: \.self) { level in
                            Toggle(level.title, isOn: levelBinding(level)).toggleStyle(.checkbox)
                        }
                    }
                }
                FormSection(title: "Countries", caption: "Order sets how Today groups and ranks jobs.") { countries }
                FormSection(title: "Limits") { limits }
                FormSection(title: "Blocked companies", caption: "Never shown, whatever the role.") {
                    PhraseList(items: $preferences.blacklist, prompt: "Add a company")
                }
                FormSection(
                    title: "Verdict", caption: "How much of a posting's must-haves your skills need to cover."
                ) { thresholds }
                Divider()
                WorkAuthorizationView()
                Divider()
                screenAgain
            }
            .padding(Spacing.space6)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            guard !loaded else { return }
            preferences = model.searchPreferences
            for country in Country.allCases {
                regions[country] = preferences.regions[country.rawValue]?.joined(separator: ", ") ?? ""
            }
            loaded = true
        }
        .onChange(of: preferences) { _, changed in
            guard loaded else { return }
            Task { await model.save(changed) }
        }
    }

    // MARK: - Countries

    /// Your countries in order, then the ones you've left out.
    private var orderedCountries: [Country] {
        preferences.countries + Country.allCases.filter { !preferences.countries.contains($0) }
    }

    private var countries: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            VStack(spacing: 0) {
                ForEach(Array(orderedCountries.enumerated()), id: \.element) { index, country in
                    if index > 0 { Divider().overlay(Color(.separatorRow)) }
                    countryRow(country, position: preferences.countries.firstIndex(of: country))
                }
            }
            .background(RoundedRectangle(cornerRadius: Radius.row).fill(Color(.surfaceGrouped)))
            Toggle("Remote jobs", isOn: $preferences.remoteAllowed).toggleStyle(.switch)
                .help("Off: only on-site and hybrid jobs.")
        }
    }

    private func countryRow(_ country: Country, position: Int?) -> some View {
        HStack(spacing: Spacing.space3) {
            Text(position.map { "\($0 + 1)" } ?? "–").font(TypeStyle.headline).monospacedDigit()
                .foregroundStyle(Color(.inkSecondary)).frame(width: 18)
            Toggle(country.displayName, isOn: countryBinding(country)).toggleStyle(.checkbox)
                .frame(width: 140, alignment: .leading)
            TextField(
                "\(country.regionsName) for on-site work", text: regionBinding(country),
                prompt: Text("\(country.regionsName) for on-site work: any (or ON, BC)")
            )
            .onSubmit { commitRegions(country) }
            .disabled(position == nil)
            Button {
                moveUp(country)
            } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled((position ?? 0) == 0)
            .help("Rank \(country.displayName) jobs first")
            .accessibilityLabel("Move \(country.displayName) up")
        }
        .padding(.horizontal, Spacing.space3)
        .frame(minHeight: 40)
    }

    private func countryBinding(_ country: Country) -> Binding<Bool> {
        Binding(
            get: { preferences.countries.contains(country) },
            set: { include in
                if include {
                    if !preferences.countries.contains(country) { preferences.countries.append(country) }
                } else if preferences.countries.count > 1 {
                    preferences.countries.removeAll { $0 == country }  // keep at least one
                }
            })
    }

    private func regionBinding(_ country: Country) -> Binding<String> {
        Binding(get: { regions[country] ?? "" }, set: { regions[country] = $0 })
    }

    /// "on, bc" or "ON BC" become ["ON", "BC"]; empty means anywhere in the country.
    private func commitRegions(_ country: Country) {
        let codes = (regions[country] ?? "").split { $0 == "," || $0.isWhitespace }.map { $0.uppercased() }
        preferences.regions[country.rawValue] = codes.isEmpty ? nil : codes
        regions[country] = codes.joined(separator: ", ")
    }

    private func moveUp(_ country: Country) {
        guard let index = preferences.countries.firstIndex(of: country), index > 0 else { return }
        preferences.countries.swapAt(index, index - 1)
    }

    // MARK: - Limits and verdict

    private var limits: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            optionalStepper(
                "Skip jobs asking for more than", unit: "years", value: $preferences.maxYearsRequired, start: 8,
                range: 1...30, step: 1)
            // How recent a posting must be is on the Fetch screen ("Posted"), since it acts while fetching.
        }
    }

    private func optionalStepper(
        _ title: String, unit: String, value: Binding<Int?>, start: Int, range: ClosedRange<Int>, step: Int
    ) -> some View {
        HStack(spacing: Spacing.space2) {
            Toggle(
                title,
                isOn: Binding(get: { value.wrappedValue != nil }, set: { value.wrappedValue = $0 ? start : nil })
            )
            .toggleStyle(.checkbox)
            if let current = value.wrappedValue {
                Stepper(
                    "\(current) \(unit)", value: Binding(get: { current }, set: { value.wrappedValue = $0 }), in: range,
                    step: step
                )
                .monospacedDigit()
            }
        }
    }

    private var thresholds: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Stepper(
                "Yes when your skills cover \(percent(preferences.thresholds.yesAt)) of them",
                value: percentBinding(\.yesAt), in: 50...100, step: 5
            )
            .monospacedDigit()
            Stepper(
                "Maybe from \(percent(preferences.thresholds.maybeAt)); below that, No",
                value: percentBinding(\.maybeAt), in: 10...max(10, percentValue(preferences.thresholds.yesAt) - 5),
                step: 5
            )
            .monospacedDigit()
        }
    }

    private func percent(_ share: Double) -> String { "\(percentValue(share))%" }
    private func percentValue(_ share: Double) -> Int { Int((share * 100).rounded()) }

    private func percentBinding(_ path: WritableKeyPath<VerdictThresholds, Double>) -> Binding<Int> {
        Binding(
            get: { percentValue(preferences.thresholds[keyPath: path]) },
            set: { preferences.thresholds[keyPath: path] = Double($0) / 100 })
    }

    private func levelBinding(_ level: Seniority) -> Binding<Bool> {
        Binding(
            get: { preferences.seniority.contains(level) },
            set: { on in
                if on { preferences.seniority.insert(level) } else { preferences.seniority.remove(level) }
            })
    }

    // MARK: - Screen again

    private var screenAgain: some View {
        HStack(alignment: .center, spacing: Spacing.space4) {
            Text(
                "Changes apply from the next run. To apply them to the jobs you already have, screen again: stored analyses are reused, so it needs few or no AI calls. Your own verdicts stay."
            )
            .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Screen again") { model.screenAgain() }
                .controlSize(.large)
                .disabled(model.isFetching)
        }
    }
}

/// Phrases as removable chips, plus a field to add one (Return adds it).
struct PhraseList: View {
    @Binding var items: [String]
    let prompt: String
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            if !items.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(items, id: \.self) { item in
                        HStack(spacing: 4) {
                            Text(item).font(TypeStyle.callout).foregroundStyle(Color(.ink))
                            Button {
                                items.removeAll { $0 == item }
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color(.inkSecondary))
                            .accessibilityLabel("Remove \(item)")
                        }
                        .padding(.horizontal, Spacing.space2)
                        .frame(height: 24)
                        .background(Capsule().fill(Color(.controlFill)))
                    }
                }
            }
            TextField(prompt, text: $draft, prompt: Text(prompt))
                .onSubmit(add)
                .frame(maxWidth: 360)
        }
    }

    private func add() {
        let phrase = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return }
        if !items.contains(where: { $0.caseInsensitiveCompare(phrase) == .orderedSame }) { items.append(phrase) }
        draft = ""
    }
}
