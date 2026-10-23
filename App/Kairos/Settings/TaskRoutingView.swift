import LLM
import SwiftUI

extension TaskID {
    /// What the task does, in the words the Settings table uses.
    var displayName: String {
        switch self {
        case .importResume: "Import a resume"
        case .importGitHubRepo: "Import GitHub projects"
        case .triage: "Quick relevance check"
        case .analyzeJob: "Read job postings"
        case .select: "Pick the best bullets"
        case .writeSummary: "Write the summary"
        case .writeSkills: "Write the skills section"
        case .writeExperience: "Write experience"
        case .writeProjects: "Write projects"
        case .rewriteSection: "Rewrite weak sections"
        case .gapBullets: "Stretch mode bullets"
        case .coverLetter: "Write cover letters"
        case .suggestEvidence: "Suggest how to show a skill"
        case .shortenBullets: "Shorten bullets to fit lines"
        default: rawValue
        }
    }
}

/// "Which model does what" (decided 2026-10-23): one-click setups, then each job as an ordered
/// chain of models with how each has done today, the per-task table folded under it, and the
/// daily budget.
struct TaskRoutingView: View {
    @Environment(AISettingsModel.self) private var model
    @State private var showingTasks = false

    var body: some View {
        FormSection(
            title: "Which model does what",
            caption:
                "Each job tries its models in order: when one is down or slow, the next takes over. When the budget is reached, AI steps wait until midnight."
        ) {
            VStack(alignment: .leading, spacing: Spacing.space4) {
                setups
                ForEach(AIJob.allCases) { job in JobChainCard(job: job) }
                DisclosureGroup("Each task on its own", isExpanded: $showingTasks) {
                    VStack(spacing: 0) {
                        header
                        ForEach(TaskID.catalog.filter { $0 != .triage }, id: \.self) { task in
                            Divider().overlay(Color(.separatorRow))
                            row(task)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: Radius.group).fill(Color(.surfaceGrouped)))
                    .padding(.top, Spacing.space2)
                }
                .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                budget
            }
        }
    }

    /// The setups your providers allow, each in one click.
    @ViewBuilder private var setups: some View {
        let setups = model.setups
        if !setups.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.space2) {
                Text("Recommended setups").font(TypeStyle.headline).foregroundStyle(Color(.ink))
                HStack(alignment: .top, spacing: Spacing.space3) {
                    ForEach(setups) { setup in
                        VStack(alignment: .leading, spacing: Spacing.space2) {
                            Text(setup.title).font(TypeStyle.headline).foregroundStyle(Color(.ink))
                            Text(setup.detail).font(TypeStyle.callout).foregroundStyle(Color(.ink2))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            if model.isInUse(setup) {
                                Label("In use", systemImage: "checkmark.circle.fill")
                                    .font(TypeStyle.callout.weight(.medium)).foregroundStyle(Color(.yes))
                            } else {
                                PillButton(title: "Use this", symbol: "wand.and.stars") {
                                    Task { await model.apply(setup) }
                                }
                            }
                        }
                        .padding(Spacing.space3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: Radius.group).fill(Color(.surfaceGrouped)))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.space3) {
            Text("Task").frame(maxWidth: .infinity, alignment: .leading)
            Text("Model").frame(width: 230, alignment: .leading)
            Text("Fallback").frame(width: 230, alignment: .leading)
            Text("Runs on").frame(width: 80, alignment: .leading)
        }
        .font(TypeStyle.caption).foregroundStyle(Color(.inkSecondary))
        .padding(.horizontal, Spacing.space3).frame(height: 32)
    }

    private func row(_ task: TaskID) -> some View {
        let primary = model.primary(for: task)
        let fallback = model.fallback(for: task)
        return HStack(spacing: Spacing.space3) {
            Text(task.displayName).font(TypeStyle.body).foregroundStyle(Color(.ink))
                .frame(maxWidth: .infinity, alignment: .leading)
            picker("Model for \(task.displayName)", selection: primary, allowNone: false) { ref in
                Task { await model.setRoute(task, primary: ref, fallback: fallback) }
            }
            .frame(width: 230, alignment: .leading)
            picker("Fallback for \(task.displayName)", selection: fallback, allowNone: true) { ref in
                Task { await model.setRoute(task, primary: primary, fallback: ref) }
            }
            .frame(width: 230, alignment: .leading)
            Text(runsOn(primary)).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                .frame(width: 80, alignment: .leading)
        }
        .padding(.horizontal, Spacing.space3).frame(minHeight: 40)
    }

    private func picker(
        _ title: String, selection: ModelRef?, allowNone: Bool, set: @escaping @Sendable (ModelRef?) -> Void
    ) -> some View {
        Picker(title, selection: Binding(get: { selection }, set: set)) {
            if allowNone || selection == nil { Text("None").tag(ModelRef?.none) }
            ForEach(model.choices(), id: \.provider.id) { choice in
                if !choice.models.isEmpty {
                    Section(choice.provider.preset.name) {
                        ForEach(choice.models, id: \.self) { id in
                            Text(id).tag(ModelRef?.some(ModelRef(provider: choice.provider.id, model: id)))
                        }
                    }
                }
            }
        }
        .labelsHidden()
    }

    private func runsOn(_ ref: ModelRef?) -> String {
        guard let ref, let provider = model.settings.provider(ref.provider) else { return "—" }
        return provider.preset.isLocal ? "This Mac" : provider.preset.name.replacing("Google Gemini", with: "Google")
    }

    private var budget: some View {
        HStack(spacing: Spacing.space3) {
            Text("Daily AI budget").font(TypeStyle.headline).foregroundStyle(Color(.ink))
            Stepper(
                "\(model.settings.budget.dailyCalls) calls",
                value: Binding(
                    get: { model.settings.budget.dailyCalls },
                    set: { calls in Task { await model.setDailyCalls(calls) } }), in: 10...5_000, step: 50
            )
            .monospacedDigit()
            Spacer()
            Text("\(model.usedToday) used today").font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                .monospacedDigit()
        }
        .padding(.top, Spacing.space2)
    }
}

/// What leaves the Mac, what never does, and the private option (SPEC §5.5, Privacy).
struct PrivacyPanel: View {
    @Environment(AISettingsModel.self) private var model

    var body: some View {
        FormSection(title: "Privacy", caption: "Exactly what Kairos sends, and where.") {
            VStack(alignment: .leading, spacing: Spacing.space4) {
                fact(
                    "Leaves this Mac, to the provider you chose",
                    "Job posting text, the master-resume bullets picked for that job, and your skill names with whether each is Proven.",
                    symbol: "arrow.up.forward.circle")
                fact(
                    "Never sent",
                    "Your name, email, phone, LinkedIn, GitHub and portfolio links. Kairos adds them on this Mac when it makes the PDF.",
                    symbol: "lock.circle")
                fact(
                    "Google's free tier",
                    "Google's terms for the unpaid Gemini API let it use what you send to improve its products. Ollama keeps everything on this Mac.",
                    symbol: "info.circle")
                localToggle
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.group).fill(Color(.surfaceGrouped)))
        }
    }

    private func fact(_ title: String, _ detail: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
            Image(systemName: symbol).foregroundStyle(Color(.inkSecondary)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TypeStyle.headline).foregroundStyle(Color(.ink))
                Text(detail).font(TypeStyle.callout).foregroundStyle(Color(.ink2)).fixedSize(
                    horizontal: false, vertical: true)
            }
        }
    }

    /// Every task on the first local model, when one is installed.
    @ViewBuilder private var localToggle: some View {
        let local = model.choices().first { $0.provider.preset.isLocal && !$0.models.isEmpty }
        let allLocal = model.settings.routes.values.allSatisfy { chain in
            chain.allSatisfy { model.settings.provider($0.provider)?.preset.isLocal == true }
        }
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Keep everything on this Mac").font(TypeStyle.headline).foregroundStyle(Color(.ink))
                Text(
                    local.map { "Use \($0.models[0]) in Ollama for every task. Slower, no daily caps." }
                        ?? "Install a model in Ollama first."
                )
                .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            }
            Spacer()
            Toggle(
                "Keep everything on this Mac",
                isOn: Binding(
                    get: { allLocal },
                    set: { on in
                        guard on, let local else { return }
                        Task { await model.keepEverythingLocal(on: local.models[0], providerID: local.provider.id) }
                    })
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(local == nil || allLocal)
        }
    }
}

/// One job: its models in the order they're tried, how each did today, and what to change.
private struct JobChainCard: View {
    @Environment(AISettingsModel.self) private var model
    let job: AIJob

    private var chain: [ModelRef] { model.settings.chain(for: job) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Text(job.title).font(TypeStyle.headline).foregroundStyle(Color(.ink))
            Text(job.detail).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                .fixedSize(horizontal: false, vertical: true)
            if !model.settings.isUniform(job) {
                Label("Some of its tasks are set on their own below.", systemImage: "slider.horizontal.3")
                    .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            }
            VStack(spacing: 0) {
                ForEach(Array(chain.enumerated()), id: \.element) { index, ref in
                    if index > 0 { Divider().overlay(Color(.separatorRow)) }
                    row(index, ref)
                }
            }
            .background(RoundedRectangle(cornerRadius: Radius.row).fill(Color(.surfaceGrouped)))
            HStack {
                if chain.count < AIJob.maxChain { addMenu }
                if chain.count == 1 {
                    Label(
                        "Nothing to fall back on if this model is down.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(TypeStyle.callout).foregroundStyle(Color(.maybe))
                }
            }
        }
    }

    private func row(_ index: Int, _ ref: ModelRef) -> some View {
        HStack(spacing: Spacing.space3) {
            Text(index == 0 ? "First" : "Then").font(TypeStyle.callout.weight(.semibold))
                .foregroundStyle(Color(.inkSecondary)).frame(width: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(ref.model).font(.system(.callout, design: .monospaced)).foregroundStyle(Color(.ink))
                Text(caption(ref)).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            }
            Spacer()
            health(ref)
            if index > 0 {
                Button("Move up", systemImage: "arrow.up") { move(index) }.labelStyle(.iconOnly)
                    .buttonStyle(.borderless).help("Try it earlier")
            }
            if chain.count > 1 {
                Button("Remove", systemImage: "minus.circle") { remove(index) }.labelStyle(.iconOnly)
                    .buttonStyle(.borderless).help("Stop using it for \(job.title.lowercased())")
            }
        }
        .padding(.horizontal, Spacing.space3).padding(.vertical, 6)
    }

    /// Where it runs, and what the guide says it costs.
    private func caption(_ ref: ModelRef) -> String {
        let provider = model.settings.provider(ref.provider)
        let place = provider.map { $0.preset.isLocal ? "This Mac" : $0.preset.name } ?? ref.provider
        guard let guide = ModelGuide.entry(for: ref.model), provider?.presetID == ProviderPreset.ollamaCloud.id else {
            return place
        }
        return "\(place) · \(guide.costLine)"
    }

    /// Today's record, as an icon and words with the colour.
    @ViewBuilder private func health(_ ref: ModelRef) -> some View {
        if let health = model.health[ref], health.calls > 0 {
            let time = health.averageSeconds.map { "\(Int($0.rounded())) s" } ?? "no answers"
            let words = "\(time) · \(health.failed) of \(health.calls) failed today"
            if health.failed * 2 > health.calls {
                Label(words, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color(.error))
                    .font(TypeStyle.callout)
            } else {
                Label(words, systemImage: "checkmark.circle.fill").foregroundStyle(Color(.inkSecondary))
                    .font(TypeStyle.callout)
            }
        } else {
            Text("not used today").font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(model.choices(), id: \.provider.id) { choice in
                let open = choice.models.filter { !chain.contains(ModelRef(provider: choice.provider.id, model: $0)) }
                if !open.isEmpty {
                    Section(choice.provider.preset.name) {
                        ForEach(open, id: \.self) { id in
                            Button(id) { add(ModelRef(provider: choice.provider.id, model: id)) }
                        }
                    }
                }
            }
        } label: {
            PillLabel(title: chain.isEmpty ? "Choose a model" : "Add a model to fall back on", symbol: "plus")
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private func add(_ ref: ModelRef) { Task { await model.setChain(chain + [ref], for: job) } }

    private func remove(_ index: Int) {
        var changed = chain
        changed.remove(at: index)
        Task { await model.setChain(changed, for: job) }
    }

    private func move(_ index: Int) {
        var changed = chain
        changed.swapAt(index, index - 1)
        Task { await model.setChain(changed, for: job) }
    }
}
