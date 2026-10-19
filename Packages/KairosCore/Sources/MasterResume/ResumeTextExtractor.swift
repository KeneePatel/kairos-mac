import Foundation
import PDFKit

/// Gets plain text out of a resume PDF (PDFKit) for import. Pasted text needs none of this.
public enum ResumeTextExtractor {
    public static func text(fromPDF data: Data) throws(ImportError) -> String {
        guard let document = PDFDocument(data: data), let raw = document.string else { throw .unreadablePDF }
        // PDFs often carry runs of blank lines and stray spaces; keep paragraphs, drop the noise.
        let lines = raw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var kept: [String] = []
        for line in lines where !(line.isEmpty && (kept.last?.isEmpty ?? true)) {
            kept.append(line)
        }
        let text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .emptyText }  // a scanned PDF with no text layer
        return text
    }
}
