import MasterResume
import SwiftUI

/// Edits one entry of any kind: its fields, its dates (with "current" where that makes sense) and,
/// for kinds that have them, its bullets. Nothing is saved until you choose Save.
struct EntryEditor: View {
    @Environment(ResumeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var entry: ResumeEntry
    /// Set when editing a draft (import review): the edit goes here instead of to the master resume.
    var onSave: ((ResumeEntry) -> Void)? = nil
    @State private var techText = ""
    @State private var courseworkText = ""

    private var isNew: Bool { onSave == nil && !model.resume.entries.contains { $0.id == entry.id } }
    private let columns = [GridItem(.adaptive(minimum: 220), spacing: Spacing.space4, alignment: .top)]

    /// Kinds whose entries carry bullets (SPEC §5.10: experience, projects, custom sections; volunteering too).
    private var hasBullets: Bool { [.experience, .project, .volunteering, .custom].contains(entry.kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space5) {
            Text(isNew ? "Add \(entry.kind.itemName.lowercased())" : "Edit \(entry.kind.itemName.lowercased())")
                .font(TypeStyle.title2).foregroundStyle(Color(.ink))
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.space5) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) { fields }
                    dates
                    if hasBullets {
                        BulletEditor(bullets: $entry.bullets, skills: model.resume.skills)
                    }
                }
                .padding(2)
            }
            .frame(maxHeight: hasBullets ? 560 : 380)
            HStack(spacing: Spacing.space2) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(entry.summary.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.large)
        }
        .padding(Spacing.space6)
        .frame(width: hasBullets ? 680 : 560)
        .onAppear {
            if case .project(let project) = entry.fields { techText = project.tech.joined(separator: ", ") }
            if case .education(let school) = entry.fields { courseworkText = school.coursework.joined(separator: ", ") }
        }
    }

    private func save() {
        var saved = entry
        // Blank bullets are dropped rather than saved as empty lines.
        saved.bullets = saved.bullets.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if case .project(var project) = saved.fields {
            project.tech = Self.list(techText)
            saved.fields = .project(project)
        }
        if case .education(var school) = saved.fields {
            school.coursework = Self.list(courseworkText)
            saved.fields = .education(school)
        }
        if let onSave {
            onSave(saved)
        } else {
            Task { await model.save(saved) }
        }
        dismiss()
    }

    private static func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    @ViewBuilder private var fields: some View {
        switch entry.kind {
        case .experience:
            text("Title", experience.title, prompt: "Backend Developer II")
            text("Employer", experience.employer, prompt: "Northline Freight")
            text("Location", experience.location, optional: true, prompt: "Toronto, ON")
            LabeledField(title: "Employment type", optional: true) {
                Picker("Employment type", selection: experience.employmentType) {
                    Text("Not stated").tag("")
                    ForEach(["Full-time", "Part-time", "Contract", "Internship", "Co-op", "Freelance"], id: \.self) {
                        Text($0).tag($0)
                    }
                }
            }
        case .project:
            text("Name", project.name, prompt: "Dockyard")
            text("Your role", project.role, optional: true, prompt: "Author and maintainer")
            LabeledField(title: "Tech", optional: true) {
                TextField("Tech", text: $techText, prompt: Text("Go, SQLite, GitHub Actions"))
            }
            text("Project URL", optionalText(project.projectURL), optional: true, prompt: "https://…")
            text("Repository URL", optionalText(project.repoURL), optional: true, prompt: "https://github.com/…")
        case .education:
            text("Institution", education.institution, prompt: "University of Waterloo")
            text("Credential", education.credential, optional: true, prompt: "BMath")
            text("Field", education.field, optional: true, prompt: "Computer Science")
            text("Location", education.location, optional: true, prompt: "Waterloo, ON")
            text("Honours", education.honours, optional: true, prompt: "Dean's list")
            LabeledField(title: "Relevant coursework", optional: true) {
                TextField("Relevant coursework", text: $courseworkText, prompt: Text("Operating systems, Databases"))
            }
        case .certification:
            text("Name", certification.name, prompt: "AWS Solutions Architect")
            text("Issuer", certification.issuer, optional: true, prompt: "Amazon Web Services")
            text("Credential URL", optionalText(certification.credentialURL), optional: true, prompt: "https://…")
        case .award:
            text("Award", titled.title, prompt: "Hackathon winner")
            text("Given by", titled.organization, optional: true, prompt: "Hack the North")
            text("Link", optionalText(titled.url), optional: true, prompt: "https://…")
        case .volunteering:
            text("Role", titled.title, prompt: "Mentor")
            text("Organization", titled.organization, optional: true, prompt: "Code Club")
            text("Link", optionalText(titled.url), optional: true, prompt: "https://…")
        case .publication:
            text("Title", titled.title, prompt: "Event sourcing at scale")
            text("Published in", titled.organization, optional: true, prompt: "InfoQ")
            text("Link", optionalText(titled.url), optional: true, prompt: "https://…")
        case .language:
            text("Language", language.language, prompt: "French")
            LabeledField(title: "Proficiency") {
                Picker("Proficiency", selection: language.proficiency) {
                    ForEach(EntryFields.Language.Proficiency.allCases, id: \.self) {
                        Text($0.rawValue.capitalized).tag($0)
                    }
                }
            }
        case .custom:
            text("Section", custom.section, prompt: "Talks")
            text("Title", custom.title, prompt: "Postgres at scale, PGConf 2024")
        }
    }

    @ViewBuilder private var dates: some View {
        switch entry.kind {
        case .language:
            EmptyView()
        case .experience, .project, .education, .volunteering:
            HStack(alignment: .top, spacing: Spacing.space5) {
                MonthField(title: "Start", optional: entry.kind != .experience, value: $entry.start)
                if !entry.isCurrent { MonthField(title: "End", value: $entry.end) }
                Toggle(currentLabel, isOn: $entry.isCurrent).toggleStyle(.switch).padding(.top, 22)
            }
        default:
            MonthField(title: entry.kind == .certification ? "Issued" : "Date", value: $entry.start)
        }
    }

    private var currentLabel: String {
        switch entry.kind {
        case .experience: "I work here now"
        case .education: "Still studying"
        default: "Ongoing"
        }
    }

    private func text(_ title: String, _ binding: Binding<String>, optional: Bool = false, prompt: String) -> some View
    {
        LabeledField(title: title, optional: optional) {
            TextField(title, text: binding, prompt: Text(prompt))
        }
    }

    private func optionalText(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    // Bindings into the entry's per-kind fields. Each one only reads or writes its own kind.

    private var experience: Binding<EntryFields.Experience> {
        Binding(
            get: { if case .experience(let value) = entry.fields { value } else { .init(employer: "", title: "") } },
            set: { entry.fields = .experience($0) })
    }

    private var project: Binding<EntryFields.Project> {
        Binding(
            get: { if case .project(let value) = entry.fields { value } else { .init(name: "") } },
            set: { entry.fields = .project($0) })
    }

    private var education: Binding<EntryFields.Education> {
        Binding(
            get: { if case .education(let value) = entry.fields { value } else { .init(institution: "") } },
            set: { entry.fields = .education($0) })
    }

    private var certification: Binding<EntryFields.Certification> {
        Binding(
            get: { if case .certification(let value) = entry.fields { value } else { .init(name: "") } },
            set: { entry.fields = .certification($0) })
    }

    /// Awards, volunteering and publications share one shape.
    private var titled: Binding<EntryFields.Titled> {
        Binding(
            get: {
                switch entry.fields {
                case .award(let value), .volunteering(let value), .publication(let value): value
                default: .init(title: "")
                }
            },
            set: { value in
                switch entry.kind {
                case .award: entry.fields = .award(value)
                case .volunteering: entry.fields = .volunteering(value)
                default: entry.fields = .publication(value)
                }
            })
    }

    private var language: Binding<EntryFields.Language> {
        Binding(
            get: {
                if case .language(let value) = entry.fields {
                    value
                } else {
                    .init(language: "", proficiency: .professional)
                }
            },
            set: { entry.fields = .language($0) })
    }

    private var custom: Binding<EntryFields.Custom> {
        Binding(
            get: { if case .custom(let value) = entry.fields { value } else { .init(section: "", title: "") } },
            set: { entry.fields = .custom($0) })
    }
}
