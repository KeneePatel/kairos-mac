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
        default: rawValue
        }
    }
}

/// "Which model does what": a model and an optional fallback per task, and the daily budget.
struct TaskRoutingView: View {
    @Environment(AISettingsModel.self) private var model

    var body: some View {
        FormSection(
            title: "Which model does what",
            caption:
                "When a task's model fails it tries the fallback. When the budget is reached, AI steps wait until midnight."
        ) {
            VStack(spacing: 0) {
                header
                ForEach(TaskID.catalog.filter { $0 != .triage }, id: \.self) { task in
                    Divider().overlay(Color(.separatorRow))
                    row(task)
                }
            }
            .background(RoundedRectangle(cornerRadius: Radius.group).fill(Color(.surfaceGrouped)))
            budget
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
