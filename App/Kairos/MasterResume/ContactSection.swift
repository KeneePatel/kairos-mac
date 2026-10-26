import MasterResume
import SwiftUI

/// Contact details, headline, highlights and total years. Each field saves when you press Return or
/// leave it; a malformed value shows its fix underneath once you've moved on.
struct ContactSection: View {
    private enum Field: Hashable {
        case fullName, email, phone, linkedIn, gitHub, portfolio, years, headline, city, region, country
    }

    @Environment(ResumeModel.self) private var model
    @State private var draft = ResumeHeader()
    @State private var yearsText = ""
    @State private var loaded = false
    @FocusState private var focus: Field?
    @FocusState private var editingHighlights: Bool

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: Spacing.space4, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space6) {
            FormSection(
                title: "Contact", caption: "All fields are required unless marked optional. They stay on this Mac."
            ) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    text("Full name", $draft.fullName, .fullName, prompt: "Jordan Rivera", issue: .fullName)
                    text("Email", $draft.email, .email, prompt: "you@example.com", issue: .email)
                    text("Phone", $draft.phone, .phone, prompt: "416-555-0123", issue: .phone)
                    text(
                        "LinkedIn URL", $draft.linkedInURL, .linkedIn, prompt: "linkedin.com/in/your-name",
                        issue: .linkedIn)
                    text(
                        "GitHub", optional($draft.gitHubURL), .gitHub, optional: true, prompt: "github.com/your-name",
                        issue: .gitHub)
                    text(
                        "Portfolio", optional($draft.portfolioURL), .portfolio, optional: true,
                        prompt: "https://your-site.dev", issue: .portfolio)
                }
            }
            FormSection(
                title: "About you",
                caption: "What the summary writer may draw from. Nothing here is invented into a resume."
            ) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    text("Headline", $draft.headline, .headline, optional: true, prompt: "Backend developer")
                    LabeledField(title: "Total years of experience", error: error(.totalYears)) {
                        TextField("Total years of experience", text: $yearsText, prompt: Text("5"))
                            .focused($focus, equals: .years)
                            .onSubmit(commit)
                    }
                    text("City", optional($draft.city), .city, optional: true, prompt: "Toronto")
                    text("Province or state", optional($draft.region), .region, optional: true, prompt: "ON")
                    text("Country", optional($draft.country), .country, optional: true, prompt: "Canada")
                }
                LabeledField(title: "Career highlights", optional: true) {
                    TextEditor(text: $draft.highlights)
                        .font(TypeStyle.body)
                        .frame(minHeight: 72)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: Radius.field).fill(Color(.surface)))
                        .overlay(RoundedRectangle(cornerRadius: Radius.field).stroke(Color(.outline)))
                        .focused($editingHighlights)
                }
            }
        }
        .onAppear(perform: reset)
        .onChange(of: model.resume.header) { _, _ in if focus == nil && !editingHighlights { reset() } }
        .onChange(of: focus) { old, _ in if old != nil { commit() } }
        .onChange(of: editingHighlights) { old, _ in if old { commit() } }
        .onChange(of: yearsText) { _, text in
            let trimmed = text.trimmingCharacters(in: .whitespaces).replacing(",", with: ".")
            draft.totalYears = trimmed.isEmpty ? nil : Double(trimmed) ?? .nan
        }
    }

    private func text(
        _ title: String, _ binding: Binding<String>, _ field: Field, optional: Bool = false, prompt: String,
        issue: ResumeField? = nil
    ) -> some View {
        LabeledField(title: title, optional: optional, error: issue.flatMap(error)) {
            TextField(title, text: binding, prompt: Text(prompt))
                .focused($focus, equals: field)
                .onSubmit(commit)
        }
    }

    /// A malformed value's message, shown once the field isn't being edited. Missing values aren't
    /// flagged inline: the readiness panel lists them, and the labels say what's required.
    private func error(_ field: ResumeField) -> String? {
        guard focusedField != field, let issue = Validator.validate(draft).issue(for: field), issue.kind == .invalid
        else { return nil }
        return issue.message
    }

    private var focusedField: ResumeField? {
        switch focus {
        case .fullName: .fullName
        case .email: .email
        case .phone: .phone
        case .linkedIn: .linkedIn
        case .gitHub: .gitHub
        case .portfolio: .portfolio
        case .years: .totalYears
        default: nil
        }
    }

    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func reset() {
        draft = model.resume.header
        yearsText = draft.totalYears.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? ""
    }

    private func commit() {
        let submitted = draft
        Task {
            await model.saveHeader(submitted)
            // Show the cleaned values (E.164 phone, tidied URLs) unless you've typed on since.
            if draft == submitted && focus == nil { reset() }
        }
    }
}
