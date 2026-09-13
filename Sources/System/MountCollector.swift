import Darwin
import Foundation

struct MountCollector: Sendable {
    func collect(at date: Date = Date()) -> [VolumeSnapshot] {
        let mountCount = getfsstat(nil, 0, MNT_NOWAIT)
        guard mountCount > 0 else { return [] }

        var fileSystems = Array(
            repeating: Darwin.statfs(),
            count: Int(mountCount)
        )

        let bufferSize = Int32(
            MemoryLayout<statfs>.stride * fileSystems.count
        )

        let result = fileSystems.withUnsafeMutableBufferPointer { buffer in
            getfsstat(buffer.baseAddress, bufferSize, MNT_NOWAIT)
        }

        guard result > 0 else { return [] }

        return fileSystems.prefix(Int(result)).compactMap { fileSystem in
            makeSnapshot(from: fileSystem, at: date)
        }
    }

    private func makeSnapshot(
        from fileSystem: statfs,
        at date: Date
    ) -> VolumeSnapshot? {
        let mountPoint = string(from: fileSystem.f_mntonname)
        let source = string(from: fileSystem.f_mntfromname)
        let typeName = string(from: fileSystem.f_fstypename)

        guard shouldDisplay(mountPoint: mountPoint, typeName: typeName) else {
            return nil
        }

        let blockSize = Int64(fileSystem.f_bsize)
        let totalBytes = multipliedSafely(
            Int64(fileSystem.f_blocks),
            blockSize
        )
        let availableBytes = multipliedSafely(
            Int64(fileSystem.f_bavail),
            blockSize
        )

        let flags = UInt32(fileSystem.f_flags)
        let isReadOnly = (flags & UInt32(MNT_RDONLY)) != 0
        let isLocal = (flags & UInt32(MNT_LOCAL)) != 0
        let name = volumeName(mountPoint: mountPoint, source: source)

        return VolumeSnapshot(
            id: "\(source)|\(mountPoint)",
            name: name,
            mountPoint: mountPoint,
            source: source,
            fileSystem: kind(for: typeName),
            fileSystemName: typeName,
            totalBytes: max(0, totalBytes),
            availableBytes: max(0, availableBytes),
            isReadOnly: isReadOnly,
            isLocal: isLocal,
            capturedAt: date,
            smartStatus: nil,
            apfsVolumeQuotaBytes: nil,
            apfsVolumeReserveBytes: nil,
            fileNodesTotal: UInt64(fileSystem.f_files),
            fileNodesFree: UInt64(fileSystem.f_ffree),
            apfs: nil
        )
    }

    private func shouldDisplay(mountPoint: String, typeName: String) -> Bool {
        if mountPoint == "/" || mountPoint == "/System/Volumes/Data" { return true }
        if mountPoint.hasPrefix("/Volumes/") { return true }
        if typeName.lowercased().contains("nfs") { return true }
        return false
    }

    private func kind(for typeName: String) -> FileSystemKind {
        let normalized = typeName.lowercased()
        if normalized == "apfs" { return .apfs }
        if normalized.contains("nfs") { return .nfs }
        if normalized == "autofs" { return .autofs }
        return .other
    }

    private func volumeName(mountPoint: String, source: String) -> String {
        if mountPoint == "/" { return "Macintosh HD" }

        let component = URL(fileURLWithPath: mountPoint).lastPathComponent
        if !component.isEmpty { return component }
        return source
    }

    private func multipliedSafely(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        return result.overflow ? 0 : result.partialValue
    }

    private func string<T>(from value: T) -> String {
        withUnsafePointer(to: value) { pointer in
            pointer.withMemoryRebound(
                to: CChar.self,
                capacity: MemoryLayout<T>.size
            ) {
                String(cString: $0)
            }
        }
    }
}
