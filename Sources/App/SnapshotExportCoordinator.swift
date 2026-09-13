import AppKit
import UniformTypeIdentifiers

/// Presents the standard save panel and hands the chosen location to the store.
/// The panel is the only place a path enters the export flow; the store never
/// picks a destination on its own.
@MainActor
enum SnapshotExportCoordinator {
    static func export(from store: MonitoringStore, format: SnapshotExportFormat) {
        let panel = NSSavePanel()
        panel.title = "Export Snapshot"
        panel.message = "Saves the current measurements, active alerts and alert history with their provenance. Nothing is re-collected."
        panel.prompt = "Export"
        panel.nameFieldStringValue = SnapshotExporter.suggestedFileName(at: Date(), format: format)
        panel.allowedContentTypes = [contentType(for: format)]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.exportSnapshot(format: format, to: url)
    }

    static func contentType(for format: SnapshotExportFormat) -> UTType {
        switch format {
        case .json: .json
        case .csv: .commaSeparatedText
        }
    }
}
