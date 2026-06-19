import Foundation
import WebKit
import Combine

/// Lifecycle of a single download. `interrupted` is a persisted-only state: a
/// download left `inProgress` when the app quit (WKWebView downloads can't resume
/// across termination), migrated on the next launch. Raw values are the persisted
/// `state` strings in `DownloadStore`.
enum DownloadState: String, Equatable {
    case inProgress
    case completed
    case failed
    case cancelled
    case interrupted
}

/// One tracked download. Observes the underlying `WKDownload.progress` so byte
/// counts stay live, and exposes the source/destination + state for the slice-B UI.
/// In-memory only for now (no persistence).
@MainActor
final class DownloadItem: ObservableObject, Identifiable {
    let id: UUID

    /// Where the file is coming from (the original request URL, if known).
    let sourceURL: URL?
    /// When the download started (or was first persisted).
    let dateAdded: Date
    /// When it reached a terminal state (completed/failed/cancelled/interrupted).
    private(set) var dateCompleted: Date?
    /// Final on-disk location, set once a destination is decided (in ~/Downloads).
    @Published private(set) var destinationURL: URL?
    /// Display name; provisional until `decideDestination` supplies the real one.
    @Published private(set) var filename: String
    /// Total expected bytes (`-1`/`0` while unknown), mirrored from `progress`.
    @Published private(set) var totalBytes: Int64 = 0
    /// Bytes received so far, mirrored from `progress`.
    @Published private(set) var receivedBytes: Int64 = 0
    @Published private(set) var state: DownloadState = .inProgress

    /// The live WebKit download. `nil` for items reconstructed from the store (a
    /// finished/interrupted download from a prior launch has no live download).
    fileprivate let download: WKDownload?
    private var observations: [NSKeyValueObservation] = []

    /// Live download from WebKit.
    init(download: WKDownload, sourceURL: URL?, suggestedFilename: String) {
        self.id = UUID()
        self.download = download
        self.sourceURL = sourceURL
        self.filename = suggestedFilename
        self.dateAdded = Date()

        // Mirror the WKDownload's Progress into @Published byte counts. The KVO
        // callback can arrive off the main thread, so read the Sendable Int64s
        // synchronously and hop to the main actor to publish.
        let progress = download.progress
        totalBytes = progress.totalUnitCount
        receivedBytes = progress.completedUnitCount
        for keyPath in [\Progress.completedUnitCount, \Progress.totalUnitCount] {
            observations.append(progress.observe(keyPath, options: [.new]) { [weak self] progress, _ in
                let received = progress.completedUnitCount
                let total = progress.totalUnitCount
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.receivedBytes = received
                    self.totalBytes = total
                    DownloadManager.shared.itemProgressDidChange()   // refresh rail ring
                    #if DEBUG
                    print("[Download] progress \(self.filename) \(received)/\(total > 0 ? "\(total)" : "?") bytes")
                    #endif
                }
            })
        }
    }

    /// Reconstruct a finished download from a persisted record (no live download).
    init(record: DownloadRecord) {
        self.id = UUID(uuidString: record.id) ?? UUID()
        self.download = nil
        self.sourceURL = record.sourceURL.flatMap(URL.init(string:))
        self.dateAdded = record.dateAdded
        self.dateCompleted = record.dateCompleted
        self.filename = record.filename
        self.destinationURL = record.destinationPath.map { URL(fileURLWithPath: $0) }
        self.totalBytes = record.totalBytes
        self.receivedBytes = record.receivedBytes
        // Defensive: any stray inProgress row is treated as interrupted (the store
        // migrates these at launch, so this should not normally trigger).
        self.state = DownloadState(rawValue: record.state) ?? .interrupted
    }

    /// A completed download whose file is no longer at its destination — shown but
    /// not revealable. Cheap `stat`; only meaningful for completed items.
    var fileIsMissing: Bool {
        guard state == .completed, let url = destinationURL else { return false }
        return !FileManager.default.fileExists(atPath: url.path)
    }

    /// Snapshot for persistence.
    func makeRecord() -> DownloadRecord {
        DownloadRecord(
            id: id.uuidString,
            filename: filename,
            sourceURL: sourceURL?.absoluteString,
            sourceHost: sourceURL?.host,
            destinationPath: destinationURL?.path,
            totalBytes: totalBytes,
            receivedBytes: receivedBytes,
            state: state.rawValue,
            dateAdded: dateAdded,
            dateCompleted: dateCompleted
        )
    }

    /// Adopt the real destination/name decided by the manager.
    fileprivate func setDestination(_ url: URL) {
        destinationURL = url
        filename = url.lastPathComponent
    }

    fileprivate func markState(_ newState: DownloadState) {
        state = newState
        if newState != .inProgress { dateCompleted = Date() }
    }

    /// Cancel an in-progress download (no resume kept).
    func cancel() {
        DownloadManager.shared.cancel(self)
    }
}

/// Owns active + finished downloads and acts as every download's delegate. Created
/// by the navigation delegate (`HistoryRecorder`) when WebKit converts a response or
/// navigation action into a `WKDownload` — there is no second navigation delegate.
@MainActor
final class DownloadManager: NSObject, ObservableObject, WKDownloadDelegate {
    static let shared = DownloadManager()

    /// Downloads still running. Slice-B UI will render these.
    @Published private(set) var active: [DownloadItem] = []
    /// Completed / failed / cancelled downloads, most recent first.
    @Published private(set) var finished: [DownloadItem] = []
    /// True once a download has completed without the popover being opened since.
    /// Drives the rail icon's green "completed" tint; cleared on `acknowledge()`.
    @Published private(set) var hasUnacknowledgedCompletion = false

    /// Maps a live `WKDownload` to its tracked item for delegate callbacks.
    private var itemsByDownload: [ObjectIdentifier: DownloadItem] = [:]

    private override init() { super.init() }

    // MARK: - UI actions (slice 2b)

    /// Opening the downloads popover acknowledges any completed downloads, so the
    /// rail icon reverts from green to idle.
    func acknowledge() { hasUnacknowledgedCompletion = false }

    /// "Clear all": drop every finished/failed/cancelled/interrupted entry from both
    /// the in-memory list and the persisted store. In-progress downloads keep running
    /// (their persisted row survives and re-upserts on completion).
    func clearFinished() {
        finished.removeAll()
        Task { await DownloadStore.shared.clearFinished() }
    }

    /// Remove a single finished entry from the list and the store (row's ✕).
    func remove(_ item: DownloadItem) {
        finished.removeAll { $0 === item }
        let id = item.id.uuidString
        Task { await DownloadStore.shared.delete(id: id) }
    }

    /// Load persisted downloads at launch: migrate any prior-run in-progress rows to
    /// interrupted, prune past the retention window, then populate `finished`.
    func loadPersisted() async {
        await DownloadStore.shared.migrateInterruptedOnLaunch()
        await DownloadStore.shared.prune(olderThan: Date().addingTimeInterval(-DownloadStore.retentionInterval))
        let records = await DownloadStore.shared.all()
        // Keep any items added during the brief launch window on top; dedupe by id
        // so a download that finished mid-load isn't listed twice.
        let existingIDs = Set(finished.map(\.id))
        let loaded = records.map { DownloadItem(record: $0) }.filter { !existingIDs.contains($0.id) }
        finished = finished + loaded
    }

    /// Persist a snapshot of `item` (insert on start, update on terminal events).
    private func persist(_ item: DownloadItem) {
        let record = item.makeRecord()
        Task { await DownloadStore.shared.upsert(record) }
    }

    /// An active item's byte counts changed. The `active` array reference is
    /// unchanged, so nudge our own observers (the rail icon's aggregate ring)
    /// to recompute. Rows in the popover observe their item directly.
    func itemProgressDidChange() { objectWillChange.send() }

    /// Called from the navigation delegate's `…didBecome download:` hooks. Sets us
    /// as the download's delegate and starts tracking it.
    func register(_ download: WKDownload) {
        download.delegate = self
        let source = download.originalRequest?.url
        let provisionalName = source?.lastPathComponent.isEmpty == false
            ? source!.lastPathComponent : "download"
        let item = DownloadItem(download: download, sourceURL: source, suggestedFilename: provisionalName)
        itemsByDownload[ObjectIdentifier(download)] = item
        active.append(item)
    }

    func cancel(_ item: DownloadItem) {
        item.download?.cancel { _ in }   // discard resume data
        item.markState(.cancelled)
        downloadLog("cancelled \(item.filename)")
        moveToFinished(item)
        persist(item)
    }

    // MARK: - WKDownloadDelegate

    /// Decide where the file lands. We compute a collision-free path in ~/Downloads
    /// off the main thread (file I/O), then hand it back. Never overwrites.
    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let item = itemsByDownload[ObjectIdentifier(download)]
        DispatchQueue.global(qos: .userInitiated).async {
            let destination = Self.uniqueDownloadsURL(forSuggestedName: suggestedFilename)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let destination, let item {
                        item.setDestination(destination)
                        self.persist(item)   // write an inProgress row now (interrupted-on-quit detection)
                        self.downloadLog("started \(destination.lastPathComponent)")
                    } else {
                        self.downloadLog("started \(suggestedFilename) — no destination")
                    }
                    completionHandler(destination)
                }
            }
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = itemsByDownload[ObjectIdentifier(download)] else { return }
        item.markState(.completed)
        downloadLog("finished \(item.filename)")
        moveToFinished(item)
        persist(item)
        hasUnacknowledgedCompletion = true   // rail icon ring turns green until acknowledged
        // Note: deliberately do NOT open the file (no auto-open).
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = itemsByDownload[ObjectIdentifier(download)] else { return }
        item.markState(.failed)
        downloadLog("failed \(item.filename) — \(error.localizedDescription)")
        moveToFinished(item)
        persist(item)
    }

    // MARK: - Helpers

    private func moveToFinished(_ item: DownloadItem) {
        active.removeAll { $0 === item }
        itemsByDownload = itemsByDownload.filter { $0.value !== item }
        if !finished.contains(where: { $0 === item }) {
            finished.insert(item, at: 0)
        }
    }

    /// Build a non-overwriting URL in the user's ~/Downloads. On collision appends
    /// " (1)", " (2)", … before the extension. Runs off-main (FileManager I/O).
    nonisolated static func uniqueDownloadsURL(forSuggestedName suggested: String) -> URL? {
        let fm = FileManager.default
        guard let downloads = try? fm.url(for: .downloadsDirectory, in: .userDomainMask,
                                          appropriateFor: nil, create: true) else {
            return nil
        }
        let trimmed = suggested.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "download" : trimmed

        var candidate = downloads.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }

        let ext = candidate.pathExtension
        let base = candidate.deletingPathExtension().lastPathComponent
        var counter = 1
        repeat {
            let next = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = downloads.appendingPathComponent(next)
            counter += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    private func downloadLog(_ message: String) {
        #if DEBUG
        print("[Download] \(message)")
        #endif
    }
}
