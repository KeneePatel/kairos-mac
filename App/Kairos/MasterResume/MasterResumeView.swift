import Engine
import Render
import Resume
import Store
import SwiftUI
import Tailoring

/// The master resume: everything you've done, the only source resumes are written from. Contact,
/// About you, each kind of entry and Skills as hairline sections; readiness in the inspector.
struct MasterResumeView: View {
    @Environment(AppModel.self) private var model
    @State private var header = ResumeHeader()
    @State private var editing: ResumeEntry?
    @State private var importing = false
    @State private var importingGitHub = false
    @State private var inspector = true
    @State private var newSkill = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.space6) {
                HStack {
                    VStack(alignment: .leading, spacing: Spacing.space1) {
                        Text("Master resume").font(TypeStyle.pageTitle)
                        Text("Version \(model.resume.version) · resumes only claim what's here")
                            .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                    }
                    Spacer()
                    Menu("Import") {
                        Button("From a resume…") { importing = true }
                        Button("A project from GitHub…") { importingGitHub = true }
                    }
                    .fixedSize()
                    Button("Export PDF…") { exportPDF() }
                }
                contact
                about
                ForEach(EntryKind.allCases, id: \.self) { kind in entries(kind) }
                skills
            }
            .padding(Spacing.space7)
            .frame(maxWidth: Spacing.formWidth + 120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.surface))
        .inspector(isPresented: $inspector) {
            ReadinessInspector().inspectorColumnWidth(min: 240, ideal: 280, max: 340)
        }
        .toolbar {
            Button {
                inspector.toggle()
            } label: {
                Label("Readiness", systemImage: "sidebar.trailing")
            }
        }
        .navigationTitle("Master resume")
        .sheet(item: $editing) { entry in
            EntryEditor(entry: entry) { saved in
                save(saved)
            } delete: {
                delete(entry.id)
            }
        }
        .sheet(isPresented: $importing) { ImportResumeSheet() }
        .sheet(isPresented: $importingGitHub) { GitHubImportSheet() }
        .task(id: model.resume.version) { header = model.resume.header }
    }

    // MARK: - Sections

    private var contact: some View {
        PaneSection(title: "Contact") {
            Grid(alignment: .leading, horizontalSpacing: Spacing.space3, verticalSpacing: Spacing.space2) {
                field("Name", $header.fullName)
                field("Email", $header.email)
                field("Phone", $header.phone)
                field("LinkedIn", $header.linkedInURL)
                field(
                    "GitHub",
                    Binding(get: { header.gitHubURL ?? "" }, set: { header.gitHubURL = $0.isEmpty ? nil : $0 }))
                field(
                    "Portfolio",
                    Binding(get: { header.portfolioURL ?? "" }, set: { header.portfolioURL = $0.isEmpty ? nil : $0 }))
                field("City", Binding(get: { header.city ?? "" }, set: { header.city = $0.isEmpty ? nil : $0 }))
                field(
                    "Province or state",
                    Binding(get: { header.region ?? "" }, set: { header.region = $0.isEmpty ? nil : $0 }))
            }
            issues
        }
    }

    @ViewBuilder private var issues: some View {
        let validation = Validator.validate(header)
        ForEach(validation.issues, id: \.field) { issue in
            Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                .font(TypeStyle.callout).foregroundStyle(issue.field.isOptional ? Color(.inkSecondary) : Color(.maybe))
        }
    }

    private var about: some View {
        PaneSection(title: "About you") {
            Grid(alignment: .leading, horizontalSpacing: Spacing.space3, verticalSpacing: Spacing.space2) {
                field("Headline", $header.headline)
                GridRow {
                    Text("Years of experience").font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                    TextField("", value: $header.totalYears, format: .number).frame(width: 80)
                        .onSubmit(saveHeader)
                }
            }
            Text("Highlights").font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            TextEditor(text: $header.highlights)
                .font(TypeStyle.body).frame(minHeight: 70).scrollContentBackground(.hidden).padding(Spacing.space2)
                .background(RoundedRectangle(cornerRadius: Radius.field).fill(Color(.surfaceSunken)))
            HStack {
                Spacer()
                Button("Save contact and about") { saveHeader() }
                    .disabled(header == model.resume.header)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        GridRow {
            Text(label).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            TextField(label, text: text).labelsHidden().onSubmit(saveHeader)
        }
    }

    @ViewBuilder private func entries(_ kind: EntryKind) -> some View {
        let entries = model.resume.entries(kind)
        if !entries.isEmpty || [.experience, .project, .education].contains(kind) {
            PaneSection(title: kind.title) {
                ForEach(entries) { entry in
                    Button {
                        editing = entry
                    } label: {
                        VStack(alignment: .leading, spacing: Spacing.space1) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(entry.fields.headline).font(TypeStyle.headline).foregroundStyle(Color(.ink))
                                Spacer()
                                Text(entry.period).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                                    .monospacedDigit()
                            }
                            ForEach(entry.bullets) { bullet in
                                HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
                                    Text("•").foregroundStyle(Color(.inkSecondary))
                                    Text(bullet.text).foregroundStyle(Color(.ink2)).fixedSize(
                                        horizontal: false, vertical: true)
                                }
                                .font(TypeStyle.body)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
                Button("Add \(kind.title.lowercased())") { editing = Self.blank(kind) }
                    .buttonStyle(.plain).foregroundStyle(Color(.accentText)).font(TypeStyle.callout)
            }
        }
    }

    private var skills: some View {
        PaneSection(title: "Skills", trailing: "\(model.resume.provenSkills.count) proven") {
            Text(
                "Proven skills are backed by your work; resumes may claim them. Can discuss skills only appear in Stretch builds, on the list to be ready to discuss. Click a skill to switch it."
            )
            .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).fixedSize(horizontal: false, vertical: true)
            FlowLayout {
                ForEach(model.resume.skills) { skill in
                    SkillChip(name: skill.name, proven: skill.level == .proven)
                        .onTapGesture { toggle(skill) }
                        .contextMenu { Button("Remove \(skill.name)", role: .destructive) { remove(skill) } }
                        .help(
                            skill.level == .proven
                                ? "Proven: click to make it Can discuss" : "Can discuss: click to make it Proven")
                }
            }
            HStack {
                TextField("Add a skill", text: $newSkill).onSubmit(addSkill).frame(maxWidth: 260)
                Button("Add", action: addSkill).disabled(newSkill.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    static func blank(_ kind: EntryKind) -> ResumeEntry {
        let fields: EntryFields =
            switch kind {
            case .experience: .experience(.init(employer: "", title: ""))
            case .project: .project(.init(name: ""))
            case .education:
                .education(.init(institution: "", credential: "", field: "", location: "", honours: "", coursework: []))
            case .certification: .certification(.init(name: ""))
            case .award: .award(.init(title: ""))
            case .volunteering: .volunteering(.init(title: ""))
            case .publication: .publication(.init(title: ""))
            case .language: .language(.init(language: "", proficiency: .professional))
            case .custom: .custom(.init(section: "", title: ""))
            }
        return ResumeEntry(fields: fields)
    }

    // MARK: - Saving

    private var store: ResumeRepository? { model.workspace?.store.resume }

    private func saveHeader() {
        let cleaned = Validator.validate(header).header
        Task {
            _ = try? await store?.saveHeader(cleaned)
            await model.reload()
        }
    }

    private func save(_ entry: ResumeEntry) {
        Task {
            _ = try? await store?.saveEntry(entry)
            await model.reload()
        }
    }

    private func delete(_ id: UUID) {
        Task {
            _ = try? await store?.deleteEntry(id)
            await model.reload()
        }
    }

    private func toggle(_ skill: Skill) {
        var skills = model.resume.skills
        guard let index = skills.firstIndex(where: { $0.id == skill.id }) else { return }
        skills[index].level = skill.level == .proven ? .canDiscuss : .proven
        saveSkills(skills)
    }

    private func remove(_ skill: Skill) {
        saveSkills(model.resume.skills.filter { $0.id != skill.id })
    }

    private func addSkill() {
        let name = newSkill.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty,
            !model.resume.skills.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { return }
        newSkill = ""
        saveSkills(model.resume.skills + [Skill(name: name)])
    }

    private func saveSkills(_ skills: [Skill]) {
        Task {
            _ = try? await store?.saveSkills(skills)
            await model.reload()
        }
    }

    /// Your whole master resume as a PDF, in the Harvard template.
    private func exportPDF() {
        guard let renderer = model.workspace?.renderer else {
            model.notice = AppModel.Notice(
                title: "Can't make a PDF", message: "The PDF maker is missing from this copy of Kairos.")
            return
        }
        let resume = model.resume
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue =
            "\(resume.header.fullName.isEmpty ? "Master" : resume.header.fullName) - Master Resume.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let pdf = try await renderer.render(ResumeDocument(FullResume(resume)))
                try pdf.data.write(to: url, options: .atomic)
            } catch {
                model.notice = AppModel.Notice(title: "The PDF couldn't be made", message: "\(error)")
            }
        }
    }
}

/// What still stands between the master resume and a build, and what's worth a look.
struct ReadinessInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let readiness = Validator.readiness(model.resume, now: YearMonth.containing(Date()))
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.space4) {
                Label(
                    readiness.isReady ? "Ready to build" : "Not ready yet",
                    systemImage: readiness.isReady ? "checkmark.circle.fill" : "circle.dashed"
                )
                .font(TypeStyle.headline)
                .foregroundStyle(readiness.isReady ? Color(.yes) : Color(.maybe))
                ForEach(Array(readiness.missing.enumerated()), id: \.offset) { _, missing in
                    Text(missing.message).font(TypeStyle.callout).foregroundStyle(Color(.ink))
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(readiness.warnings, id: \.self) { warning in
                    Text(warning).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                FactRow(label: "Entries", value: "\(model.resume.entries.count)")
                FactRow(label: "Bullets", value: "\(model.resume.entries.reduce(0) { $0 + $1.bullets.count })")
                FactRow(label: "Proven skills", value: "\(model.resume.provenSkills.count)")
                FactRow(label: "Can discuss", value: "\(model.resume.canDiscussSkills.count)")
            }
            .padding(Spacing.space5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
