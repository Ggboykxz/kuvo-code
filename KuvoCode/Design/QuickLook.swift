import AppKit
import Quartz

/// The system's Quick Look panel for files the app shows: pictures to zoom into, and the rest
/// as Finder previews them. Space or Escape closes it.
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLook()
    /// The panel asks from the main thread.
    nonisolated(unsafe) private var urls: [URL] = []

    func show(_ urls: [URL], at index: Int = 0) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = min(index, urls.count - 1)
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
}
