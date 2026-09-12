import AppKit
import SwiftUI

struct ActivityView: View {
    let store: MonitoringStore

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.sectionSpacing) {
            ScreenHeader(
                title: "Activity",
                subtitle: "Storage changes, in order"
            ) {
                Text(store.activity.count == 1 ? "1 event" : "\(store.activity.count) events")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(store.activity.count) activity events")
            }

            folderWatchControls

            if store.activity.isEmpty {
                EmptyStateView(
                    symbol: "clock.arrow.circlepath",
                    title: "No activity yet",
                    message: "Mount, alert, pNFS, benchmark, and watched-folder state changes will appear here."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.activity) { event in
                            activityRow(event)
                            if event.id != store.activity.last?.id { Divider() }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            ProductLabel("Session only · no file contents read", systemImage: "hand.raised")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(LayoutMetrics.pageInset)
    }

    private func activityRow(_ event: ActivityEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ProductIcon(systemName: symbol(for: event))
                .foregroundStyle(event.provenance == .benchmark ? .purple : .secondary)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.eventDescription)
                    .fontWeight(.medium)
                HStack(spacing: 8) {
                    Text(event.displayPath)
                    Text("·")
                    Text(event.timestamp, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()
            ProvenanceBadge(provenance: event.provenance)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(event.eventDescription) \(event.displayPath). \(event.timestamp.formatted(date: .abbreviated, time: .shortened)). Data source \(event.provenance.rawValue.lowercased())."
        )
    }

    private var folderWatchControls: some View {
        InsetPanel {
            VStack(alignment: .leading, spacing: LayoutMetrics.compactSpacing) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: LayoutMetrics.contentSpacing) {
                        folderWatchStatus
                        Spacer(minLength: LayoutMetrics.contentSpacing)
                        folderWatchButtons
                    }

                    VStack(alignment: .leading, spacing: LayoutMetrics.compactSpacing) {
                        folderWatchStatus
                        folderWatchButtons
                    }
                }

                if let error = store.fileActivityError {
                    ProductLabel(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                        .help(error)
                        .accessibilityLabel("Folder monitoring error: \(error)")
                }
            }
            .padding(LayoutMetrics.rowSpacing)
        }
    }

    private var folderWatchStatus: some View {
        VStack(alignment: .leading, spacing: 3) {
            ProductLabel(
                store.watchedFolderLabel.map { "Watching \($0)" } ?? "No folder watched",
                systemImage: store.watchedFolderLabel == nil ? "folder" : "folder.badge.gearshape"
            )
            .font(.callout.weight(.medium))

            Text("Session only · redacted folder label · no file contents")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var folderWatchButtons: some View {
        HStack(spacing: LayoutMetrics.compactSpacing) {
            if store.watchedFolderLabel != nil {
                Button("Stop") {
                    store.stopWatchingFolder()
                }
                .help("Stop watching the selected folder")
            }

            Button(store.watchedFolderLabel == nil ? "Watch Folder…" : "Choose Another…") {
                chooseFolder()
            }
            .help("Choose one folder to watch for this session")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Watch Folder Activity"
        panel.message = "LumeFS monitors file-system events for this session. It does not retain full paths or read file contents."
        panel.prompt = "Watch Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let folderURL = panel.url else {
            return
        }

        store.watchFolder(folderURL)
    }

    private func symbol(for event: ActivityEvent) -> String {
        if event.provenance == .benchmark { return "speedometer" }
        if event.eventDescription.hasPrefix("Raised") { return "exclamationmark.triangle" }
        if event.eventDescription.hasPrefix("Cleared") { return "checkmark.circle" }
        if event.eventDescription.hasPrefix("Mounted") { return "externaldrive.badge.plus" }
        if event.eventDescription.hasPrefix("Unmounted") { return "externaldrive.badge.minus" }
        return "waveform.path.ecg"
    }
}
