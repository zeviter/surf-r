import SwiftUI
import AppKit
import Combine

// MARK: - Suggestions

enum SuggestionSource {
    case history, bookmark, search
    var icon: String {
        switch self {
        case .history: return "clock"
        case .bookmark: return "star"
        case .search: return "magnifyingglass"
        }
    }
}

struct Suggestion: Identifiable {
    let id = UUID()
    let source: SuggestionSource
    let title: String
    let subtitle: String
    let url: URL
}

// MARK: - Shared omnibox component (used by both contexts)

/// The spotlight omnibox: an input field plus a live suggestion list. Reused by
/// the summoned overlay (Context A) and the new-tab permanent box (Context B);
/// the two differ only in the wrapper around this component. Parsing reuses the
/// existing `Omnibox` (URL vs DuckDuckGo search).
struct SpotlightOmnibox: View {
    @Binding var text: String
    let large: Bool
    /// Navigate to a target — `newTab == true` means ⌘Enter (open in a new tab).
    let onNavigate: (URL, Bool) -> Void
    /// Esc handler; `nil` means not dismissable (Context B never dismisses).
    let onEscape: (() -> Void)?
    /// Bump to focus + select-all the field (⌘L); also focuses on first appearance.
    let focusToken: Int

    @State private var suggestions: [Suggestion] = []
    @State private var highlight = -1   // -1 = the typed text itself; 0… = a suggestion

    var body: some View {
        VStack(spacing: 0) {
            OmniboxField(
                text: $text,
                placeholder: "Search DuckDuckGo or enter address",
                large: large,
                focusToken: focusToken,
                onMoveUp: { move(-1) },
                onMoveDown: { move(1) },
                onSubmit: { submit(newTab: false) },   // plain Return → current tab
                onCancel: { onEscape?() }
            )
            .padding(large ? 14 : 10)

            if !suggestions.isEmpty {
                Divider()
                VStack(spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        SuggestionRow(suggestion: suggestion, highlighted: index == highlight)
                            .contentShape(Rectangle())
                            .onTapGesture { onNavigate(suggestion.url, false) }
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .background {
            // ⌘Return is detected as a key-equivalent (deterministic), independent of
            // the field's key handling, so it always opens a new foreground tab —
            // including when a suggestion row is highlighted.
            Button(action: { submit(newTab: true) }) { EmptyView() }
                .keyboardShortcut(.return, modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .task(id: text) {
            highlight = -1
            suggestions = await Self.loadSuggestions(for: text)
        }
    }

    private func move(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        highlight = max(-1, min(suggestions.count - 1, highlight + delta))
    }

    private func submit(newTab: Bool) {
        if highlight >= 0, highlight < suggestions.count {
            onNavigate(suggestions[highlight].url, newTab)
        } else if let url = Omnibox.resolve(Self.collapse(text)) {
            onNavigate(url, newTab)
        }
    }

    /// Trim + collapse whitespace/newlines so a pasted URL with a trailing newline
    /// still parses as a URL.
    static func collapse(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Build ranked suggestions. With no query: most-recent history, recency order.
    /// With a query: blend history + bookmarks by `rankScore` (match quality + visit
    /// frequency + a bookmark boost), keep the recent-history → bookmarks ordering as
    /// the tie-break, dedupe by URL, cap at 7, then append the DuckDuckGo search row
    /// last. Total capped at 8.
    static func loadSuggestions(for raw: String) async -> [Suggestion] {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if query.isEmpty {
            var out: [Suggestion] = []
            var seen = Set<String>()
            for h in await HistoryStore.shared.recent(limit: 8) {
                guard let u = URL(string: h.url), seen.insert(u.absoluteString).inserted else { continue }
                out.append(Suggestion(source: .history, title: h.title, subtitle: h.url, url: u))
            }
            return Array(out.prefix(8))
        }

        // Score a pool of candidates. `order` preserves source/recency order so
        // equal scores fall back to "recent history before bookmarks".
        struct Scored { let suggestion: Suggestion; let score: Int; let order: Int }
        var scored: [Scored] = []
        var order = 0
        let q = query.lowercased()

        for h in await HistoryStore.shared.search(query: query, limit: 10) {
            guard let u = URL(string: h.url) else { continue }
            let s = rankScore(title: h.title, urlString: h.url, host: u.host,
                              visitCount: h.visitCount, isBookmark: false, query: q)
            scored.append(Scored(suggestion: Suggestion(source: .history, title: h.title, subtitle: h.url, url: u),
                                 score: s, order: order)); order += 1
        }
        for b in await BookmarkStore.shared.search(query: query) {
            guard let u = URL(string: b.url) else { continue }
            let s = rankScore(title: b.title, urlString: b.url, host: u.host,
                              visitCount: 0, isBookmark: true, query: q)
            scored.append(Scored(suggestion: Suggestion(source: .bookmark, title: b.title, subtitle: b.url, url: u),
                                 score: s, order: order)); order += 1
        }

        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }

        // Dedupe by URL (keep the highest-scored occurrence), cap at 7.
        var seen = Set<String>()
        var result: [Suggestion] = []
        for item in scored {
            guard seen.insert(item.suggestion.url.absoluteString).inserted else { continue }
            result.append(item.suggestion)
            if result.count == 7 { break }
        }

        if let searchURL = Omnibox.searchURL(for: collapse(raw)) {
            result.append(Suggestion(source: .search,
                                     title: "Search DuckDuckGo for “\(query)”",
                                     subtitle: "", url: searchURL))
        }
        return Array(result.prefix(8))
    }

    /// Relevance score for a candidate (higher = better). Predictable blend:
    ///  • match quality — exact/`www.` host (120), host prefix (100), title prefix
    ///    (80), host contains (50), title contains (30), URL contains (10);
    ///  • visit frequency — `min(visitCount, 20) * 2` (0…40), so often-visited pages
    ///    rise;
    ///  • bookmark boost — +25, so a saved page outranks an equally-matching plain
    ///    history hit.
    static func rankScore(title: String, urlString: String, host: String?,
                          visitCount: Int, isBookmark: Bool, query q: String) -> Int {
        let t = title.lowercased()
        let h = (host ?? "").lowercased()
        let u = urlString.lowercased()
        var s = 0
        if h == q || h == "www.\(q)" { s += 120 }
        else if h.hasPrefix(q) { s += 100 }
        else if t.hasPrefix(q) { s += 80 }
        else if h.contains(q) { s += 50 }
        else if t.contains(q) { s += 30 }
        else if u.contains(q) { s += 10 }
        s += min(visitCount, 20) * 2
        if isBookmark { s += 25 }
        return s
    }
}

struct SuggestionRow: View {
    let suggestion: Suggestion
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: suggestion.source.icon)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.title.isEmpty ? suggestion.subtitle : suggestion.title)
                    .lineLimit(1)
                if !suggestion.subtitle.isEmpty, suggestion.source != .search {
                    Text(suggestion.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(highlighted ? Color.accentColor.opacity(0.18) : Color.clear)
    }
}

// MARK: - NSTextField-backed field (reliable select-all + key handling)

/// `NSTextField` wrapper so we get real select-all (auto-highlight), arrow-key
/// suggestion movement, Enter vs ⌘Enter, and Esc — none of which SwiftUI's
/// `TextField` exposes cleanly on macOS.
struct OmniboxField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let large: Bool
    let focusToken: Int
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onSubmit: () -> Void        // plain Return (⌘Return is a key-equivalent)
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.font = .systemFont(ofSize: large ? 20 : 13)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            context.coordinator.beginFocus(field)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OmniboxField
        var lastFocusToken = Int.min

        init(_ parent: OmniboxField) { self.parent = parent }

        /// Deterministically focus + select-all. The field may not yet be in its
        /// window (or the window not yet key) when the overlay first presents, so
        /// `makeFirstResponder` can silently fail. Instead of firing once and
        /// hoping, confirm it took (the field editor exists) and retry on the next
        /// runloop tick until it does.
        func beginFocus(_ field: NSTextField) { focus(field, attempt: 0) }

        private func focus(_ field: NSTextField, attempt: Int) {
            if let window = field.window, window.makeFirstResponder(field), field.currentEditor() != nil {
                field.selectText(nil)   // auto-highlight: typing replaces
                return
            }
            guard attempt < 30 else { return }
            DispatchQueue.main.async { [weak field] in
                guard let field else { return }
                self.focus(field, attempt: attempt + 1)
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveUp(); return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveDown(); return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit(); return true   // ⌘Return handled by the key-equivalent
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel(); return true
            default:
                return false
            }
        }
    }
}

// MARK: - Context A: summoned overlay (on a loaded page)

/// Centered floating panel over a dimmed page; Esc / click-outside dismiss.
struct SpotlightOverlay: View {
    /// Increments on every ⌘L summon so focus + select-all re-fires each time,
    /// even if SwiftUI reuses the field's coordinator across summons.
    let focusToken: Int
    let onNavigate: (URL, Bool) -> Void
    let onClose: () -> Void

    @State private var text: String

    /// `initialText` is the current URL on a loaded page (pre-filled, auto-selected)
    /// and "" on internal pages (history/trusted/etc.) where there's no URL.
    init(initialText: String, focusToken: Int, onNavigate: @escaping (URL, Bool) -> Void, onClose: @escaping () -> Void) {
        self.focusToken = focusToken
        self.onNavigate = onNavigate
        self.onClose = onClose
        _text = State(initialValue: initialText)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture { onClose() }   // click-outside

            SpotlightOmnibox(
                text: $text,
                large: false,
                onNavigate: { url, newTab in onNavigate(url, newTab); onClose() },
                onEscape: onClose,
                focusToken: focusToken
            )
            .frame(width: 600)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.gray.opacity(0.25)))
            .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

// MARK: - Context B: permanent box (new-tab page)

/// The new-tab page: a large, always-visible omnibox box near the top, with empty
/// space below (the bookmarks grid is slice 6). Not dismissable. The box is bound
/// to the tab's `addressText`, so typed-but-uncommitted text keeps the tab alive
/// (pristine rule) and is preserved.
struct NewTabPage: View {
    @ObservedObject var tab: Tab
    /// Live bookmark records for the grid (slice 6); empty → nothing below the box.
    @ObservedObject private var bookmarkState = BookmarkState.shared
    let onNavigate: (URL, Bool) -> Void
    let focusToken: Int

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 90)
            SpotlightOmnibox(
                text: $tab.addressText,
                large: true,
                onNavigate: onNavigate,
                onEscape: nil,            // permanent — no Esc/click-away
                focusToken: focusToken
            )
            .frame(width: 620)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.gray.opacity(0.2)))
            .shadow(color: .black.opacity(0.1), radius: 12, y: 4)

            // §6: bookmarks grid below the box. Empty → just the box (no grid,
            // no placeholder), so keep the box near the top with a plain Spacer.
            if bookmarkState.bookmarks.isEmpty {
                Spacer()
            } else {
                BookmarksGrid(bookmarks: bookmarkState.bookmarks, onOpen: onNavigate)
                    .padding(.top, 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// The new-tab bookmarks grid (§6): responsive favicon + label tiles below the
/// omnibox box. Pure render of the supplied records; `NewTabPage` owns liveness.
struct BookmarksGrid: View {
    let bookmarks: [Bookmark]
    /// `(url, newTab)` — same closure the omnibox uses; ⌘-click opens in a new tab.
    let onOpen: (URL, Bool) -> Void

    private let columns = [GridItem(.adaptive(minimum: 92, maximum: 120), spacing: 18)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .center, spacing: 18) {
                ForEach(bookmarks) { bookmark in
                    BookmarkTile(bookmark: bookmark, onOpen: onOpen)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)   // center the grid in the content area
        }
        .frame(maxHeight: .infinity)
    }
}

/// One bookmark tile: favicon (FaviconService, letter-tile fallback like the rail)
/// + title/host label. Click navigates the current tab; ⌘-click opens a new tab;
/// right-click → "Remove bookmark". Loads/swaps its favicon like `FaviconTile`.
struct BookmarkTile: View {
    let bookmark: Bookmark
    let onOpen: (URL, Bool) -> Void

    @State private var iconData: Data?
    /// Observe trust so the badge appears/disappears live on trust/untrust.
    @ObservedObject private var trustStore = TrustStore.shared

    private var label: String { bookmark.title.isEmpty ? bookmark.host : bookmark.title }

    var body: some View {
        Button(action: open) {
            VStack(spacing: 6) {
                iconContent
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    // Trusted check in the top-right corner, inset inside the icon so
                    // it isn't clipped — matches the rail tile's badge placement.
                    .overlay(alignment: .topTrailing) {
                        if trustStore.isTrusted(host: bookmark.host) {
                            TrustedBadge().offset(x: -2, y: 2)
                        }
                    }
                Text(label)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: 92)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .contextMenu {
            Button("Remove bookmark", role: .destructive) {
                Task { await BookmarkState.shared.remove(bookmark) }
            }
        }
        .task(id: bookmark.host) { await loadIcon() }
        .onReceive(NotificationCenter.default.publisher(for: .faviconUpdated).receive(on: RunLoop.main)) { note in
            // A favicon was cached after this tile rendered — swap it in, this tile only.
            guard (note.userInfo?["host"] as? String)?.lowercased() == bookmark.host.lowercased() else { return }
            if let data = FaviconService.shared.cachedFaviconData(forHost: bookmark.host) {
                iconData = data
            }
        }
    }

    /// Real favicon if we have usable bytes, else the shared letter-tile fallback.
    @ViewBuilder private var iconContent: some View {
        if let data = iconData ?? FaviconService.shared.cachedFaviconData(forHost: bookmark.host),
           let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                FaviconTile.letterColor(for: bookmark.host)
                Text(FaviconTile.letter(for: bookmark.host))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    private func loadIcon() async {
        if let cached = FaviconService.shared.cachedFaviconData(forHost: bookmark.host) {
            iconData = cached
            return
        }
        iconData = await FaviconService.shared.favicon(forHost: bookmark.host)
    }

    /// Click → current tab; ⌘-click → new tab (matches the omnibox ⌘Enter convention).
    private func open() {
        guard let url = URL(string: bookmark.url) else { return }
        let commandHeld = NSEvent.modifierFlags.contains(.command)
        onOpen(url, commandHeld)
    }
}
