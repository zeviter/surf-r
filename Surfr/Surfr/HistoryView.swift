import SwiftUI
import Combine

/// Backs the full-page history view: holds the current query + fetched entries
/// (newest first), groups them by day, and applies deletes. All DB work is async
/// (off-main via the store); the page renders instantly and fills in.
@MainActor
final class HistoryPageModel: ObservableObject {
    @Published var query = ""
    /// Flat, newest-first entries for the current query (or all recent).
    @Published private(set) var entries: [HistoryEntry] = []

    /// Generous cap for a local history page.
    private let fetchLimit = 1000

    /// Day-grouped sections (Today, Yesterday, then dates), newest first.
    var sections: [PageSection<HistoryEntry>] { Self.group(entries) }

    /// (Re)load for the current query. Debounced by the caller's `.task(id:)`, which
    /// cancels the prior load when the query changes — so the last write wins.
    func reload() async {
        // Small debounce so fast typing doesn't hammer the DB; cancellation aborts.
        try? await Task.sleep(nanoseconds: 150_000_000)
        if Task.isCancelled { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let results = trimmed.isEmpty
            ? await HistoryStore.shared.recent(limit: fetchLimit)
            : await HistoryStore.shared.search(query: trimmed, limit: fetchLimit)
        if Task.isCancelled { return }
        entries = results
    }

    func delete(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }   // live update
        guard let id = entry.id else { return }
        Task { await HistoryStore.shared.delete(id: id) }
    }

    func clearAll() {
        entries = []
        Task { await HistoryStore.shared.clear() }
    }

    /// Clear entries visited within the last `seconds` (e.g. last hour / 24h).
    func clear(lastSeconds seconds: TimeInterval) {
        let cutoff = Date().addingTimeInterval(-seconds)
        entries.removeAll { $0.lastVisited >= cutoff }
        Task { await HistoryStore.shared.deleteVisited(since: cutoff) }
    }

    // MARK: - Grouping

    private static func group(_ entries: [HistoryEntry]) -> [PageSection<HistoryEntry>] {
        let cal = Calendar.current
        var order: [Date] = []
        var byDay: [Date: [HistoryEntry]] = [:]
        for entry in entries {
            let day = cal.startOfDay(for: entry.lastVisited)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(entry)
        }
        return order.map { day in
            PageSection(id: "\(day.timeIntervalSince1970)",
                        title: dayTitle(day, cal),
                        items: byDay[day] ?? [])
        }
    }

    private static func dayTitle(_ day: Date, _ cal: Calendar) -> String {
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return dateFormatter.string(from: day)
    }

    static func meta(for entry: HistoryEntry) -> String {
        let time = timeFormatter.string(from: entry.lastVisited)
        let visits = "\(entry.visitCount) visit\(entry.visitCount == 1 ? "" : "s")"
        return "\(time) · \(visits)"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d, yyyy"
        return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}

/// The full-page history view (ui-wireframes §7), rendered as an internal tab.
/// Live search, day-grouped, newest first; rows open in a new tab; per-row delete;
/// header clear-all + clear-recent menu. Built on the reusable `SearchFilterPage`.
struct HistoryPage: View {
    /// Open a history entry — always in a NEW tab (never replaces the history tab).
    let onOpenURL: (URL) -> Void

    @StateObject private var model = HistoryPageModel()

    var body: some View {
        SearchFilterPage(
            title: "History",
            query: $model.query,
            searchPrompt: "Search history",
            sections: model.sections,
            emptyMessage: "No history",
            noResultsMessage: "No results",
            actions: {
                Menu {
                    Button("Clear Last Hour") { model.clear(lastSeconds: 3600) }
                    Button("Clear Last 24 Hours") { model.clear(lastSeconds: 24 * 3600) }
                } label: {
                    Label("Clear Recent", systemImage: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button(role: .destructive) { model.clearAll() } label: {
                    Text("Clear All History")
                }
            },
            row: { entry in
                PageRow(
                    host: entry.host,
                    primary: entry.title,
                    secondary: entry.url,
                    trailingMeta: HistoryPageModel.meta(for: entry),
                    onOpen: { if let url = URL(string: entry.url) { onOpenURL(url) } }
                ) {
                    Button { model.delete(entry) } label: {
                        Image(systemName: "xmark").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Delete from history")
                }
            }
        )
        // Live search: re-runs whenever the query changes (cancelling the prior load).
        .task(id: model.query) { await model.reload() }
    }
}
