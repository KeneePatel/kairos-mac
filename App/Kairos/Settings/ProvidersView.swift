import LLM
import SwiftUI

/// AI providers: one card per provider, which model does each task, and what leaves the Mac.
struct ProvidersView: View {
    @Environment(AISettingsModel.self) private var model
    @State private var addingCustom = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.space6) {
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(TypeStyle.callout).foregroundStyle(Color(.error))
                }
                FormSection(title: "Providers", caption: "Your own keys, kept on this Mac only.") {
                    Menu {
                        ForEach(model.addablePresets) { preset in
                            Button(preset.name) { Task { await model.add(preset) } }
                        }
                        if !model.addablePresets.isEmpty { Divider() }
                        Button("Custom address…") { addingCustom = true }
                    } label: {
                        PillLabel(title: "Add provider", symbol: "plus")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                } content: {
                    VStack(spacing: Spacing.space3) {
                        ForEach(model.settings.providers) { provider in
                            ProviderCard(provider: provider)
                        }
                    }
                }
                Divider()
                TaskRoutingView()
                Divider()
                PrivacyPanel()
            }
            .padding(Spacing.space6)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $addingCustom) { CustomProviderSheet() }
    }
}

/// One provider: status, keys (primary first, then backups used when it hits a cap), usage, models.
private struct ProviderCard: View {
    @Environment(AISettingsModel.self) private var model
    let provider: LLMSettings.Provider
    @State private var keySheet: KeySheet.Mode?
    @State private var confirmingRemoval = false

    private var preset: ProviderPreset { provider.preset }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name).font(.system(size: 14, weight: .bold)).foregroundStyle(Color(.ink))
                    Text(subtitle).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                }
                Spacer()
                status
            }
            if preset.needsKey || !provider.keyNames.isEmpty {
                keys
            }
            models
            HStack {
                Text(usageLine).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).monospacedDigit()
                if !preset.plans.isEmpty {
                    Picker(
                        "Plan",
                        selection: Binding(
                            get: { provider.plan ?? preset.plans[0].id },
                            set: { plan in Task { await model.setPlan(plan, for: provider.id) } })
                    ) {
                        ForEach(preset.plans) { plan in
                            Text("\(plan.name) · \(plan.concurrent) at a time").tag(plan.id)
                        }
                    }
                    .fixedSize()
                    .help("Your plan on \(preset.name): Kairos sends no more calls at once than it allows.")
                }
                Stepper(
                    "\(model.requestsPerMinute(for: provider.id)) requests a minute",
                    value: Binding(
                        get: { model.requestsPerMinute(for: provider.id) },
                        set: { value in Task { await model.setRequestsPerMinute(value, for: provider.id) } }),
                    in: 1...1_000
                )
                .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).monospacedDigit()
                .help("Kairos stays under this so the provider doesn't refuse requests. Raise it on a paid plan.")
                Spacer()
                if preset.needsKey {
                    PillButton(title: provider.keyNames.isEmpty ? "Add key" : "Add backup key", symbol: "key") {
                        keySheet = .add
                    }
                }
                PillButton(title: preset.isLocal ? "Refresh" : "Test", symbol: "arrow.clockwise") {
                    Task { await model.refreshModels(for: provider.id) }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Radius.group).fill(Color(.surface)))
        .overlay(RoundedRectangle(cornerRadius: Radius.group).strokeBorder(Color(.separator)))
        .contextMenu {
            Button("Remove \(preset.name)…", role: .destructive) { confirmingRemoval = true }
        }
        .sheet(item: $keySheet) { mode in KeySheet(provider: provider, mode: mode) }
        .confirmationDialog("Remove \(preset.name)?", isPresented: $confirmingRemoval) {
            Button("Remove", role: .destructive) { Task { await model.remove(provider.id) } }
        } message: {
            Text("Its keys are deleted from this Mac, and tasks that used it fall back to their other models.")
        }
        .task { if model.models[provider.id] == nil { await model.refreshModels(for: provider.id) } }
    }

    private var subtitle: String {
        if preset.isLocal { return preset.baseURL.replacing("http://", with: "").replacing("/v1/", with: "") }
        return preset.id == "gemini" ? "Google AI Studio API keys" : preset.baseURL
    }

    private var usageLine: String {
        let calls = model.usage[provider.id]?.calls ?? 0
        let today = "\(calls) call\(calls == 1 ? "" : "s") today"
        if preset.isLocal { return today + " · nothing leaves this Mac" }
        guard let spent = model.spentThisMonth[provider.id] else { return today }
        // Ollama bills in US dollars: "$0.04", not the locale's "US$0.04".
        return today + " · about $" + spent.formatted(.number.precision(.fractionLength(2))) + " this month"
    }

    /// Always an icon and a word with the colour.
    @ViewBuilder private var status: some View {
        switch model.models[provider.id] {
        case .loaded?:
            label(preset.isLocal ? "Running" : "Connected", "checkmark.circle.fill", Color(.yes))
        case .loading?:
            ProgressView().controlSize(.small)
        case .failed(let message)?:
            label(
                preset.needsKey && provider.keyNames.isEmpty ? "No key yet" : "Not connected",
                "exclamationmark.triangle.fill", Color(.error)
            )
            .help(message)
        case .unknown?, nil:
            label("Not checked", "circle.dashed", Color(.inkSecondary))
        }
    }

    private func label(_ text: String, _ symbol: String, _ color: Color) -> some View {
        Label(text, systemImage: symbol).font(TypeStyle.callout.weight(.medium)).foregroundStyle(color)
    }

    private var keys: some View {
        VStack(spacing: 0) {
            ForEach(Array(provider.keyNames.enumerated()), id: \.element) { index, name in
                if index > 0 { Divider().overlay(Color(.separatorRow)) }
                // Redrawn each minute so "back in about…" stays true while Settings is open.
                TimelineView(.everyMinute) { _ in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: Spacing.space3) {
                            Text(index == 0 ? "Primary" : "Backup").font(TypeStyle.headline).foregroundStyle(
                                Color(.ink)
                            )
                            .frame(width: 70, alignment: .leading)
                            if index > 0 {
                                Text("used when Primary hits a cap").font(TypeStyle.callout).foregroundStyle(
                                    Color(.inkSecondary))
                            }
                            Spacer()
                            check(name)
                            Text(model.masked[name] ?? "Not on this Mac").font(.system(.callout, design: .monospaced))
                                .foregroundStyle(Color(.ink2))
                            // A key named in your settings but not saved here (such as one from the
                            // Keychain, before keys moved to a file) can be pasted again in place.
                            let missing = model.masked[name] == nil
                            Button(missing ? "Add" : index == 0 ? "Replace" : "Remove") {
                                if missing || index == 0 {
                                    keySheet = .replace(name)
                                } else {
                                    Task { await model.removeKey(name, from: provider.id) }
                                }
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color(.accentText))
                        }
                        if let line = model.restLine(for: name, of: provider.id) {
                            Label {
                                Text("Used up: \(line)").foregroundStyle(Color(.inkSecondary))
                            } icon: {
                                Image(systemName: "hourglass").foregroundStyle(Color(.maybe))
                            }
                            .font(TypeStyle.callout)
                            .padding(.leading, 70 + Spacing.space3)
                        }
                    }
                }
                .padding(.horizontal, Spacing.space3)
                .padding(.vertical, 6)
                .frame(minHeight: 36)
            }
            if provider.keyNames.isEmpty {
                Text(
                    preset.id == "gemini"
                        ? "No key yet. Get one free from Google AI Studio, then choose Add key."
                        : "No key yet. Add one to use \(preset.name)."
                )
                .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.space3)
            }
        }
        .background(RoundedRectangle(cornerRadius: Radius.row).fill(Color(.surfaceGrouped)))
    }

    /// What "Test" found for this key, as an icon and a word with the colour.
    @ViewBuilder private func check(_ name: String) -> some View {
        switch model.keyChecks[name] {
        case .checking?: ProgressView().controlSize(.mini)
        case .works?: label("Works", "checkmark.circle.fill", Color(.yes))
        case .rejected?: label("Rejected", "xmark.octagon.fill", Color(.error))
        case .failed(let message)?:
            label("Not checked", "exclamationmark.triangle.fill", Color(.inkSecondary)).help(message)
        case nil: EmptyView()
        }
    }

    @ViewBuilder private var models: some View {
        if case .loaded(let ids) = model.models[provider.id], ids.contains(where: { ModelGuide.entry(for: $0) != nil })
        {
            ModelGuideList(ids: ids)
        } else if case .loaded(let ids) = model.models[provider.id] {
            VStack(alignment: .leading, spacing: 6) {
                Text(ids.isEmpty ? "No models installed" : "\(ids.count) model\(ids.count == 1 ? "" : "s") available")
                    .font(TypeStyle.callout.weight(.semibold)).foregroundStyle(Color(.ink))
                FlowLayout(spacing: 6) {
                    ForEach(ids.prefix(8), id: \.self) { id in
                        Text(id).font(.system(.callout, design: .monospaced)).foregroundStyle(Color(.ink2))
                            .padding(.horizontal, Spacing.space2).frame(height: 22)
                            .background(RoundedRectangle(cornerRadius: Radius.chip).fill(Color(.chipMetricBg)))
                    }
                }
            }
        } else if case .failed(let message) = model.models[provider.id] {
            Text(message).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
        }
    }
}

/// Paste a key: it's saved on this Mac only and is only ever shown masked afterwards.
private struct KeySheet: View {
    enum Mode: Identifiable, Hashable {
        case add
        case replace(String)
        var id: Self { self }
    }

    @Environment(AISettingsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let provider: LLMSettings.Provider
    let mode: Mode
    @State private var key = ""
    @FocusState private var focused: Bool

    private var isBackup: Bool { mode == .add && !provider.keyNames.isEmpty }

    private var title: String {
        switch mode {
        case .add: isBackup ? "Add a backup key for \(provider.preset.name)" : "Add a key for \(provider.preset.name)"
        case .replace(let name): model.masked[name] == nil ? "Paste this key again" : "Replace the primary key"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space5) {
            VStack(alignment: .leading, spacing: Spacing.space1) {
                Text(title).font(TypeStyle.title3).foregroundStyle(Color(.ink))
                Text(
                    "It's saved on this Mac only, in a file only you can read. Kairos shows only its first and last characters."
                )
                .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            }
            if isBackup {
                Label {
                    Text(
                        provider.preset.id == "gemini"
                            ? "Kairos switches to a backup when a key runs out. Gemini counts quota per Google Cloud project, so a backup adds requests only if it's from a different project."
                            : "Kairos switches to a backup when a key runs out."
                    )
                    .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            }
            LabeledField(title: "API key") {
                SecureField("API key", text: $key, prompt: Text("Paste the key"))
                    .focused($focused)
                    .onSubmit(save)
            }
            HStack(spacing: Spacing.space2) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(mode == .add ? "Add key" : "Replace", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.large)
        }
        .padding(Spacing.space6)
        .frame(width: 480)
        .onAppear { focused = true }
    }

    private func save() {
        let key = self.key
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            switch mode {
            case .add: await model.addKey(key, to: provider.id)
            case .replace(let name): await model.replaceKey(name, with: key, for: provider.id)
            }
        }
        dismiss()
    }
}

/// Any OpenAI-compatible endpoint: a self-hosted gateway, LM Studio, and so on.
private struct CustomProviderSheet: View {
    @Environment(AISettingsModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space5) {
            VStack(alignment: .leading, spacing: Spacing.space1) {
                Text("Add a provider by address").font(TypeStyle.title3).foregroundStyle(Color(.ink))
                Text("Any service that speaks the OpenAI chat API. Add keys afterwards if it needs them.")
                    .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            }
            LabeledField(title: "Name", optional: true) {
                TextField("Name", text: $name, prompt: Text("LM Studio"))
            }
            LabeledField(title: "Base address", error: error) {
                TextField("Base address", text: $address, prompt: Text("http://localhost:1234/v1"))
                    .onSubmit(save)
            }
            HStack(spacing: Spacing.space2) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add provider", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.large)
        }
        .padding(Spacing.space6)
        .frame(width: 480)
    }

    private func save() {
        let (name, address) = (self.name, self.address)
        Task {
            if let problem = await model.addCustom(name: name, baseURL: address) {
                error = problem
            } else {
                dismiss()
            }
        }
    }
}

/// The live models a provider lists, as the guide judges them for resumes: what to use, what to
/// fall back on, what's worth a try with credits, and what isn't worth it (folded away).
private struct ModelGuideList: View {
    let ids: [String]
    @State private var showingSkipped = false

    private func entries(_ advice: ModelGuide.Advice) -> [(id: String, guide: ModelGuide)] {
        ids.compactMap { id in ModelGuide.entry(for: id).map { (id, $0) } }.filter { $0.guide.advice == advice }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Text("Model guide for resumes").font(TypeStyle.callout.weight(.semibold)).foregroundStyle(Color(.ink))
            group("Use", .recommended)
            group("Fall back on", .fallback)
            group("Worth a try", .untried)
            let skipped = entries(.skip)
            if !skipped.isEmpty {
                DisclosureGroup("Not worth it for resumes (\(skipped.count))", isExpanded: $showingSkipped) {
                    VStack(alignment: .leading, spacing: Spacing.space2) {
                        ForEach(skipped, id: \.id) { row($0.id, $0.guide) }
                    }
                    .padding(.top, Spacing.space1)
                }
                .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            }
            Text("Prices from Ollama's pricing page and advice from Kairos's own test builds, October 23, 2026.")
                .font(TypeStyle.caption).foregroundStyle(Color(.inkSecondary))
        }
        .padding(Spacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.row).fill(Color(.surfaceGrouped)))
    }

    @ViewBuilder private func group(_ title: String, _ advice: ModelGuide.Advice) -> some View {
        let found = entries(advice)
        if !found.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.space2) {
                Text(title).font(TypeStyle.caption.weight(.semibold)).foregroundStyle(Color(.inkSecondary))
                ForEach(found, id: \.id) { row($0.id, $0.guide) }
            }
        }
    }

    private func row(_ id: String, _ guide: ModelGuide) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
                Text(id).font(.system(.callout, design: .monospaced)).foregroundStyle(Color(.ink))
                Text(guide.costLine).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            }
            Text(guide.note).font(TypeStyle.callout).foregroundStyle(Color(.ink2))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
