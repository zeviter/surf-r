import SwiftUI
import AppKit
import Combine

// MARK: - Reusable favicon

/// First-party favicon for `host` with the shared letter-tile fallback, loaded via
/// `FaviconService` (cache → async fetch) and live-swapped when one resolves. Reused
/// by the history page rows and (next slice) the trusted-sites page.
struct FaviconView: View {
    let host: String
    var size: CGFloat = 16
    var cornerRadius: CGFloat = 3

    @State private var iconData: Data?

    var body: some View {
        Group {
            if let data = iconData ?? FaviconService.shared.cachedFaviconData(forHost: host),
               let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    FaviconTile.letterColor(for: host)
                    Text(FaviconTile.letter(for: host))
                        .font(.system(size: size * 0.5, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: host) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .faviconUpdated).receive(on: RunLoop.main)) { note in
            guard (note.userInfo?["host"] as? String)?.lowercased() == host.lowercased() else { return }
            if let data = FaviconService.shared.cachedFaviconData(forHost: host) { iconData = data }
        }
    }

    private func load() async {
        if let cached = FaviconService.shared.cachedFaviconData(forHost: host) {
            iconData = cached
            return
        }
        iconData = await FaviconService.shared.favicon(forHost: host)
    }
}

// MARK: - Reusable row

/// A reusable list row: favicon · primary line · optional secondary line · optional
/// trailing meta · optional trailing action (e.g. ✕). When the host is trusted
/// (`TrustStore.isTrusted`), the row gets a green accent + the trusted badge,
/// consistent with the rail/bookmark tile badge. Tapping anywhere but the trailing
/// action calls `onOpen`.
struct PageRow<Trailing: View>: View {
    let host: String
    let primary: String
    let secondary: String?
    let trailingMeta: String?
    /// When set, render this SF Symbol glyph as the leading icon instead of the favicon — for non-host
    /// rows (typed-vault notes/addresses/payment), which have no first-party favicon.
    let leadingSystemImage: String?
    let onOpen: () -> Void
    /// Trailing controls (e.g. a delete ✕, or Open + untrust). Caller-supplied so
    /// the same row serves pages with different actions.
    @ViewBuilder let trailing: () -> Trailing

    init(host: String,
         primary: String,
         secondary: String? = nil,
         trailingMeta: String? = nil,
         leadingSystemImage: String? = nil,
         onOpen: @escaping () -> Void,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.host = host
        self.primary = primary
        self.secondary = secondary
        self.trailingMeta = trailingMeta
        self.leadingSystemImage = leadingSystemImage
        self.onOpen = onOpen
        self.trailing = trailing
    }

    @ObservedObject private var trustStore = TrustStore.shared
    private var trusted: Bool { leadingSystemImage == nil && trustStore.isTrusted(host: host) }
    @State private var hovering = false

    @ViewBuilder private var leading: some View {
        if let glyph = leadingSystemImage {
            Image(systemName: glyph)
                .font(.system(size: 15)).foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
        } else {
            FaviconView(host: host, size: 28, cornerRadius: 6)
                .overlay(alignment: .topTrailing) {
                    if trusted { TrustedBadge().offset(x: 4, y: -4) }
                }
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            // The whole favicon + text + meta region is one full-width/height tap target — clicking
            // anywhere on the row opens it (the trailing controls stay separate).
            HStack(spacing: 10) {
                leading
                VStack(alignment: .leading, spacing: 2) {
                    Text(primary.isEmpty ? host : primary).lineLimit(1)
                    if let secondary, !secondary.isEmpty {
                        Text(secondary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let trailingMeta {
                    Text(trailingMeta).font(.caption).foregroundStyle(.secondary).fixedSize()
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)

            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(trusted ? Color.green.opacity(0.08)
                              : (hovering ? Color.primary.opacity(0.06) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(trusted ? Color.green.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .onHover { hovering = $0 }
    }
}

// MARK: - Grouped list scaffold

/// One titled section of rows.
struct PageSection<Item: Identifiable>: Identifiable {
    let id: String
    let title: String
    let items: [Item]
}

/// A reusable search-and-filter page: a header (title + actions), a live search
/// field, and a scrollable list of sections with pinned headers — plus empty and
/// no-results states. The history page builds on this; the trusted-sites page
/// (next slice) reuses the same scaffold with its own rows/actions.
struct SearchFilterPage<Item: Identifiable, Row: View, Actions: View>: View {
    let title: String
    @Binding var query: String
    let searchPrompt: String
    let sections: [PageSection<Item>]
    let emptyMessage: String
    /// Optional one-line hint shown under `emptyMessage` only in the true-empty
    /// state (not for "no results"). e.g. the ⌘⇧T hint on the trusted-sites page.
    let emptyHint: String?
    let noResultsMessage: String
    /// Bump to grab first-responder on the search field (e.g. ⌘F). Default 0 = no auto-focus.
    let searchFocusToken: Int
    /// Optional accessory rendered **between the title row and the search field** (e.g. the typed-vault
    /// segmented control). `nil` for the plain pages (history/trusted/downloads).
    let headerAccessory: AnyView?
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let row: (Item) -> Row

    @FocusState private var searchFocused: Bool

    init(title: String,
         query: Binding<String>,
         searchPrompt: String = "Search",
         sections: [PageSection<Item>],
         emptyMessage: String,
         emptyHint: String? = nil,
         noResultsMessage: String = "No results",
         searchFocusToken: Int = 0,
         headerAccessory: AnyView? = nil,
         @ViewBuilder actions: @escaping () -> Actions,
         @ViewBuilder row: @escaping (Item) -> Row) {
        self.title = title
        self._query = query
        self.searchPrompt = searchPrompt
        self.sections = sections
        self.emptyMessage = emptyMessage
        self.emptyHint = emptyHint
        self.noResultsMessage = noResultsMessage
        self.searchFocusToken = searchFocusToken
        self.headerAccessory = headerAccessory
        self.actions = actions
        self.row = row
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title).font(.title2).bold()
                Spacer()
                actions()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            if let headerAccessory {
                headerAccessory
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(searchPrompt, text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onChange(of: searchFocusToken) { _, _ in searchFocused = true }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.gray.opacity(0.25)))
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider()

            if sections.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Text(query.isEmpty ? emptyMessage : noResultsMessage)
                        .foregroundStyle(.secondary)
                    if query.isEmpty, let emptyHint {
                        Text(emptyHint)
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.items) { row($0) }
                            } header: {
                                Text(section.title)
                                    .font(.caption).bold()
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(.regularMaterial)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
