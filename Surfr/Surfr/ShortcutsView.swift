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

    /// One cap per modifier (canonical order) then the key glyph (arrows/return/etc.
    /// render as symbols via `keyLabel`, not the raw control character).
    private var caps: [String] {
        var result: [String] = []
        let m = combo.modifiers
        if m.contains(.control) { result.append("⌃") }
        if m.contains(.option)  { result.append("⌥") }
        if m.contains(.shift)   { result.append("⇧") }
        if m.contains(.command) { result.append("⌘") }
        result.append(combo.keyLabel)
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

/// A focused NSView that records the next key combo (9b2). It becomes first
/// responder and converts the key-down (or key-equivalent, so combos like ⌘L are
/// caught before the menu) into a `KeyCombo`. Esc cancels.
struct ShortcutCaptureField: NSViewRepresentable {
    let onCapture: (KeyCombo) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> CaptureView { CaptureView() }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.onCapture = onCapture
        view.onCancel = onCancel
        // Grab focus so keystrokes land here while recording.
        DispatchQueue.main.async {
            if view.window?.firstResponder !== view { view.window?.makeFirstResponder(view) }
        }
    }

    final class CaptureView: NSView {
        var onCapture: ((KeyCombo) -> Void)?
        var onCancel: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) { handle(event) }
        // Catch combos that are menu key-equivalents (e.g. ⌘L) before the menu does.
        override func performKeyEquivalent(with event: NSEvent) -> Bool { handle(event) }

        @discardableResult private func handle(_ event: NSEvent) -> Bool {
            if event.keyCode == 53 { onCancel?(); return true }   // Esc
            guard let combo = Self.combo(from: event) else { return false }
            onCapture?(combo)
            return true
        }

        /// Build a combo from an event: modifiers + the base character (ignoring
        /// modifiers, so ⇧Y → "y" with a shift flag). Lowercased to match the
        /// registry's key convention.
        static func combo(from event: NSEvent) -> KeyCombo? {
            var mods: ShortcutModifiers = []
            let f = event.modifierFlags
            if f.contains(.command) { mods.insert(.command) }
            if f.contains(.shift)   { mods.insert(.shift) }
            if f.contains(.option)  { mods.insert(.option) }
            if f.contains(.control) { mods.insert(.control) }
            guard let ch = event.charactersIgnoringModifiers?.first else { return nil }
            return KeyCombo(key: String(ch).lowercased(), modifiers: mods)
        }
    }
}

/// One editable row on the shortcuts page (9b2): category glyph + action name +
/// its current combo. Click the combo to record a new one; validates against
/// reserved keys and conflicts; per-row reset-to-default. Writes go to the
/// registry's override layer, so the menu/key handlers update live.
struct ShortcutRow: View {
    let definition: ShortcutDefinition

    @ObservedObject private var registry = ShortcutRegistry.shared
    @State private var capturing = false
    @State private var message: String?

    private var combo: KeyCombo { registry.binding(for: definition.id) }
    private var isCustom: Bool { registry.isCustomized(definition.id) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Self.glyph(for: definition.category))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.10)))

            VStack(alignment: .leading, spacing: 2) {
                Text(definition.name).lineLimit(1)
                if let message {
                    Text(message).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                } else {
                    Text(definition.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if capturing {
                captureControls
            } else {
                // Click the combo to start recording a replacement.
                Button { startCapture() } label: { KeyCapsView(combo: combo) }
                    .buttonStyle(.plain)
                    .help("Click to change")
                // Reset only when this action is customised.
                Button { registry.resetToDefault(definition.id); message = nil } label: {
                    Image(systemName: "arrow.uturn.backward").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Reset to default (\(definition.defaultCombo.display))")
                .opacity(isCustom ? 1 : 0)
                .disabled(!isCustom)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var captureControls: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 2)
            Text("Press shortcut…").font(.caption).foregroundStyle(.secondary)
            ShortcutCaptureField(onCapture: handleCapture, onCancel: cancelCapture).opacity(0.02)
        }
        .frame(width: 150, height: 24)
        Button("Cancel", action: cancelCapture)
            .controlSize(.small)
    }

    private func startCapture() {
        message = nil
        capturing = true
    }

    private func cancelCapture() {
        capturing = false
        message = nil
    }

    private func handleCapture(_ new: KeyCombo) {
        // Require a real shortcut modifier (⌘/⌃/⌥); shift-only or bare keys would
        // hijack typing. Stay in capture so the user can press another.
        let mods = new.modifiers
        guard mods.contains(.command) || mods.contains(.control) || mods.contains(.option) else {
            message = "Use a modifier key (⌘, ⌃, or ⌥)."
            return
        }
        // Unchanged → just close.
        if new == combo { cancelCapture(); return }
        // Reserved by macOS / the system — can't be overridden.
        if registry.isReserved(new) {
            message = "\(new.display) is reserved by the system."
            return
        }
        // Already bound elsewhere — name the holder; let the user pick another or cancel.
        if let holder = registry.conflict(for: new, excluding: definition.id) {
            message = "\(new.display) is already used by “\(registry.definition(for: holder).name)”. Press another, or Cancel."
            return
        }
        registry.setOverride(new, for: definition.id)   // override layer → live everywhere
        capturing = false
        message = nil
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

/// The full Keyboard Shortcuts page (slice 9b/9b2), rendered as an internal tab via
/// the shared `SearchFilterPage`. All registry entries grouped by category,
/// searchable, and editable (record a new combo per row; reset per-row or all).
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
            actions: {
                Button("Reset All") { registry.resetAll() }
                    .disabled(registry.overrides.isEmpty)
            },
            row: { def in
                ShortcutRow(definition: def)
            }
        )
    }
}
