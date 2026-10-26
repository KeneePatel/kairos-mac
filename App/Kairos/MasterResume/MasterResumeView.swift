import MasterResume
import SwiftUI

/// The master resume: every section on one scrolling page, with build readiness in the inspector.
struct MasterResumeView: View {
    @Environment(ResumeModel.self) private var model
    @Environment(AISettingsModel.self) private var ai
    @State private var editing: ResumeEntry?
    @State private var importing: ImportSession?
    @State private var importingGitHub = false
    @State private var deleting: ResumeEntry?
    @State private var showsReadiness = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.space6) {
                if let error = model.saveError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(TypeStyle.callout).foregroundStyle(Color(.error))
                }
                ContactSection()
                Divider()
                EntrySection(
                    title: "Experience", kinds: [.experience, .project], editing: $editing, deleting: $deleting)
                EntrySection(title: "Education", kinds: [.education], editing: $editing, deleting: $deleting)
                Divider()
                SkillsSection()
                Divider()
                AdditionalSections(editing: $editing, deleting: $deleting)
            }
            .padding(Spacing.space6)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.surface))
        .navigationTitle("Master resume")
        .navigationSubtitle("Version \(model.resume.version) · the only source for every resume Kairos builds")
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("From a resume…") { importing = ImportSession(router: ai.router()) }
                    Button("From GitHub…") { importingGitHub = true }
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down").labelStyle(.titleAndIcon)
                }
                .help("Draft entries from a resume or from your GitHub repos")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach([EntryKind.experience, .project, .education], id: \.self) { kind in
                        Button(kind.itemName) { editing = ResumeEntry(fields: kind.blank()) }
                    }
                    Divider()
                    ForEach(EntryKind.additional, id: \.self) { kind in
                        Button(kind.itemName) { editing = ResumeEntry(fields: kind.blank()) }
                    }
                } label: {
                    Label("Add entry", systemImage: "plus").labelStyle(.titleAndIcon)
                }
                .menuStyle(.button)
                .buttonStyle(.borderedProminent)
            }
        }
        .sheet(item: $editing) { entry in EntryEditor(entry: entry) }
        .sheet(item: $importing) { session in ImportReviewView(session: session) }
        .sheet(isPresented: $importingGitHub) { GitHubImportView() }
        .confirmationDialog(
            "Delete this \(deleting?.kind.itemName.lowercased() ?? "entry")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting
        ) { entry in
            Button("Delete", role: .destructive) { Task { await model.deleteEntry(entry.id) } }
        } message: { entry in
            Text(
                "“\(entry.summary.title)” and its bullets leave your master resume. Resumes already built keep their copy."
            )
        }
        .inspector(isPresented: $showsReadiness) {
            ReadinessPanel(resume: model.resume, readiness: model.readiness)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 360)
        }
    }
}

/// "Ready to build", or what's left, plus a count of what the resume holds. Missing items use the
/// dashed grey circle (the design's Missing mark); warnings never block.
struct ReadinessPanel: View {
    let resume: MasterResume
    let readiness: BuildReadiness

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.space5) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: Spacing.space2) {
                        Image(systemName: readiness.isReady ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(Color(readiness.isReady ? .yesSolid : .inkSecondary))
                            .accessibilityHidden(true)
                        Text(readiness.isReady ? "Ready to build" : "Not ready to build yet")
                            .font(TypeStyle.title2).foregroundStyle(Color(.ink))
                    }
                    Text(
                        "Every resume draws only from this page. Kairos never adds a job, skill or number you haven't written here."
                    )
                    .font(TypeStyle.callout).foregroundStyle(Color(.ink2))
                    .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(readiness.missing.enumerated()), id: \.offset) { _, requirement in
                        Label {
                            Text(requirement.message).foregroundStyle(Color(.ink))
                        } icon: {
                            Image(systemName: "circle.dashed").foregroundStyle(Color(.inkSecondary))
                        }
                        .font(TypeStyle.callout)
                    }
                    ForEach(readiness.warnings, id: \.self) { warning in
                        Label {
                            Text(warning).foregroundStyle(Color(.ink))
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(.maybe))
                        }
                        .font(TypeStyle.callout)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.group).fill(Color(.surfaceRaised)))

                VStack(alignment: .leading, spacing: Spacing.space3) {
                    fact("Contact", contactStatus)
                    fact("Experience", experienceSummary)
                    fact("Skills", "\(proven) Proven, \(resume.skills.count - proven) Can discuss")
                    fact("Other entries", "\(otherEntries)")
                }
            }
            .padding(Spacing.space5)
        }
        .background(Color(.surface))
    }

    private var proven: Int { resume.skills.count { $0.level == .proven } }
    private var otherEntries: Int { resume.entries.count { EntryKind.additional.contains($0.kind) } }

    private var contactStatus: String {
        let validation = Validator.validate(resume.header)
        let blocking = validation.blocking.count
        var status = blocking == 0 ? "Complete." : "\(blocking) to fill in or fix."
        let leftOff = [ResumeField.gitHub, .portfolio].filter { validation.issue(for: $0) != nil }
            .map { $0 == .gitHub ? "GitHub" : "Portfolio" }
        if !leftOff.isEmpty {
            status += " \(leftOff.joined(separator: " and ")) left off until fixed."
        }
        return status
    }

    private var experienceSummary: String {
        let roles = resume.entries(.experience).count
        let projects = resume.entries(.project).count
        let bullets = resume.entries.reduce(0) { $0 + $1.bullets.count }
        return
            "\(roles) role\(roles == 1 ? "" : "s"), \(projects) project\(projects == 1 ? "" : "s") · \(bullets) bullet\(bullets == 1 ? "" : "s")"
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(TypeStyle.headline).foregroundStyle(Color(.ink))
            Text(value).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).monospacedDigit()
        }
    }
}
