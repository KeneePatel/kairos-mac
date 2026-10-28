import AI
import Engine
import Resume
import Secrets
import SwiftUI
import UniformTypeIdentifiers

/// Import a resume: a PDF or pasted text, with your contact details and work status taken out
/// before the AI reads it; then a review of what it found before it replaces your master resume
/// (the old one is kept as a snapshot).
struct ImportResumeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var draft: ImportDraft?
    @State private var working = false
    @State private var problem: String?
    @State private var choosing = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            Text("Import a resume").font(TypeStyle.title1)
            if let draft {
                review(draft)
            } else {
                Text(
                    "Paste your resume's text or choose a PDF. Your name, email, phone, links and work status are taken out before the AI reads it."
                )
                .font(TypeStyle.body).foregroundStyle(Color(.inkSecondary)).fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $text)
                    .font(TypeStyle.body).scrollContentBackground(.hidden).padding(Spacing.space2)
                    .background(RoundedRectangle(cornerRadius: Radius.field).fill(Color(.surfaceSunken)))
                if let problem { Text(problem).font(TypeStyle.callout).foregroundStyle(Color(.error)) }
                HStack {
                    Button("Choose a PDF…") { choosing = true }
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Read it") { read() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(working || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if working { ProgressView("Reading your resume…").controlSize(.small) }
            }
        }
        .padding(Spacing.space6)
        .frame(width: Spacing.formWidth, height: 560)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                text = try ResumeImporter.text(fromPDF: try Data(contentsOf: url))
            } catch let error as ImportError {
                problem = error.message
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func review(_ draft: ImportDraft) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Text(
                "Found \(draft.entries.count) entries, \(draft.entries.reduce(0) { $0 + $1.bullets.count }) bullets and \(draft.skills.count) skills. Saving replaces your master resume; the current one is kept and can be put back."
            )
            .font(TypeStyle.body).foregroundStyle(Color(.inkSecondary)).fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(draft.entries) { entry in
                    VStack(alignment: .leading) {
                        Text(entry.fields.headline).font(TypeStyle.headline)
                        Text(
                            "\(entry.kind.title) · \(entry.period) · \(entry.bullets.count) bullets"
                                + (draft.monthsToCheck.contains(entry.id) ? " · check the month" : "")
                        )
                        .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                    }
                }
                Text(draft.skills.map(\.name).joined(separator: ", ")).font(TypeStyle.callout)
            }
            HStack {
                Button("Back") { self.draft = nil }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Replace my master resume") { save(draft) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func read() {
        guard let workspace = model.workspace else { return }
        problem = nil
        working = true
        let header = model.resume.header
        let raw = text
        Task {
            defer { working = false }
            do {
                let prepared = try ResumeImporter.prepare(raw, header: header)
                let result = try await workspace.router.run(ImportResumeTask(), input: prepared)
                draft = ImportDraft(result.output)
            } catch let error as ImportError {
                problem = error.message
            } catch let error as AIError {
                problem = "The AI couldn't read it: the model \(error.reason)."
            } catch {
                problem = "\(error)"
            }
        }
    }

    private func save(_ draft: ImportDraft) {
        guard let store = model.workspace?.store else { return }
        var resume = model.resume
        if let headline = draft.headline { resume.header.headline = headline }
        if let highlights = draft.highlights { resume.header.highlights = highlights }
        if let years = draft.totalYears { resume.header.totalYears = years }
        resume.entries = draft.entries
        resume.skills = draft.skills
        Task {
            _ = try? await store.resume.replace(with: resume, reason: "Before importing a resume")
            await model.reload()
            dismiss()
        }
    }
}

/// Add a project from one of your public GitHub repositories: its README and languages are read,
/// with your contact details taken out, and the AI writes the entry for you to check.
struct GitHubImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var repos: [GitHubRepo] = []
    @State private var choice: GitHubRepo.ID?
    @State private var entry: ResumeEntry?
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            Text("Add a project from GitHub").font(TypeStyle.title1)
            if let entry {
                EntryEditor(entry: entry) { saved in
                    Task {
                        _ = try? await model.workspace?.store.resume.saveEntry(saved)
                        await model.reload()
                        dismiss()
                    }
                } delete: {
                    self.entry = nil
                }
            } else {
                List(repos, selection: $choice) { repo in
                    VStack(alignment: .leading) {
                        Text(repo.name).font(TypeStyle.headline)
                        Text(
                            [repo.language ?? "", repo.description ?? ""].filter { !$0.isEmpty }.joined(
                                separator: " · ")
                        )
                        .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).lineLimit(1)
                    }
                }
                .overlay {
                    if repos.isEmpty, !working {
                        EmptyState("No repositories", problem ?? "Add your GitHub profile link in Contact first.")
                    }
                }
                if let problem, !repos.isEmpty { Text(problem).font(TypeStyle.callout).foregroundStyle(Color(.error)) }
                HStack {
                    if working { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Write the entry") { write() }
                        .buttonStyle(.borderedProminent).disabled(choice == nil || working)
                }
            }
        }
        .padding(Spacing.space6)
        .frame(width: Spacing.formWidth, height: 620)
        .task { await load() }
    }

    private var client: GitHubClient? {
        guard let workspace = model.workspace else { return nil }
        return GitHubClient(token: (try? workspace.secrets.read(.gitHub)) ?? nil, http: workspace.http)
    }

    private func load() async {
        guard let client, let user = GitHubClient.user(fromProfile: model.resume.header.gitHubURL) else { return }
        working = true
        defer { working = false }
        do {
            repos = try await client.repos(of: user)
        } catch {
            problem = "GitHub didn't answer: \(error)"
        }
    }

    private func write() {
        guard let client, let workspace = model.workspace, let repo = repos.first(where: { $0.id == choice }) else {
            return
        }
        working = true
        let header = model.resume.header
        Task {
            defer { working = false }
            do {
                let languages = (try? await client.languages(of: repo)) ?? []
                let readme = try? await client.readme(of: repo)
                let input = ImportGitHubRepoTask.Input(
                    repo: repo, languages: languages, readme: readme ?? nil, header: header)
                let result = try await workspace.router.run(ImportGitHubRepoTask(), input: input)
                entry = ImportGitHubRepoTask.entry(from: result.output, repo: repo)
            } catch {
                problem = "The entry couldn't be written: \(error)"
            }
        }
    }
}
