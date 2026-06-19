import SwiftUI

/// Renders a `KeyCombo` as individual key caps (⌘ ⇧ R …). Everything here reads the
/// registry's effective bindings, so the UI can never drift from the real shortcuts.
struct KeyCapsView: View {
    let combo: KeyCombo

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .frame(minWidth: 16)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.15)))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.gray.opacity(0.30)))
            }
        }
    }

    /// One cap per modifier (canonical order) then the key.
    private var caps: [String] {
        var result: [String] = []
        let m = combo.modifiers
        if m.contains(.control) { result.append("⌃") }
        if m.contains(.option)  { result.append("⌥") }
        if m.contains(.shift)   { result.append("⇧") }
        if m.contains(.command) { result.append("⌘") }
        result.append(combo.key.uppercased())
        return result
    }
}

/// The rail shortcuts popover: a compact cheatsheet of the most-used shortcuts plus
/// a "See all shortcuts" button. Same pattern as the downloads popover.
struct ShortcutsCheatsheet: View {
    let onSeeAll: () -> Void

    @ObservedObject private var registry = ShortcutRegistry.shared

    /// Curated "most-used" set, rendered from the registry's effective bindings.
    private let featured: [ShortcutID] = [.openLocation, .newTab, .reload, .history, .trustSite, .back, .forward]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shortcuts").font(.headline)
            Divider()
            VStack(spacing: 6) {
                ForEach(featured, id: \.self) { id in
                    let def = registry.definition(for: id)
                    HStack(spacing: 10) {
                        Text(def.name).lineLimit(1)
                        Spacer(minLength: 12)
                        KeyCapsView(combo: registry.binding(for: id))
                    }
                }
            }
            Divider()
            Button(action: onSeeAll) {
                HStack {
                    Text("See all shortcuts")
                    Spacer()
                    Image(systemName: "arrow.up.forward.square")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
        .padding(12)
        .frame(width: 280)
    }
}

/// One row on the full shortcuts page: a neutral category glyph, the action name,
/// and its key combo as caps. No favicon (not a site) — view-only (editing is 9b2).
struct ShortcutRow: View {
    let definition: ShortcutDefinition
    let combo: KeyCombo

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Self.glyph(for: definition.category))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.10)))

            Text(definition.name)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)

            KeyCapsView(combo: combo)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private static func glyph(for category: ShortcutCategory) -> String {
        switch category {
        case .tabs:       return "rectangle.stack"
        case .navigation: return "arrow.left.arrow.right"
        case .page:       return "doc"
        case .surfaces:   return "square.grid.2x2"
        }
    }
}

/// The full Keyboard Shortcuts page (slice 9b), rendered as an internal tab via the
/// shared `SearchFilterPage`. All registry entries grouped by category, searchable
/// by action name or key combo. View-only — remapping is deferred (9b2).
struct ShortcutsPage: View {
    @ObservedObject private var registry = ShortcutRegistry.shared
    @State private var query = ""

    private static let categoryOrder: [ShortcutCategory] = [.tabs, .navigation, .page, .surfaces]

    private var sections: [PageSection<ShortcutDefinition>] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Self.categoryOrder.compactMap { category in
            let items = registry.definitions.filter { $0.category == category }.filter { def in
                guard !q.isEmpty else { return true }
                // Filter by action name OR the rendered key combo (e.g. "⌘t", "t").
                return def.name.lowercased().contains(q)
                    || registry.binding(for: def.id).display.lowercased().contains(q)
            }
            return items.isEmpty ? nil : PageSection(id: category.rawValue, title: category.rawValue, items: items)
        }
    }

    var body: some View {
        SearchFilterPage(
            title: "Keyboard Shortcuts",
            query: $query,
            searchPrompt: "Search shortcuts",
            sections: sections,
            emptyMessage: "No shortcuts",
            noResultsMessage: "No results",
            actions: { EmptyView() },
            row: { def in
                ShortcutRow(definition: def, combo: registry.binding(for: def.id))
            }
        )
    }
}
