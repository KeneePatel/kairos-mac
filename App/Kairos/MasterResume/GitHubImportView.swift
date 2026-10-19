import LLM
import MasterResume
import SwiftUI

/// Pick public repos, draft a project entry for each, then review them like any import.
struct GitHubImportView: View {
    @Environment(ResumeModel.self) private var resume
    @Environment(AISettingsModel.self) private var ai
    @Environment(\.dismiss) private var dismiss
    @State private var repos: [GitHubRepo] = []
    @State private var chosen: Set<String> = []
    @State private var loading = false
    @State private var problem: String?
    @State private var progress: (done: Int, total: Int)?
    @State private var token = ""
    @State private var review: ImportSession?

    private var user: String? { GitHubClient.user(fromProfile: resume.resume.header.gitHubURL) }

    var body: some View {
        if let review {
            ImportReviewView(session: review, title: "Import GitHub projects")
        } else {
            picker
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: Spacing.space5) {
            VStack(alignment: .leading, spacing: Spacing.space1) {
                Text("Import GitHub projects").font(TypeStyle.title3).foregroundStyle(Color(.ink))
                Text(
                    "Pick repos; Kairos drafts a project entry for each from its name, languages and README. You review them before anything is saved."
                )
                .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                .fixedSize(horizontal: false, vertical: true)
            }
            if user == nil {
                notice("Add your GitHub URL in Contact first.", symbol: "person.text.rectangle")
            } else if loading {
                HStack(spacing: Spacing.space2) {
                    ProgressView().controlSize(.small)
                    Text("Listing your repos…").font(TypeStyle.body)
                }
            } else {
                repoList
            }
            if let problem {
                notice(problem, symbol: "exclamationmark.triangle.fill", color: Color(.error))
            }
            if problem?.contains("hourly limit") == true || problem?.contains("token") == true {
                LabeledField(title: "GitHub token", optional: true) {
                    SecureField("GitHub token", text: $token, prompt: Text("A read-only token lifts the hourly limit"))
                        .onSubmit {
                            ai.setGitHubToken(token)
                            Task { await load() }
                        }
                }
            }
            HStack(spacing: Spacing.space2) {
                if let progress {
                    ProgressView(value: Double(progress.done), total: Double(progress.total)).frame(width: 140)
                    Text("Drafting \(progress.done) of \(progress.total)…").font(TypeStyle.callout).monospacedDigit()
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Draft \(chosen.count) project\(chosen.count == 1 ? "" : "s")") { Task { await draft() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen.isEmpty || progress != nil)
            }
            .controlSize(.large)
        }
        .padding(Spacing.space6)
        .frame(width: 640)
        .task { await load() }
    }

    private var repoList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(repos.enumerated()), id: \.element.id) { index, repo in
                    if index > 0 { Divider().overlay(Color(.separatorRow)) }
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
                        Toggle("Choose \(repo.name)", isOn: binding(for: repo)).toggleStyle(.checkbox).labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: Spacing.space2) {
                                Text(repo.name).font(TypeStyle.headline).foregroundStyle(Color(.ink))
                                if repo.fork { tag("fork") }
                                if repo.archived { tag("archived") }
                            }
                            if let description = repo.description, !description.isEmpty {
                                Text(description).font(TypeStyle.callout).foregroundStyle(Color(.ink2)).lineLimit(2)
                            }
                        }
                        Spacer()
                        Text(
                            [repo.language, repo.stargazersCount > 0 ? "★ \(repo.stargazersCount)" : nil].compactMap {
                                $0
                            }.joined(separator: " · ")
                        )
                        .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).monospacedDigit()
                    }
                    .padding(.horizontal, Spacing.space3).padding(.vertical, Spacing.space2)
                }
                if repos.isEmpty {
                    Text("No public repos found.").font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                        .padding(Spacing.space3)
                }
            }
        }
        .frame(maxHeight: 360)
        .background(RoundedRectangle(cornerRadius: Radius.row).fill(Color(.surfaceGrouped)))
    }

    // MARK: - Work

    private func load() async {
        guard let user else { return }
        loading = true
        defer { loading = false }
        do {
            repos = try await GitHubClient(token: ai.gitHubToken()).repos(of: user)
            problem = nil
        } catch {
            problem = Self.describe(error)
        }
    }

    /// One repo at a time, so a slow or failed one doesn't block the rest; failures are reported.
    private func draft() async {
        let client = GitHubClient(token: ai.gitHubToken())
        let router = ai.router()
        let picked = repos.filter { chosen.contains($0.id) }
        var entries: [ResumeEntry] = []
        var failed: [String] = []
        progress = (0, picked.count)
        for repo in picked {
            do {
                let languages = (try? await client.languages(of: repo)) ?? [repo.language].compactMap { $0 }
                let readme = try? await client.readme(of: repo)
                let input = ImportGitHubRepoTask.Input(
                    repo: repo, languages: languages, readme: readme ?? nil, header: resume.resume.header)
                let result = try await router.run(ImportGitHubRepoTask(), input: input)
                entries.append(ImportGitHubRepoTask.entry(from: result.output, repo: repo))
            } catch {
                failed.append(repo.name)
            }
            progress = (entries.count + failed.count, picked.count)
        }
        progress = nil
        if entries.isEmpty {
            problem = "Couldn't draft those projects. Check your AI provider in Settings, then try again."
            return
        }
        if !failed.isEmpty { problem = "Skipped \(failed.joined(separator: ", ")); the rest are ready to review." }
        let session = ImportSession(router: nil)
        session.review(ImportDraft(entries: entries))
        review = session
    }

    // MARK: - Pieces

    private func binding(for repo: GitHubRepo) -> Binding<Bool> {
        Binding(
            get: { chosen.contains(repo.id) },
            set: { pick in
                if pick { chosen.insert(repo.id) } else { chosen.remove(repo.id) }
            })
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(TypeStyle.caption).foregroundStyle(Color(.inkSecondary))
            .padding(.horizontal, 6).frame(height: 18)
            .background(Capsule().fill(Color(.noBg)))
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

    static func describe(_ error: GitHubError) -> String {
        switch error {
        case .noProfile: "Add your GitHub URL in Contact first."
        case .userNotFound(let user): "GitHub has no user called \(user). Check the GitHub URL in Contact."
        case .rateLimited:
            "GitHub's hourly limit for requests without a token is reached. Add a token below, or try in an hour."
        case .tokenRejected: "GitHub rejected the token. Paste a new one below."
        case .http(let status): "GitHub answered with an error (\(status)). Try again later."
        case .network: "Couldn't reach GitHub."
        }
    }
}
