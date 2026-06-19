import SwiftUI
import AppKit

/// The blue/white count badge used on rail tiles (favicon tab counts and the
/// downloads in-progress count). Caller positions it (e.g. `.offset`).
struct CountBadge: View {
    let count: Int
    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.blue))
    }
}

/// The pinned rail downloads control. Three visual states, in priority order:
///   1. Active — ≥1 in-progress download: a progress ring (determinate when every
///      active download has a known size, else an indeterminate spinner) plus the
///      in-progress count badge.
///   2. Completed-unacknowledged — a download finished and the popover hasn't been
///      opened since: the glyph is tinted green.
///   3. Idle — plain glyph.
/// Tapping opens the popover (which acknowledges completions → reverts from green).
struct DownloadsRailIcon: View {
    @ObservedObject private var downloads = DownloadManager.shared
    /// 9a active-state: true when the downloads page is the active tab.
    var isActive: Bool = false
    let onTap: () -> Void

    private static let glyphSize: CGFloat = 16
    private static let ringSize: CGFloat = 26

    /// Aggregate fraction across active downloads, or nil when any size is unknown
    /// (→ indeterminate) or nothing is active.
    private var aggregateFraction: Double? {
        let active = downloads.active
        guard !active.isEmpty, active.allSatisfy({ $0.totalBytes > 0 }) else { return nil }
        let total = active.reduce(Int64(0)) { $0 + $1.totalBytes }
        let received = active.reduce(Int64(0)) { $0 + $1.receivedBytes }
        guard total > 0 else { return nil }
        return min(1, Double(received) / Double(total))
    }

    /// The icon BODY is green only for the 9a active-page state — never for download
    /// completion (that's the ring's job). Idle/in-progress/completed bodies are plain.
    private var glyphColor: Color { isActive ? .green : .primary }

    /// The ring conveys download STATUS, independent of the body colour:
    /// downloading → blue fill (determinate, else spinner); completed-unacknowledged
    /// → full green ring; idle → no ring.
    @ViewBuilder private var statusRing: some View {
        if !downloads.active.isEmpty {
            if let fraction = aggregateFraction {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: Self.ringSize, height: Self.ringSize)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: Self.ringSize, height: Self.ringSize)
            }
        } else if downloads.hasUnacknowledgedCompletion {
            // Completed: full green ring until the popover is opened (acknowledged).
            Circle()
                .stroke(Color.green, style: StrokeStyle(lineWidth: 2))
                .frame(width: Self.ringSize, height: Self.ringSize)
        }
        // Idle: no ring.
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                statusRing
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: Self.glyphSize))
                    .foregroundStyle(glyphColor)
            }
            .frame(width: 32, height: 28)

            if !downloads.active.isEmpty {
                CountBadge(count: downloads.active.count).offset(x: 4, y: 4)
            }
        }
        .frame(width: 40, height: 32)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .help("Downloads")
    }
}

/// The downloads manager popover (slice 2b): header + "Clear all", a newest-first
/// list of rows, and an empty state. Renders the in-memory `DownloadManager` live.
struct DownloadsPopover: View {
    /// Opens the full downloads page (slice 9c).
    let onSeeAll: () -> Void

    @ObservedObject private var downloads = DownloadManager.shared

    /// Newest on top: in-progress (most recent first) above finished (already
    /// stored most-recent-first).
    private var rows: [DownloadItem] {
        Array(downloads.active.reversed()) + downloads.finished
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: title + Clear all (top-right, accent text with a trash icon).
            HStack(spacing: 10) {
                Text("Downloads").font(.headline)
                Spacer()
                Button { downloads.clearFinished() } label: {
                    Label("Clear all", systemImage: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(downloads.finished.isEmpty)
            }
            Divider()
            if rows.isEmpty {
                Text("No downloads.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(rows) { DownloadRow(item: $0) }
                    }
                }
                .frame(maxHeight: 320)
            }
            // Footer: full-width "See all downloads" row, mirroring the shortcuts popover.
            Divider()
            Button(action: onSeeAll) {
                HStack {
                    Text("See all downloads")
                    Spacer()
                    Image(systemName: "arrow.up.forward.square")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
        .padding(10)
        .frame(width: 320)
    }
}

/// One download row: filename, source host, contextual state line, and a ✕ that
/// cancels (in-progress) or removes from the list (finished). Clicking a completed
/// row reveals the file in Finder. Observes its item so it updates live.
struct DownloadRow: View {
    @ObservedObject var item: DownloadItem

    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private var hostText: String { item.sourceURL?.host ?? "" }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename).lineLimit(1)
                if !hostText.isEmpty {
                    Text(hostText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                stateLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: revealIfCompleted)

            Button(action: closeAction) {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
            .help(item.state == .inProgress ? "Cancel download" : "Remove from list")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder private var stateLine: some View {
        switch item.state {
        case .inProgress:
            if item.totalBytes > 0 {
                ProgressView(value: Double(item.receivedBytes), total: Double(item.totalBytes))
                    .controlSize(.small)
                Text("\(bytes(item.receivedBytes)) / \(bytes(item.totalBytes))")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
                Text("\(bytes(item.receivedBytes)) received")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        case .completed:
            if item.fileIsMissing {
                Text("Unavailable — file moved or deleted")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                let size = item.totalBytes > 0 ? item.totalBytes : item.receivedBytes
                Text(size > 0 ? "Completed · \(bytes(size))" : "Completed")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        case .failed:
            Text("Failed").font(.caption2).foregroundStyle(.red)
        case .cancelled:
            Text("Cancelled").font(.caption2).foregroundStyle(.secondary)
        case .interrupted:
            Text("Interrupted").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func bytes(_ count: Int64) -> String { Self.formatter.string(fromByteCount: count) }

    /// ✕ is contextual: cancel while running, otherwise remove from the list.
    private func closeAction() {
        if item.state == .inProgress {
            item.cancel()
        } else {
            DownloadManager.shared.remove(item)
        }
    }

    /// Reveal a finished file in Finder (no-op unless completed AND still present).
    private func revealIfCompleted() {
        guard item.state == .completed, !item.fileIsMissing, let url = item.destinationURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// The full Downloads page (slice 9c), rendered as an internal tab via the shared
/// `SearchFilterPage` — consistent with history/trusted/shortcuts. Reuses
/// `DownloadRow` (progress/state, contextual ✕, reveal-in-Finder), grouped into
/// In Progress / Finished, searchable by filename or host. Still in-memory.
struct DownloadsPage: View {
    @ObservedObject private var downloads = DownloadManager.shared
    @State private var query = ""

    private func matches(_ item: DownloadItem, _ q: String) -> Bool {
        guard !q.isEmpty else { return true }
        return item.filename.lowercased().contains(q)
            || (item.sourceURL?.host?.lowercased().contains(q) ?? false)
    }

    private var sections: [PageSection<DownloadItem>] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let active = Array(downloads.active.reversed()).filter { matches($0, q) }   // newest first
        let finished = downloads.finished.filter { matches($0, q) }                 // already newest first
        var result: [PageSection<DownloadItem>] = []
        if !active.isEmpty { result.append(PageSection(id: "active", title: "In Progress", items: active)) }
        if !finished.isEmpty { result.append(PageSection(id: "finished", title: "Finished", items: finished)) }
        return result
    }

    var body: some View {
        SearchFilterPage(
            title: "Downloads",
            query: $query,
            searchPrompt: "Search downloads",
            sections: sections,
            emptyMessage: "No downloads",
            noResultsMessage: "No results",
            actions: {
                Button("Clear all") { downloads.clearFinished() }
                    .foregroundStyle(.secondary)
                    .disabled(downloads.finished.isEmpty)
            },
            row: { DownloadRow(item: $0) }
        )
    }
}
