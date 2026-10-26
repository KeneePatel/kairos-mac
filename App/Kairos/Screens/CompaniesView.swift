import Screening
import Store
import SwiftUI

/// The companies whose boards Kairos reads (job collection v3, C4): one list, filtered Hiring for
/// you · Watching · Found · Muted · All, with the chosen board beside it. A catalog board appears
/// only once it has a role for you; the rest are checked quietly.
struct CompaniesView: View {
    @Environment(AppModel.self) private var model
    var addCompany: () -> Void = {}
    var changeAdzuna: () -> Void = {}
    @State private var path: [JobID] = []
    @State private var selection: Source.ID?
    @State private var scope = SourcesTable.Scope.hiring
    @State private var search = ""

    var body: some View {
        ListPaneLayout(listWidth: 640) {
            VStack(spacing: 0) {
                ColumnTitle(title: "Companies", line: countLine)
                SourcesTable(selection: $selection, scope: scope, search: search)
                Divider()
                Text("↑↓ move · ↩ open the board · P pause or resume")
                    .font(TypeStyle.caption).foregroundStyle(Color(.inkSecondary)).lineLimit(1)
                    .padding(.horizontal, Spacing.space6).padding(.vertical, Spacing.space3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } pane: {
            if let id = selection, let source = model.source(id) {
                SourcePane(source: source, changeAdzuna: changeAdzuna) { path.append($0) }
            } else {
                EmptyState("Nothing selected", "Choose a company in the list.")
            }
        }
        .navigationTitle("Companies")
        .searchable(text: $search, placement: .toolbar, prompt: "Search companies")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Show", selection: $scope) {
                    ForEach(SourcesTable.Scope.allCases) { scope in
                        Text("\(scope.rawValue) \(model.companies(in: scope).count)").tag(scope)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().monospacedDigit().fixedSize()
                Button {
                    addCompany()
                } label: {
                    Label("Add company", systemImage: "plus").labelStyle(.titleAndIcon)
                }
            }
            RunControls(model: model, title: "Find new jobs")
        }
        .navigationDestination(for: JobID.self) { JobScreen(id: $0) }
        .task(id: "\(scope.rawValue)-\(model.sources.count)") {
            let shown = model.companies(in: scope)
            if selection.map({ id in !shown.contains { $0.id == id } }) ?? true { selection = shown.first?.id }
        }
    }

    /// "163 hiring for you · 19 you added · 42 found by Kairos · 794 from the catalog, checked quietly".
    private var countLine: String {
        let hiring = model.companies(in: .hiring).count
        let watching = model.companies(in: .watching).count
        let found = model.companies(in: .found).count
        let catalog = model.sources.count(where: \.isFromCatalog)
        var parts = [
            "\(hiring) hiring for you", "\(watching) you added", "\(found) found by Kairos",
        ]
        if catalog > 0 { parts.append("\(catalog) from the catalog, checked quietly") }
        return parts.joined(separator: " · ")
    }
}
