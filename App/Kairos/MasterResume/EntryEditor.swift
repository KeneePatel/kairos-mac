import Resume
import SwiftUI

/// One entry's sheet: its fields by kind, its dates, and its bullets in order. Bullet ids never
/// change, so tailored resumes keep citing them.
struct EntryEditor: View {
    @State private var entry: ResumeEntry
    @State private var start: String
    @State private var end: String
    let save: (ResumeEntry) -> Void
    let delete: () -> Void
    @Environment(\.dismiss) private var dismiss

    init(entry: ResumeEntry, save: @escaping (ResumeEntry) -> Void, delete: @escaping () -> Void) {
        _entry = State(initialValue: entry)
        _start = State(initialValue: entry.start?.description ?? "")
        _end = State(initialValue: entry.end?.description ?? "")
        self.save = save
        self.delete = delete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section(entry.kind.title) { fields }
                if ![.language, .certification].contains(entry.kind) {
                    Section("Dates") {
                        TextField("Start (YYYY-MM)", text: $start)
                        Toggle("Current", isOn: $entry.isCurrent)
                        if !entry.isCurrent { TextField("End (YYYY-MM)", text: $end) }
                        if !dateProblem.isEmpty {
                            Text(dateProblem).font(TypeStyle.callout).foregroundStyle(Color(.maybe))
                        }
                    }
                }
                if [.experience, .project, .volunteering].contains(entry.kind) {
                    Section("Bullets") {
                        ForEach($entry.bullets) { $bullet in
                            HStack(alignment: .top) {
                                TextField("What you did, and what came of it", text: $bullet.text, axis: .vertical)
                                    .lineLimit(1...4)
                                Button {
                                    entry.bullets.removeAll { $0.id == bullet.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                                .help("Remove this bullet")
                            }
                        }
                        .onMove { entry.bullets.move(fromOffsets: $0, toOffset: $1) }
                        Button("Add a bullet") { entry.bullets.append(ResumeBullet(text: "")) }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Delete", role: .destructive) {
                    delete()
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var saved = entry
                    saved.start = YearMonth(start)
                    saved.end = saved.isCurrent ? nil : YearMonth(end)
                    saved.bullets = saved.bullets.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
                    save(saved)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!dateProblem.isEmpty || entry.fields.headline.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(Spacing.space5)
        }
        .frame(width: Spacing.formWidth, height: 620)
    }

    private var dateProblem: String {
        if !start.isEmpty, YearMonth(start) == nil { return "Write the start as YYYY-MM, like 2023-05." }
        if !entry.isCurrent, !end.isEmpty, YearMonth(end) == nil { return "Write the end as YYYY-MM, like 2024-08." }
        return ""
    }

    /// How to read one kind's fields out of an entry and put them back.
    struct Kind<F> {
        let extract: (EntryFields) -> F?
        let embed: (F) -> EntryFields
    }

    static var experience: Kind<EntryFields.Experience> {
        Kind(extract: { if case .experience(let value) = $0 { value } else { nil } }, embed: { .experience($0) })
    }
    static var project: Kind<EntryFields.Project> {
        Kind(extract: { if case .project(let value) = $0 { value } else { nil } }, embed: { .project($0) })
    }
    static var education: Kind<EntryFields.Education> {
        Kind(extract: { if case .education(let value) = $0 { value } else { nil } }, embed: { .education($0) })
    }
    static var certification: Kind<EntryFields.Certification> {
        Kind(extract: { if case .certification(let value) = $0 { value } else { nil } }, embed: { .certification($0) })
    }
    static var language: Kind<EntryFields.Language> {
        Kind(extract: { if case .language(let value) = $0 { value } else { nil } }, embed: { .language($0) })
    }
    static var custom: Kind<EntryFields.Custom> {
        Kind(extract: { if case .custom(let value) = $0 { value } else { nil } }, embed: { .custom($0) })
    }
    static func titled(_ wrap: @escaping (EntryFields.Titled) -> EntryFields) -> Kind<EntryFields.Titled> {
        Kind(
            extract: {
                switch $0 {
                case .award(let value), .volunteering(let value), .publication(let value): value
                default: nil
                }
            }, embed: wrap)
    }

    private func value<F, V>(_ kind: Kind<F>, _ path: WritableKeyPath<F, V>, _ empty: V) -> Binding<V> {
        Binding(
            get: { kind.extract(entry.fields)?[keyPath: path] ?? empty },
            set: { newValue in
                guard var fields = kind.extract(entry.fields) else { return }
                fields[keyPath: path] = newValue
                entry.fields = kind.embed(fields)
            })
    }

    private func text<F>(_ label: String, _ kind: Kind<F>, _ path: WritableKeyPath<F, String>) -> some View {
        TextField(label, text: value(kind, path, ""))
    }

    private func optional<F>(_ label: String, _ kind: Kind<F>, _ path: WritableKeyPath<F, String?>) -> some View {
        let binding = value(kind, path, nil)
        return TextField(
            label,
            text: Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 }))
    }

    @ViewBuilder private var fields: some View {
        switch entry.kind {
        case .experience:
            text("Title", Self.experience, \.title)
            text("Employer", Self.experience, \.employer)
            text("Location", Self.experience, \.location)
            text("Employment type", Self.experience, \.employmentType)
        case .project:
            text("Name", Self.project, \.name)
            text("Your role", Self.project, \.role)
            let tech = value(Self.project, \.tech, [])
            TextField(
                "Tech, comma separated",
                text: Binding(
                    get: { tech.wrappedValue.joined(separator: ", ") },
                    set: {
                        tech.wrappedValue = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    }))
            optional("Repository", Self.project, \.repoURL)
            optional("Link", Self.project, \.projectURL)
        case .education:
            text("Credential", Self.education, \.credential)
            text("Field", Self.education, \.field)
            text("Institution", Self.education, \.institution)
            text("Location", Self.education, \.location)
            text("Honours", Self.education, \.honours)
        case .certification:
            text("Name", Self.certification, \.name)
            text("Issuer", Self.certification, \.issuer)
            optional("Credential link", Self.certification, \.credentialURL)
        case .award:
            text("Title", Self.titled { .award($0) }, \.title)
            text("Organization", Self.titled { .award($0) }, \.organization)
        case .volunteering:
            text("Title", Self.titled { .volunteering($0) }, \.title)
            text("Organization", Self.titled { .volunteering($0) }, \.organization)
        case .publication:
            text("Title", Self.titled { .publication($0) }, \.title)
            text("Where", Self.titled { .publication($0) }, \.organization)
        case .language:
            text("Language", Self.language, \.language)
            Picker("Level", selection: value(Self.language, \.proficiency, .professional)) {
                ForEach(EntryFields.Language.Proficiency.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
        case .custom:
            text("Section", Self.custom, \.section)
            text("Title", Self.custom, \.title)
        }
    }
}
