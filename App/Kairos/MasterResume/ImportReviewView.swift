import LLM
import MasterResume
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// One import: the resume text, the draft the model made from it, and what you've chosen to keep.
@MainActor
@Observable
final class ImportSession: Identifiable {
    enum Step: Equatable {
        case source, working, review
        case failed(String)
    }

    var step = Step.source
    var pastedText = ""
    private(set) var pdfText: String?
    private(set) var pdfName: String?
    private(set) var draft: ImportDraft?
    var keptEntries: Set<UUID> = []
    var keptSkills: Set<UUID> = []
    var keepHeader = true

    @ObservationIgnored private let router: LLMRouter?
    @ObservationIgnored private var work: Task<Void, Never>?

    init(router: LLMRouter?) {
        self.router = router
    }

    #if DEBUG
        /// For snapshots: straight to review.
        init(preview draft: ImportDraft) {
            router = nil
            self.draft = draft
            keptEntries = Set(draft.entries.map(\.id))
            keptSkills = Set(draft.skills.map(\.id))
            step = .review
        }
    #endif

    var sourceText: String { pdfText ?? pastedText }

    func loadPDF(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            pdfText = try ResumeTextExtractor.text(fromPDF: try Data(contentsOf: url))
            pdfName = url.lastPathComponent
        } catch ImportError.emptyText {
            step = .failed("That PDF has no text in it (a scan, perhaps). Paste the text instead.")
        } catch {
            step = .failed("Kairos couldn't read that PDF. Paste the text instead.")
        }
    }

    func clearPDF() {
        pdfText = nil
        pdfName = nil
    }

    /// Exactly what would be sent, or why nothing can be yet.
    func preview(header: ResumeHeader) -> Result<String, ImportError> {
        Result { () throws(ImportError) in try ResumeImporter.prepare(sourceText, header: header) }
    }

    func start(header: ResumeHeader) {
        guard case .success(let prepared) = preview(header: header) else { return }
        guard let router else {
            step = .failed("AI isn't set up yet. Add a key in Settings, AI providers.")
            return
        }
        step = .working
        work = Task {
            do {
                let result = try await router.run(ImportResumeTask(), input: prepared)
                let draft = ImportDraft(result.output)
                self.draft = draft
                keptEntries = Set(draft.entries.map(\.id))
                keptSkills = Set(draft.skills.map(\.id))
                step = .review
            } catch let error as LLMError {
                step = .failed(Self.describe(error))
            } catch {
                step = .failed("Couldn't get a draft. Try again in a minute.")
            }
        }
    }

    func cancel() {
        work?.cancel()
        step = .source
    }

    func update(_ entry: ResumeEntry) {
        guard var draft, let index = draft.entries.firstIndex(where: { $0.id == entry.id }) else { return }
        draft.entries[index] = entry
        self.draft = draft
    }

    var keptCount: Int { keptEntries.count + keptSkills.count + (keepHeader && hasHeader ? 1 : 0) }
    var hasHeader: Bool { draft.map { $0.headline != nil || $0.highlights != nil || $0.totalYears != nil } ?? false }

    static func describe(_ error: LLMError) -> String {
        switch error {
        case .budgetReached: "\(Budget.reachedMessage). Import tomorrow, or raise the budget in Settings."
        case .noProvider, .noKey: "Add an AI provider key in Settings, AI providers, first."
        case .keyRejected: "Your key was rejected. Check it in Settings, AI providers."
        case .modelNotOnPlan(let model):
            "\(model) isn't on your plan. Pick another model for \"Import a resume\" in Settings."
        case .invalidOutput:
            "The draft didn't pass Kairos's checks, even after a retry. Try again, or pick another model."
        case .cancelled: "Stopped."
        default: "Couldn't get a draft from the AI provider (\(error.code)). Try again in a minute."
        }
    }
}

/// Import a resume: choose it, see what gets sent, then review the draft before anything is saved.
struct ImportReviewView: View {
    @Environment(ResumeModel.self) private var resume
    @Environment(\.dismiss) private var dismiss
    @State var session: ImportSession
    @State private var choosingPDF = false
    @State private var showsSent = false
    @State private var editing: ResumeEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space5) {
            VStack(alignment: .leading, spacing: Spacing.space1) {
                Text("Import a resume").font(TypeStyle.title3).foregroundStyle(Color(.ink))
                Text("Kairos drafts your master resume from it. You choose what to keep; nothing is saved before that.")
                    .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            }
            switch session.step {
            case .source: source
            case .working: working
            case .review: review
            case .failed(let message): failed(message)
            }
        }
        .padding(Spacing.space6)
        .frame(width: 720)
        .frame(minHeight: 420, alignment: .top)
        .fileImporter(isPresented: $choosingPDF, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result { session.loadPDF(at: url) }
        }
        .sheet(item: $editing) { entry in
            EntryEditor(entry: entry, onSave: { session.update($0) })
        }
    }

    // MARK: - Steps

    @ViewBuilder private var source: some View {
        let preview = session.preview(header: resume.resume.header)
        if case .failure(.contactIncomplete(let fields)) = preview {
            notice(
                "Fill in your \(fields.map(Self.name).joined(separator: ", ")) in Contact first. Kairos removes your "
                    + "contact details from the resume before anything is sent, so it needs to know them.",
                symbol: "person.text.rectangle")
        }
        HStack(spacing: Spacing.space2) {
            PillButton(title: session.pdfName ?? "Choose a PDF…", symbol: "doc") { choosingPDF = true }
            if session.pdfName != nil {
                Button("Use pasted text instead") { session.clearPDF() }.buttonStyle(.borderless)
            }
        }
        if session.pdfName == nil {
            LabeledField(title: "Or paste the text") {
                TextEditor(text: $session.pastedText)
                    .font(TypeStyle.body)
                    .frame(height: 180)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: Radius.field).fill(Color(.surface)))
                    .overlay(RoundedRectangle(cornerRadius: Radius.field).stroke(Color(.fieldBorderStrong)))
            }
        }
        if case .success(let sent) = preview {
            DisclosureGroup("What gets sent (contact details removed)", isExpanded: $showsSent) {
                ScrollView {
                    Text(sent).font(.system(.callout, design: .monospaced)).foregroundStyle(Color(.ink2))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
            }
            .font(TypeStyle.callout)
        }
        footer {
            Button("Draft my master resume") { session.start(header: resume.resume.header) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!preview.isSuccess)
        }
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            HStack(spacing: Spacing.space2) {
                ProgressView().controlSize(.small)
                Text("Reading your resume…").font(TypeStyle.body).foregroundStyle(Color(.ink))
            }
            Text("This usually takes under a minute.").font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            footer {
                Button("Stop", role: .cancel) { session.cancel() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    @ViewBuilder private var review: some View {
        if let draft = session.draft {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.space4) {
                    if session.hasHeader {
                        reviewGroup("About you") {
                            Toggle(isOn: $session.keepHeader) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(draft.headline ?? "Highlights and total years").font(TypeStyle.headline)
                                    Text(
                                        [draft.totalYears.map { "\($0.formatted()) years" }, draft.highlights]
                                            .compactMap { $0 }.joined(separator: " · ")
                                    )
                                    .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).lineLimit(2)
                                }
                            }
                            Text("Fills only fields that are still empty.").font(TypeStyle.callout)
                                .foregroundStyle(Color(.inkSecondary))
                        }
                    }
                    ForEach(Self.groups, id: \.title) { group in
                        let entries = draft.entries.filter { group.kinds.contains($0.kind) }
                        if !entries.isEmpty {
                            reviewGroup(group.title) {
                                ForEach(entries) { entry in entryRow(entry) }
                            }
                        }
                    }
                    if !draft.skills.isEmpty {
                        reviewGroup("Skills") {
                            FlowLayout(spacing: 6) {
                                ForEach(draft.skills) { skill in
                                    Toggle(isOn: Self.binding(for: skill.id, in: $session.keptSkills)) {
                                        SkillChip(skill: skill)
                                    }
                                    .toggleStyle(.checkbox)
                                }
                            }
                            Text(
                                "Solid chips are Proven (used in a job or project); dashed are Can discuss. Change it later in Skills."
                            )
                            .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                        }
                    }
                }
            }
            .frame(maxHeight: 460)
            footer {
                Button("Discard") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add \(session.keptCount) item\(session.keptCount == 1 ? "" : "s") to my master resume") {
                    let draft = draft
                    let (entries, skills, header) = (session.keptEntries, session.keptSkills, session.keepHeader)
                    Task {
                        await resume.addImport(
                            entries: draft.entries.filter { entries.contains($0.id) },
                            skills: draft.skills.filter { skills.contains($0.id) },
                            headline: header ? draft.headline : nil, highlights: header ? draft.highlights : nil,
                            totalYears: header ? draft.totalYears : nil)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(session.keptCount == 0)
            }
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            notice(message, symbol: "exclamationmark.triangle.fill", color: Color(.error))
            footer {
                Button("Close", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Try again") { session.step = .source }.keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Pieces

    private func entryRow(_ entry: ResumeEntry) -> some View {
        let summary = entry.summary
        return HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
            Toggle("Keep \(summary.title)", isOn: Self.binding(for: entry.id, in: $session.keptEntries))
                .toggleStyle(.checkbox).labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title.isEmpty ? "Untitled" : summary.title).font(TypeStyle.headline).foregroundStyle(
                    Color(.ink))
                if !summary.meta.isEmpty {
                    Text(summary.meta).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                }
                ForEach(entry.bullets.prefix(2)) { bullet in
                    Text("• " + bullet.text).font(TypeStyle.callout).foregroundStyle(Color(.ink2)).lineLimit(2)
                }
                if entry.bullets.count > 2 {
                    Text("and \(entry.bullets.count - 2) more").font(TypeStyle.callout).foregroundStyle(
                        Color(.inkSecondary))
                }
            }
            Spacer()
            Button("Edit…") { editing = entry }.buttonStyle(.borderless).foregroundStyle(Color(.accentText))
        }
    }

    private func reviewGroup(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Text(title).font(TypeStyle.headline).foregroundStyle(Color(.ink))
            VStack(alignment: .leading, spacing: Spacing.space3) { content() }
                .padding(Spacing.space3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.row).fill(Color(.surfaceGrouped)))
        }
    }

    private func notice(_ text: String, symbol: String, color: Color = Color(.ink2)) -> some View {
        Label {
            Text(text).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(TypeStyle.callout)
        .padding(Spacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.row).fill(Color(.surfaceGrouped)))
    }

    private func footer(@ViewBuilder _ buttons: () -> some View) -> some View {
        HStack(spacing: Spacing.space2) {
            Spacer()
            buttons()
        }
        .controlSize(.large)
    }

    private static let groups: [(title: String, kinds: [EntryKind])] = [
        ("Experience", [.experience]), ("Projects", [.project]), ("Education", [.education]),
        ("Other sections", [.certification, .award, .volunteering, .publication, .language, .custom]),
    ]

    private static func binding(for id: UUID, in set: Binding<Set<UUID>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(id) },
            set: { keep in
                if keep { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) }
            })
    }

    private static func name(_ field: ResumeField) -> String {
        switch field {
        case .fullName: "name"
        case .email: "email"
        case .phone: "phone"
        case .linkedIn: "LinkedIn URL"
        default: field.rawValue
        }
    }
}

extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
