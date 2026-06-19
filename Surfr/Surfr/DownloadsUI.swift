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

    private var glyphColor: Color {
        if !downloads.active.isEmpty { return .primary }           // active
        if downloads.hasUnacknowledgedCompletion { return .green } // completed
        return .primary                                             // idle
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                if !downloads.active.isEmpty {
                    if let fraction = aggregateFraction {
                        // Determinate ring of aggregate progress.
                        Circle()
                            .trim(from: 0, to: fraction)
                            .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: Self.ringSize, height: Self.ringSize)
                    } else {
                        // Indeterminate: at least one active download's size is unknown.
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: Self.ringSize, height: Self.ringSize)
                    }
                }
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
    @ObservedObject private var downloads = DownloadManager.shared

    /// Newest on top: in-progress (most recent first) above finished (already
    /// stored most-recent-first).
    private var rows: [DownloadItem] {
        Array(downloads.active.reversed()) + downloads.finished
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                Button("Clear all") { downloads.clearFinished() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
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
            let size = item.totalBytes > 0 ? item.totalBytes : item.receivedBytes
            Text(size > 0 ? "Completed · \(bytes(size))" : "Completed")
                .font(.caption2).foregroundStyle(.secondary)
        case .failed:
            Text("Failed").font(.caption2).foregroundStyle(.red)
        case .cancelled:
            Text("Cancelled").font(.caption2).foregroundStyle(.secondary)
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

    /// Reveal a finished file in Finder (no-op for other states / unknown path).
    private func revealIfCompleted() {
        guard item.state == .completed, let url = item.destinationURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
