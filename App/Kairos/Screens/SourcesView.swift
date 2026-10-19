import JobSources
import Store
import SwiftUI

/// The company watchlist: add a company by its careers page, see each board's status, pause or remove one.
struct SourcesView: View {
    @Environment(AppModel.self) private var model
    @State private var addingCompany = false
    @State private var selection: Source.ID?

    var body: some View {
        content
            .navigationTitle("Sources")
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        addingCompany = true
                    } label: {
                        Label("Add company", systemImage: "plus").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .sheet(isPresented: $addingCompany) { AddCompanySheet() }
    }

    @ViewBuilder private var content: some View {
        if model.sources.isEmpty {
            ContentUnavailableView {
                Label("No companies yet", systemImage: "antenna.radiowaves.left.and.right")
            } description: {
                Text("Choose Add company and paste a careers page from Greenhouse, Lever or Ashby.")
            }
        } else {
            Table(model.sources, selection: $selection) {
                TableColumn("Company") { source in
                    Text(source.displayName).font(TypeStyle.headline).foregroundStyle(Color(.ink))
                }
                .width(min: 160, ideal: 220)
                TableColumn("Job board") { source in
                    Text(source.kind.displayName).foregroundStyle(Color(.ink2))
                }
                .width(min: 90, ideal: 120)
                TableColumn("Open roles") { source in
                    Text(source.lastRunAt == nil ? "—" : "\(model.openRoles(for: source))")
                        .monospacedDigit().foregroundStyle(Color(.ink2))
                }
                .width(min: 70, ideal: 90)
                TableColumn("Last checked") { source in
                    Text(source.lastRunAt?.formatted(date: .abbreviated, time: .shortened) ?? "Not yet")
                        .monospacedDigit().foregroundStyle(Color(.inkSecondary))
                }
                .width(min: 110, ideal: 150)
                TableColumn("Status") { source in
                    SourceStatus(source: source, failure: model.failure(for: source))
                }
                .width(min: 140, ideal: 220)
            }
            .contextMenu(forSelectionType: Source.ID.self) { ids in
                if let id = ids.first, let source = model.source(id) {
                    Button(source.enabled ? "Pause" : "Resume") {
                        Task { await model.setEnabled(!source.enabled, for: source) }
                    }
                    Divider()
                    Button("Remove \(source.displayName)", role: .destructive) {
                        Task { await model.remove(source) }
                    }
                }
            }
        }
    }

    private var subtitle: String {
        let count = model.sources.count
        let watched = "\(count) compan\(count == 1 ? "y" : "ies") watched"
        guard let checked = model.sources.compactMap(\.lastRunAt).max() else { return watched }
        return "\(watched) · checked \(checked.formatted(date: .omitted, time: .shortened))"
    }
}

/// A dot or a warning, always with words: never colour alone.
private struct SourceStatus: View {
    let source: Source
    let failure: String?

    var body: some View {
        if !source.enabled {
            dot("Paused by you", Color(.inkSecondary))
        } else if let failure {
            warning("Can't reach", detail: failure)
        } else if source.health == .degraded {
            warning("No jobs in \(source.emptyRuns) checks", detail: "The board may have moved or been emptied.")
        } else if source.lastRunAt == nil {
            dot("Not checked yet", Color(.inkSecondary))
        } else {
            dot("Active", Color(.yes))
        }
    }

    private func dot(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(text).foregroundStyle(Color(.ink))
        }
    }

    private func warning(_ text: String, detail: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(Color(.error))
            .help(detail)
    }
}

/// Paste a careers page; Kairos says which board it found before you add it.
private struct AddCompanySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var careersURL = ""
    @State private var name = ""
    @State private var error: String?
    @State private var saving = false

    private var detection: ATSDetection? {
        careersURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : ATSDetector.detect(careersURL)
    }

    var body: some View {
        Form {
            Section {
                TextField("Careers page", text: $careersURL, prompt: Text("https://jobs.lever.co/company"))
                TextField("Company name", text: $name, prompt: Text("Optional"))
            } header: {
                Text("Add a company").font(TypeStyle.title3)
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.space1) {
                    switch detection {
                    case .detected(let kind, let slug)?:
                        Label("\(kind.displayName) board “\(slug)”", systemImage: "checkmark.circle")
                            .foregroundStyle(Color(.yes))
                    case .notDetected(let reason)?:
                        Label(reason, systemImage: "info.circle").foregroundStyle(Color(.inkSecondary))
                    case nil:
                        Text("Greenhouse, Lever and Ashby boards work today.").foregroundStyle(Color(.inkSecondary))
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color(.error))
                    }
                }
                .font(TypeStyle.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { Task { await add() } }
                    .disabled(saving || !isDetected)
            }
        }
    }

    private var isDetected: Bool {
        if case .detected? = detection { return true }
        return false
    }

    private func add() async {
        saving = true
        defer { saving = false }
        if let problem = await model.addCompany(careersURL: careersURL, name: name) {
            error = problem
        } else {
            dismiss()
        }
    }
}
