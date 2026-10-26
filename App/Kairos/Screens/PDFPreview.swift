import PDFKit
import SwiftUI

/// A build's PDF, scaled to fit, one page after another (PDFKit). Selecting text in it reports
/// what was selected, so the trace can follow the line you picked.
struct PDFPreview: NSViewRepresentable {
    let url: URL
    var onSelect: (String) -> Void = { _ in }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = NSColor(resource: .surfaceRaised)
        view.document = PDFDocument(url: url)
        context.coordinator.observe(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.onSelect = onSelect
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    @MainActor
    final class Coordinator: NSObject {
        var onSelect: (String) -> Void
        private var token: (any NSObjectProtocol)?

        init(onSelect: @escaping (String) -> Void) {
            self.onSelect = onSelect
        }

        func observe(_ view: PDFView) {
            token = NotificationCenter.default.addObserver(
                forName: .PDFViewSelectionChanged, object: view, queue: .main
            ) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let text = view?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                        text.count >= 3
                    else { return }
                    self?.onSelect(text)
                }
            }
        }
    }
}
