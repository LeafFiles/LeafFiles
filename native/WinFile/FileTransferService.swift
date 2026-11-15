import Foundation
import Darwin

struct FileTransferProgress {
    var total: Int
    var completed = 0
    var currentName = ""
    var isMoving: Bool
    var completedBytes: Int64 = 0
    var totalBytes: Int64?
}
struct FileTransferOutcome {
    var completed: [URL] = []
    /// UU Remote completes the actual transfer independently after receiving its marker.
    var delegatedRemoteTransfers = 0
    var moves: [FileMoveRecord] = []
    var failures: [String] = []
    var cancelled = false
    var retryURLs: [URL] = []
    var destination: URL?
    var isMoving = false
    var clipboardGeneration: Int?

    var summary: String {
        let finished = L("operation.finished", "已完成 %d 项，失败 %d 项%@", completed.count,
                         failures.count, cancelled ? L("operation.cancelledSuffix", "（已取消）") : "")
        guard delegatedRemoteTransfers > 0 else { return finished }
        return finished + " · " + L("operation.uuRemotePending", "已交由 UU 远程接收，请在 UU 远程中查看传输结果")
    }
}

struct FileDeletionProgress {
    let total: Int
    var processed = 0
    var currentName = ""
    var isStopping = false
}

struct FileDeletionOutcome {
    var completed: [URL] = []
    var failures: [String] = []
    var cancelled = false
}

/// A native deletion cannot be interrupted safely halfway through a folder.
/// Cancellation prevents starting the next item and preserves partial results.
enum FileDeletionService {
    static func delete(_ urls: [URL], token: ScanCancellation,
                       remove: (URL) throws -> Void,
                       onProgress: (FileDeletionProgress) -> Void = { _ in }) -> FileDeletionOutcome {
        var outcome = FileDeletionOutcome()
        var progress = FileDeletionProgress(total: urls.count)
        var lastUpdate = 0.0
        for url in urls {
            if token.isCancelled { outcome.cancelled = true; break }
            progress.currentName = url.lastPathComponent
            let now = ProcessInfo.processInfo.systemUptime
            if progress.processed == 0 || now - lastUpdate >= 0.15 {
                onProgress(progress); lastUpdate = now
            }
            do { try remove(url); outcome.completed.append(url) }
            catch { outcome.failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            progress.processed += 1
        }
        outcome.cancelled = outcome.cancelled || (token.isCancelled && progress.processed < urls.count)
        onProgress(progress)
        return outcome
    }
}

/// Copies metadata and data through macOS copyfile into private destination staging.
/// The callback reports actual copied bytes and can interrupt the current data stream.
enum FileTransferService {
    private enum TransferError: LocalizedError {
        case uuRemoteMove
        var errorDescription: String? {
            L("operation.uuRemoteCopyOnly", "UU 远程文件请使用普通粘贴，不能使用移动粘贴。")
        }
    }
    static var uuRemoteClipboardDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.netease.uuremote/Clipboard", isDirectory: true)
    }

    static func isUURemoteMarker(_ item: FileItem, clipboardDirectory: URL) -> Bool {
        item.url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() ==
            clipboardDirectory.standardizedFileURL.resolvingSymlinksInPath()
            && item.name.hasPrefix(".uuremote_") && !item.isDirectory && !item.isSymlink && item.size == 0
    }
    private final class CopyContext {
        let token: ScanCancellation
        let update: (Int64, String) -> Void
        var copied: Int64 = 0
        var lastFileBytes: Int64 = 0
        init(token: ScanCancellation, update: @escaping (Int64, String) -> Void) { self.token = token; self.update = update }
    }
    private static let callback: copyfile_callback_t = { what, stage, state, source, _, raw in
        guard let raw else { return Int32(COPYFILE_QUIT) }
        let context = Unmanaged<CopyContext>.fromOpaque(raw).takeUnretainedValue()
        if context.token.isCancelled { return Int32(COPYFILE_QUIT) }
        if stage == COPYFILE_ERR || what == COPYFILE_RECURSE_ERROR { return Int32(COPYFILE_QUIT) }
        if what == COPYFILE_COPY_DATA {
            if stage == COPYFILE_START { context.lastFileBytes = 0 }
            var bytes: off_t = 0
            if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &bytes) == 0 {
                context.copied += max(0, Int64(bytes) - context.lastFileBytes)
                context.lastFileBytes = Int64(bytes)
                context.update(context.copied, source.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "")
            }
        }
        return Int32(COPYFILE_CONTINUE)
    }
    private static func copy(_ source: URL, to target: URL, token: ScanCancellation,
                             update: @escaping (Int64, String) -> Void) throws {
        guard let state = copyfile_state_alloc() else { throw POSIXError(.ENOMEM) }
        defer { copyfile_state_free(state) }
        let context = CopyContext(token: token, update: update)
        let raw = Unmanaged.passUnretained(context).toOpaque()
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), raw)
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_EXCL | COPYFILE_NOFOLLOW)
        let result = source.withUnsafeFileSystemRepresentation { from in
            target.withUnsafeFileSystemRepresentation { to in Darwin.copyfile(from, to, state, flags) }
        }
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        withExtendedLifetime(context) {}
    }

    static func transfer(_ items: [FileItem], to directory: URL, mode: FSEngine.TransferMode,
                         token: ScanCancellation, uuClipboardDirectory: URL = uuRemoteClipboardDirectory,
                         onProgress: @escaping (FileTransferProgress) -> Void) -> FileTransferOutcome {
        var outcome = FileTransferOutcome(destination: directory, isMoving: mode == .move)
        var progress = FileTransferProgress(total: items.count, isMoving: mode == .move)
        onProgress(progress)
        var sizes: [String: Int64] = [:]
        var complete = true
        for item in items {
            if token.isCancelled { break }
            if item.isDirectory && !item.isSymlink {
                let size = FileSystemService.directorySize(item.url, cancelled: { token.isCancelled })
                sizes[item.id] = size.bytes; complete = complete && size.isComplete
            } else { sizes[item.id] = item.isSymlink ? 0 : (item.size ?? 0) }
        }
        progress.totalBytes = complete ? sizes.values.reduce(0, +) : nil
        let fm = FileManager()
        var finished = Set<String>()
        for item in items {
            if token.isCancelled { outcome.cancelled = true; break }
            progress.currentName = item.name
            onProgress(progress)
            do {
                if isUURemoteMarker(item, clipboardDirectory: uuClipboardDirectory) {
                    guard mode == .copy else { throw TransferError.uuRemoteMove }
                    // UU watches for this exact marker in the final folder and writes the
                    // real files beside it asynchronously. Staging or renaming it breaks that handoff.
                    try fm.copyItem(at: item.url, to: directory.appendingPathComponent(item.name))
                    outcome.delegatedRemoteTransfers += 1
                    finished.insert(item.id)
                    progress.completed += 1
                    onProgress(progress)
                    continue
                }
                let destinationPath = directory.standardizedFileURL.resolvingSymlinksInPath().path
                let sourcePath = item.url.standardizedFileURL.resolvingSymlinksInPath().path
                if item.isDirectory && !item.isSymlink && (destinationPath == sourcePath || destinationPath.hasPrefix(sourcePath + "/")) { throw FSError.recursiveTransfer(item.name) }
                var target = FSEngine.uniqueURL(in: directory, name: item.name, isDirectory: item.isDirectory)
                if mode == .move, item.url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path == destinationPath {
                    target = item.url
                } else if mode == .copy {
                    let staging = directory.appendingPathComponent(".WinFile-transfer-\(UUID().uuidString)")
                    try fm.createDirectory(at: staging, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
                    defer { try? fm.removeItem(at: staging) }
                    let temporary = staging.appendingPathComponent(item.name)
                    let baseline = progress
                    var lastUpdate = Date.distantPast
                    var reportedBytes = false
                    try copy(item.url, to: temporary, token: token) { bytes, name in
                        if (bytes > 0 && !reportedBytes) || Date().timeIntervalSince(lastUpdate) >= 0.08 || token.isCancelled {
                            var update = baseline
                            update.completedBytes += bytes; update.currentName = name
                            onProgress(update); lastUpdate = Date(); reportedBytes = reportedBytes || bytes > 0
                        }
                    }
                    if token.isCancelled { outcome.cancelled = true; break }
                    target = FSEngine.uniqueURL(in: directory, name: item.name, isDirectory: item.isDirectory)
                    try fm.moveItem(at: temporary, to: target)
                } else {
                    try fm.moveItem(at: item.url, to: target)
                    if let record = FileMoveRecord(original: item.url, current: target) { outcome.moves.append(record) }
                }
                outcome.completed.append(target); finished.insert(item.id)
                progress.completed += 1; progress.completedBytes += sizes[item.id] ?? 0
                onProgress(progress)
            } catch {
                if token.isCancelled { outcome.cancelled = true; break }
                outcome.failures.append("\(item.name): \(error.localizedDescription)")
            }
        }
        outcome.cancelled = outcome.cancelled || token.isCancelled
        outcome.retryURLs = items.filter { !finished.contains($0.id) }.map(\.url)
        return outcome
    }
}
