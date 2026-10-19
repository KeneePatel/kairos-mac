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
    @Binding var editing: ResumeEntry?
    @Binding var deleting: ResumeEntry?

    var body: some View {
        ForEach(EntryKind.additional, id: \.self) { kind in
            EntryList(kind: kind, editing: $editing, deleting: $deleting)
        }
    }
}

/// One kind's entries as rows; click to edit, context menu to move or delete.
struct EntryList: View {
    @Environment(ResumeModel.self) private var model
    let kind: EntryKind
    @Binding var editing: ResumeEntry?
    @Binding var deleting: ResumeEntry?

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
        .contextMenu { EntryMenu(entry: entry, editing: $editing, deleting: $deleting) }
    }
}
