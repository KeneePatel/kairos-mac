import MasterResume
import SwiftUI

extension EntryKind {
    var sectionTitle: String {
        switch self {
        case .experience: "Experience"
        case .project: "Projects"
        case .education: "Education"
        case .certification: "Certifications"
        case .award: "Awards"
        case .volunteering: "Volunteering"
        case .publication: "Publications"
        case .language: "Languages"
        case .custom: "Other sections"
        }
    }

    var itemName: String {
        switch self {
        case .experience: "Experience"
        case .project: "Project"
        case .education: "Education"
        case .certification: "Certification"
        case .award: "Award"
        case .volunteering: "Volunteering"
        case .publication: "Publication"
        case .language: "Language"
        case .custom: "Custom entry"
        }
    }

    /// An empty entry of this kind, for "Add".
    func blank() -> EntryFields {
        switch self {
        case .experience: .experience(.init(employer: "", title: ""))
        case .project: .project(.init(name: ""))
        case .education: .education(.init(institution: ""))
        case .certification: .certification(.init(name: ""))
        case .award: .award(.init(title: ""))
        case .volunteering: .volunteering(.init(title: ""))
        case .publication: .publication(.init(title: ""))
        case .language: .language(.init(language: "", proficiency: .professional))
        case .custom: .custom(.init(section: "", title: ""))
        }
    }

    static let additional: [EntryKind] = [.certification, .award, .volunteering, .publication, .language, .custom]
}

extension ResumeEntry {
    /// The row's main line and its meta line.
    var summary: (title: String, meta: String) {
        let dates = dateRange
        func join(_ parts: String?...) -> String {
            parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        switch fields {
        case .experience(let job): return (job.title, join(job.employer, job.location, dates))
        case .project(let project): return (project.name, join(project.role, dates))
        case .education(let school): return (join(school.credential, school.field), join(school.institution, dates))
        case .certification(let cert): return (cert.name, join(cert.issuer, dates))
        case .award(let item), .volunteering(let item), .publication(let item):
            return (item.title, join(item.organization, dates))
        case .language(let language): return (language.language, language.proficiency.rawValue.capitalized)
        case .custom(let custom): return (custom.title, join(custom.section, dates))
        }
    }

    var dateRange: String? {
        let format = Date.FormatStyle().month(.abbreviated).year()
        func text(_ month: YearMonth) -> String {
            let date = Calendar.current.date(from: DateComponents(year: month.year, month: month.month)) ?? Date()
            return date.formatted(format)
        }
        switch (start, isCurrent ? nil : end, isCurrent) {
        case (let start?, _, true): return "\(text(start)) – Present"
        case (let start?, let end?, false): return "\(text(start)) – \(text(end))"
        case (let start?, nil, false): return text(start)
        default: return nil
        }
    }
}

/// Certifications, awards, volunteering, publications, languages and your own sections.
struct AdditionalSections: View {
    @Environment(ResumeModel.self) private var model
    @Binding var editing: ResumeEntry?

    var body: some View {
        ForEach(EntryKind.additional, id: \.self) { kind in
            EntryList(kind: kind, editing: $editing)
        }
    }
}

/// One kind's entries as rows; click to edit, context menu to move or delete.
struct EntryList: View {
    @Environment(ResumeModel.self) private var model
    let kind: EntryKind
    @Binding var editing: ResumeEntry?

    var body: some View {
        let entries = model.resume.entries(kind)
        FormSection(title: kind.sectionTitle, caption: entries.isEmpty ? "Optional" : nil) {
            PillButton(title: "Add", symbol: "plus") { editing = ResumeEntry(fields: kind.blank()) }
        } content: {
            if !entries.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().overlay(Color(.separatorRow)) }
                        row(entry, index: index, count: entries.count)
                    }
                }
                .background(RoundedRectangle(cornerRadius: Radius.group).fill(Color(.surfaceGrouped)))
            }
        }
    }

    private func row(_ entry: ResumeEntry, index: Int, count: Int) -> some View {
        let summary = entry.summary
        return Button {
            editing = entry
        } label: {
            HStack(spacing: Spacing.space3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.title.isEmpty ? "Untitled" : summary.title).font(TypeStyle.headline)
                        .foregroundStyle(Color(.ink))
                    if !summary.meta.isEmpty {
                        Text(summary.meta).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                    }
                }
                Spacer()
                if !entry.bullets.isEmpty {
                    Text("\(entry.bullets.count) bullet\(entry.bullets.count == 1 ? "" : "s")")
                        .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).monospacedDigit()
                }
                Image(systemName: "chevron.right").foregroundStyle(Color(.inkSecondary)).accessibilityHidden(true)
            }
            .padding(.horizontal, Spacing.space4)
            .frame(minHeight: Spacing.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit…") { editing = entry }
            Button("Move up") { Task { await model.move(entry, by: -1) } }.disabled(index == 0)
            Button("Move down") { Task { await model.move(entry, by: 1) } }.disabled(index == count - 1)
            Divider()
            Button("Delete", role: .destructive) { Task { await model.deleteEntry(entry.id) } }
        }
    }
}

/// Edits one entry of any kind. T18 adds bullets and the experience, project and education fields.
struct EntryEditor: View {
    @Environment(ResumeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var entry: ResumeEntry
    @State private var confirmingDelete = false

    private var isNew: Bool { !model.resume.entries.contains { $0.id == entry.id } }
    private let columns = [GridItem(.adaptive(minimum: 220), spacing: Spacing.space4, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space5) {
            Text(isNew ? "Add \(entry.kind.itemName.lowercased())" : "Edit \(entry.kind.itemName.lowercased())")
                .font(TypeStyle.title3).foregroundStyle(Color(.ink))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) { fields }
                    dates
                }
                .padding(2)
            }
            .frame(maxHeight: 460)
            HStack(spacing: Spacing.space2) {
                if !isNew {
                    Button("Delete…", role: .destructive) { confirmingDelete = true }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    let entry = self.entry
                    Task { await model.save(entry) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(entry.summary.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.large)
        }
        .padding(Spacing.space6)
        .frame(width: 560)
        .confirmationDialog("Delete this \(entry.kind.itemName.lowercased())?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                let id = entry.id
                Task { await model.deleteEntry(id) }
                dismiss()
            }
        } message: {
            Text("Resumes already built keep their copy.")
        }
    }

    @ViewBuilder private var fields: some View {
        switch entry.kind {
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
        case .experience, .project, .education:
            EmptyView()
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

    @ViewBuilder private var dates: some View {
        switch entry.kind {
        case .language:
            EmptyView()
        case .volunteering:
            HStack(alignment: .top, spacing: Spacing.space4) {
                MonthField(title: "Started", value: $entry.start)
                if !entry.isCurrent { MonthField(title: "Ended", value: $entry.end) }
                Toggle("I still do this", isOn: $entry.isCurrent).toggleStyle(.switch).padding(.top, 22)
            }
        default:
            MonthField(title: entry.kind == .certification ? "Issued" : "Date", value: $entry.start)
        }
    }
}
