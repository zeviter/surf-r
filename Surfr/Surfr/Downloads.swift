import Foundation
import WebKit
import Combine

/// Lifecycle of a single download (slice A: tracking only — UI is slice B).
enum DownloadState: Equatable {
    case inProgress
    case completed
    case failed
    case cancelled
}

/// One tracked download. Observes the underlying `WKDownload.progress` so byte
/// counts stay live, and exposes the source/destination + state for the slice-B UI.
/// In-memory only for now (no persistence).
@MainActor
final class DownloadItem: ObservableObject, Identifiable {
    let id = UUID()

    /// Where the file is coming from (the original request URL, if known).
    let sourceURL: URL?
    /// Final on-disk location, set once a destination is decided (in ~/Downloads).
    @Published private(set) var destinationURL: URL?
    /// Display name; provisional until `decideDestination` supplies the real one.
    @Published private(set) var filename: String
    /// Total expected bytes (`-1`/`0` while unknown), mirrored from `progress`.
    @Published private(set) var totalBytes: Int64 = 0
    /// Bytes received so far, mirrored from `progress`.
    @Published private(set) var receivedBytes: Int64 = 0
    @Published private(set) var state: DownloadState = .inProgress

    /// The live WebKit download. `fileprivate` so the manager can cancel it.
    fileprivate let download: WKDownload
    private var observations: [NSKeyValueObservation] = []

    init(download: WKDownload, sourceURL: URL?, suggestedFilename: String) {
        self.download = download
        self.sourceURL = sourceURL
        self.filename = suggestedFilename

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
                    #if DEBUG
                    print("[Download] progress \(self.filename) \(received)/\(total > 0 ? "\(total)" : "?") bytes")
                    #endif
                }
            })
        }
    }

    /// Adopt the real destination/name decided by the manager.
    fileprivate func setDestination(_ url: URL) {
        destinationURL = url
        filename = url.lastPathComponent
    }

    fileprivate func markState(_ newState: DownloadState) {
        state = newState
    }

    /// Cancel an in-progress download (no resume kept; slice A).
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

    /// Maps a live `WKDownload` to its tracked item for delegate callbacks.
    private var itemsByDownload: [ObjectIdentifier: DownloadItem] = [:]

    private override init() { super.init() }

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
        item.download.cancel { _ in }   // discard resume data (slice A)
        item.markState(.cancelled)
        downloadLog("cancelled \(item.filename)")
        moveToFinished(item)
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
                    if let destination {
                        item?.setDestination(destination)
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
        // Note: deliberately do NOT open the file (no auto-open).
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = itemsByDownload[ObjectIdentifier(download)] else { return }
        item.markState(.failed)
        downloadLog("failed \(item.filename) — \(error.localizedDescription)")
        moveToFinished(item)
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
