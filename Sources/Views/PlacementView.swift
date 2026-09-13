import AppKit
import SwiftUI

/// Plan where data should live, then copy it there — never move, never delete.
/// Every copy is a dry run first, requires one explicit confirmation, shows
/// progress, can be cancelled, and is written to a local journal.
struct PlacementView: View {
    let store: MonitoringStore
    @State private var isConfirmingCopy = false

    private var controller: MigrationController { store.placement }

    private var writableVolumes: [VolumeSnapshot] {
        store.volumes.filter { !$0.isReadOnly && $0.mountPoint != "/" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LayoutMetrics.sectionSpacing) {
                ScreenHeader(
                    title: "Placement",
                    subtitle: "Plan a copy to another volume, confirm it, keep the original"
                ) {
                    ProvenanceBadge(provenance: .estimate)
                }

                pairPanel

                if controller.isPlanning {
                    planningPanel
                } else if let error = controller.planError {
                    errorPanel(error)
                } else if let plan = controller.plan {
                    planPanel(plan)
                }

                if controller.isCopying, let progress = controller.progress {
                    progressPanel(progress)
                }

                if let result = controller.result {
                    resultPanel(result)
                }

                journalSection

                ProductLabel(
                    "Copies only · never deletes, moves or overwrites · confirmation required · journal stored locally",
                    systemImage: "hand.raised"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(LayoutMetrics.pageInset)
        }
    }

    // MARK: Source and destination

    private var pairPanel: some View {
        InsetPanel {
            VStack(alignment: .leading, spacing: LayoutMetrics.rowSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: LayoutMetrics.contentSpacing) {
                    Text("Source")
                        .foregroundStyle(.secondary)
                        .frame(width: 100, alignment: .leading)
                    Text(controller.sourceURL?.path ?? "No source chosen")
                        .monospaced()
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .foregroundStyle(controller.sourceURL == nil ? Color.secondary : Color.primary)
                    Spacer(minLength: 0)
                    Button(controller.sourceURL == nil ? "Choose Source…" : "Change…") {
                        chooseSource()
                    }
                    .help("Choose the folder or file to copy; it is read, never modified")
                    .disabled(controller.isCopying)
                }
                .accessibilityElement(children: .combine)

                Divider()

                HStack(alignment: .firstTextBaseline, spacing: LayoutMetrics.contentSpacing) {
                    Text("Destination")
                        .foregroundStyle(.secondary)
                        .frame(width: 100, alignment: .leading)
                    Picker("Destination volume", selection: volumeSelection) {
                        Text("Choose a volume").tag(String?.none)
                        ForEach(writableVolumes) { volume in
                            Text("\(volume.name) · \(MetricFormatter.bytes(volume.availableBytes)) free")
                                .tag(Optional(volume.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 360)
                    .disabled(controller.isCopying)
                    .help("Writable mounted volumes; the copy is created at the volume root")
                    Text("or")
                        .foregroundStyle(.secondary)
                    Button(controller.destinationFolder == nil ? "Choose Folder…" : "Change Folder…") {
                        chooseDestinationFolder()
                    }
                    .help("Choose a folder; the copy is created inside it")
                    .disabled(controller.isCopying)
                    Spacer(minLength: 0)
                }

                if let root = controller.destinationRoot(volumes: store.volumes) {
                    let name = controller.sourceURL?.lastPathComponent ?? "<source name>"
                    Text("The copy will be created at \(root.appendingPathComponent(name).path)")
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                HStack(spacing: LayoutMetrics.compactSpacing) {
                    if controller.isPlanning {
                        Button("Cancel") { controller.cancelPlanning() }
                            .help("Stop walking the source; nothing has been written")
                    } else {
                        Button("Plan Copy (Dry Run)") {
                            controller.makePlan(volumes: store.volumes)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!controller.canPlan)
                        .help("Walk the source, check the destination and free space; nothing is written")
                    }
                    Text("A plan reads metadata only. Nothing is written until you confirm.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(LayoutMetrics.rowSpacing)
        }
    }

    private var volumeSelection: Binding<String?> {
        Binding(
            get: { controller.destinationVolumeID },
            set: { controller.selectDestinationVolume($0) }
        )
    }

    // MARK: Plan

    private var planningPanel: some View {
        InsetPanel {
            HStack(spacing: LayoutMetrics.contentSpacing) {
                ProgressView()
                    .controlSize(.small)
                Text("Walking the source and checking the destination…")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(LayoutMetrics.rowSpacing)
            .accessibilityElement(children: .combine)
        }
    }

    private func errorPanel(_ message: String) -> some View {
        InsetPanel {
            ProductLabel(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .lineLimit(4)
                .padding(LayoutMetrics.rowSpacing)
                .accessibilityLabel("Plan rejected: \(message)")
        }
    }

    private func planPanel(_ plan: MigrationPlan) -> some View {
        InsetPanel {
            VStack(alignment: .leading, spacing: LayoutMetrics.rowSpacing) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Plan")
                        .font(.headline)
                    Spacer()
                    Label(plan.fits ? "Fits" : "Does not fit", systemImage: plan.fits ? "checkmark.circle" : "xmark.octagon")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(plan.fits ? Color.green : Color.red)
                    ProvenanceBadge(provenance: plan.provenance)
                }

                VStack(alignment: .leading, spacing: 6) {
                    PlacementRow(label: "Source", value: plan.sourceURL.path)
                    PlacementRow(label: "Destination", value: plan.destinationURL.path)
                    PlacementRow(label: "Volume", value: "\(plan.destinationVolumeName) (\(plan.destinationMountPoint))")
                    PlacementRow(label: "Contents", value: contentsLabel(plan.inventory))
                    PlacementRow(label: "Data", value: "\(MetricFormatter.bytes(plan.inventory.totalBytes)) · largest file \(MetricFormatter.bytes(plan.inventory.largestFileBytes))")
                    PlacementRow(label: "Required", value: "\(MetricFormatter.bytes(plan.requiredBytes)) (data + 20% margin)")
                    PlacementRow(label: "Available", value: "\(MetricFormatter.bytes(plan.destinationAvailableBytes)) on \(plan.destinationVolumeName), purgeable space not counted")
                }

                if plan.sameVolume {
                    ProductLabel("Source and destination are on the same volume: this copy frees no space there. On APFS it becomes a clone.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if plan.inventory.unreadableCount > 0 {
                    ProductLabel("\(plan.inventory.unreadableCount) item(s) could not be read and would be skipped.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack(spacing: LayoutMetrics.compactSpacing) {
                    Button("Copy…") {
                        isConfirmingCopy = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!plan.fits || controller.isCopying)
                    .help("Copy after an explicit confirmation; the original is never deleted")
                    .confirmationDialog(
                        "Copy \(plan.inventory.fileCount) file(s), \(MetricFormatter.bytes(plan.inventory.totalBytes)), to \(plan.destinationVolumeName)?",
                        isPresented: $isConfirmingCopy,
                        titleVisibility: .visible
                    ) {
                        Button("Copy") {
                            controller.startCopy()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("LumeFS creates \(plan.destinationURL.path) and copies into it. \(plan.sourceURL.path) is never deleted or modified. You can cancel at any time; anything already copied stays in place.")
                    }

                    Button("Discard Plan") {
                        controller.discardPlan()
                    }
                    .disabled(controller.isCopying)
                }
            }
            .padding(LayoutMetrics.rowSpacing)
        }
    }

    private func contentsLabel(_ inventory: MigrationInventory) -> String {
        var parts = ["\(inventory.fileCount) file(s)", "\(inventory.directoryCount) folder(s)"]
        if inventory.symlinkCount > 0 { parts.append("\(inventory.symlinkCount) symlink(s), copied as links") }
        return parts.joined(separator: ", ")
    }

    // MARK: Progress

    private func progressPanel(_ progress: MigrationProgress) -> some View {
        InsetPanel {
            VStack(alignment: .leading, spacing: LayoutMetrics.compactSpacing) {
                HStack {
                    Text("Copying")
                        .font(.headline)
                    Spacer()
                    Button("Cancel") {
                        controller.cancelCopy()
                    }
                    .help("Stop after the current block; copied files stay, the original is untouched")
                }
                ProgressView(value: progress.fraction)
                    .accessibilityLabel("Copy progress")
                    .accessibilityValue(MetricFormatter.percentage(progress.fraction))
                HStack {
                    Text("\(progress.copiedFiles) of \(progress.totalFiles) file(s) · \(MetricFormatter.bytes(progress.copiedBytes)) of \(MetricFormatter.bytes(progress.totalBytes))")
                        .monospacedDigit()
                    Spacer()
                    if let item = progress.currentItem {
                        Text(item)
                            .monospaced()
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(LayoutMetrics.rowSpacing)
        }
    }

    // MARK: Result

    private func resultPanel(_ result: MigrationResult) -> some View {
        InsetPanel {
            VStack(alignment: .leading, spacing: LayoutMetrics.rowSpacing) {
                HStack(alignment: .firstTextBaseline) {
                    Label(outcomeTitle(result.outcome), systemImage: outcomeSymbol(result.outcome))
                        .font(.headline)
                        .foregroundStyle(outcomeColor(result.outcome))
                    Spacer()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([result.destinationURL])
                    }
                    .help("Show the copy in Finder")
                    Button("Dismiss") {
                        controller.dismissResult()
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    PlacementRow(label: "Copied", value: "\(result.copiedFiles) file(s), \(MetricFormatter.bytes(result.copiedBytes)); \(result.verifiedFiles) size-verified")
                    PlacementRow(label: "Duration", value: durationLabel(result.elapsedSeconds))
                    PlacementRow(label: "Destination", value: result.destinationURL.path)
                    if let failure = result.failureDescription {
                        PlacementRow(label: "Error", value: failure)
                    }
                    if let incomplete = result.incompleteItem {
                        PlacementRow(label: "Incomplete", value: "\(incomplete) — left in place; verify or remove it yourself")
                    }
                }

                ProductLabel(
                    result.outcome == .completed
                        ? "The original is untouched. Nothing was deleted; verify the copy before removing anything yourself."
                        : "The original is untouched. A partial copy remains at the destination; nothing was deleted.",
                    systemImage: "hand.raised"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(LayoutMetrics.rowSpacing)
        }
    }

    private func outcomeTitle(_ outcome: MigrationOutcome) -> String {
        switch outcome {
        case .completed: "Copy completed"
        case .cancelled: "Copy cancelled"
        case .failed: "Copy failed"
        }
    }

    private func outcomeSymbol(_ outcome: MigrationOutcome) -> String {
        switch outcome {
        case .completed: "checkmark.circle"
        case .cancelled: "stop.circle"
        case .failed: "xmark.octagon"
        }
    }

    private func outcomeColor(_ outcome: MigrationOutcome) -> Color {
        switch outcome {
        case .completed: .green
        case .cancelled: .orange
        case .failed: .red
        }
    }

    private func durationLabel(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "under a second" : "\(Int(seconds.rounded())) s"
    }

    // MARK: Journal

    private var journalSection: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.compactSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text("Journal")
                    .font(.headline)
                Spacer()
                Text(controller.journal.entries.count == 1 ? "1 entry" : "\(controller.journal.entries.count) entries")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if controller.journal.entries.isEmpty {
                Text("Plans and copies made from this Mac appear here, newest first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                InsetPanel {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(controller.journal.newestFirst) { entry in
                            journalRow(entry)
                            if entry.id != controller.journal.entries.first?.id { Divider() }
                        }
                    }
                }
            }

            if let url = controller.journalFileURL {
                Text("Stored in \(url.path) · full source and destination paths · \(MigrationJournal.maximumEntries) entries maximum")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("Journal kept in memory for this session only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = controller.journalError {
                ProductLabel(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func journalRow(_ entry: MigrationJournalEntry) -> some View {
        HStack(alignment: .top, spacing: LayoutMetrics.rowSpacing) {
            Text(entry.kind.rawValue.capitalized)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(entry.sourcePath) → \(entry.destinationPath)")
                    .monospaced()
                    .font(.callout)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                    Text("·")
                    Text("\(entry.fileCount) file(s), \(MetricFormatter.bytes(entry.byteCount))")
                    if let detail = entry.detail {
                        Text("·")
                        Text(detail)
                            .lineLimit(2)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LayoutMetrics.rowSpacing)
        .padding(.vertical, LayoutMetrics.compactSpacing)
        .accessibilityElement(children: .combine)
    }

    // MARK: Panels

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.title = "Choose What to Copy"
        panel.message = "LumeFS reads this folder or file to plan and copy it. It is never modified or deleted."
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.setSource(url)
    }

    private func chooseDestinationFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Destination Folder"
        panel.message = "The copy is created inside this folder under the source's name. Existing items are never overwritten."
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.selectDestinationFolder(url)
    }
}

private struct PlacementRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LayoutMetrics.contentSpacing) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .monospaced()
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
