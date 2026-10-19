import JobSources
import SwiftUI

/// Renders a job description: headings, paragraphs and lists as blocks, bold, italics and links
/// inline. The text is the employer's, so links open in the browser and nothing else is interpreted.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    init(_ markdown: String) {
        blocks = MarkdownBlock.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(_, let text):
                    inline(text).font(TypeStyle.headline).foregroundStyle(Color(.ink)).padding(.top, Spacing.space2)
                case .paragraph(let text):
                    inline(text).font(TypeStyle.body).foregroundStyle(Color(.ink2))
                case .item(let marker, let depth, let text):
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
                        Text(marker).monospacedDigit().foregroundStyle(Color(.inkSecondary))
                        inline(text).foregroundStyle(Color(.ink2))
                    }
                    .font(TypeStyle.body)
                    .padding(.leading, CGFloat(depth) * Spacing.space4)
                case .rule:
                    Divider()
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let attributed = try? AttributedString(markdown: text, options: options) else { return Text(text) }
        return Text(attributed)
    }
}
