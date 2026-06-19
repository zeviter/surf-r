import SwiftUI
import Combine

/// Stable identity for every app shortcut (used as the persistence key).
enum ShortcutID: String, CaseIterable, Codable {
    case newTab, closeTab, openLocation
    case reload, hardReload, emptyCacheReload
    case back, forward
    case bookmark, trustSite
    case history, trustedSites, downloads, shortcuts
}

/// Grouping for the (later) shortcuts page/editor.
enum ShortcutCategory: String {
    case tabs = "Tabs"
    case navigation = "Navigation"
    case page = "Page"
    case surfaces = "Surfaces"
}

/// Codable, SwiftUI-bridgeable modifier set (so combos can be persisted as JSON
/// and applied to menu `keyboardShortcut`s).
struct ShortcutModifiers: OptionSet, Codable, Equatable {
    let rawValue: Int
    static let command = ShortcutModifiers(rawValue: 1 << 0)
    static let shift   = ShortcutModifiers(rawValue: 1 << 1)
    static let option  = ShortcutModifiers(rawValue: 1 << 2)
    static let control = ShortcutModifiers(rawValue: 1 << 3)

    var eventModifiers: EventModifiers {
        var m: EventModifiers = []
        if contains(.command) { m.insert(.command) }
        if contains(.shift)   { m.insert(.shift) }
        if contains(.option)  { m.insert(.option) }
        if contains(.control) { m.insert(.control) }
        return m
    }

    /// Menu-style glyphs in canonical order (⌃⌥⇧⌘).
    var symbols: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option)  { s += "⌥" }
        if contains(.shift)   { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

/// A key + modifiers. Persisted (Codable) for user overrides; resolves to a
/// SwiftUI `KeyEquivalent`/`EventModifiers` for the menu bar.
struct KeyCombo: Equatable, Codable {
    var key: String   // single character, e.g. "t", "[", "/"
    var modifiers: ShortcutModifiers

    var keyEquivalent: KeyEquivalent { KeyEquivalent(Character(key)) }

    /// Human-readable, e.g. "⌘T", "⌘⌥R", "⌘/".
    var display: String { modifiers.symbols + key.uppercased() }
}

/// One shortcut's identity, label, category, and factory-default combo.
struct ShortcutDefinition: Identifiable {
    let id: ShortcutID
    let name: String
    let category: ShortcutCategory
    let defaultCombo: KeyCombo
}

/// Central, override-ready shortcut registry (slice 9a).
///
/// Two layers: immutable **defaults** (`definitions`) + a persisted **user
/// override** map (`overrides`). The **effective** binding is
/// `override ?? default`, resolved by `binding(for:)`. The menu bar and key
/// handlers must read `binding(for:)` — never hardcode keys — so a future editor
/// (9b) can mutate `overrides` at runtime and everything updates. Overrides are
/// empty by default; the editing UI is a later slice, but the mutation +
/// conflict API is provided here so 9b can render and change bindings.
@MainActor
final class ShortcutRegistry: ObservableObject {
    static let shared = ShortcutRegistry()

    /// Factory defaults, in display order. The 9b page groups these by category.
    let definitions: [ShortcutDefinition]
    /// User remaps: id → custom combo. Empty unless the user has customised.
    @Published private(set) var overrides: [ShortcutID: KeyCombo]

    private let overridesKey = "SurfrShortcutOverrides"

    private init() {
        definitions = Self.defaults
        overrides = Self.loadOverrides(key: "SurfrShortcutOverrides")
    }

    // MARK: - Resolution (used by the menu bar + key handlers)

    func definition(for id: ShortcutID) -> ShortcutDefinition {
        // Every ShortcutID has a definition; this is exhaustive by construction.
        definitions.first { $0.id == id } ?? definitions[0]
    }

    /// The effective binding: user override if set, else the default.
    func binding(for id: ShortcutID) -> KeyCombo {
        overrides[id] ?? definition(for: id).defaultCombo
    }

    func isCustomized(_ id: ShortcutID) -> Bool { overrides[id] != nil }

    // MARK: - Mutation (foundation for the 9b editor; no UI yet)

    func setOverride(_ combo: KeyCombo, for id: ShortcutID) {
        overrides[id] = combo
        persist()
    }

    func resetToDefault(_ id: ShortcutID) {
        overrides[id] = nil
        persist()
    }

    func resetAll() {
        overrides = [:]
        persist()
    }

    /// The first shortcut already bound to `combo` (excluding `id`) — so the editor
    /// can warn before assigning a key that's already taken.
    func conflict(for combo: KeyCombo, excluding id: ShortcutID) -> ShortcutID? {
        ShortcutID.allCases.first { $0 != id && binding(for: $0) == combo }
    }

    /// macOS-reserved combos a user shouldn't be able to claim (the editor blocks
    /// these). Not exhaustive — the common system globals.
    func isReserved(_ combo: KeyCombo) -> Bool {
        Self.reserved.contains(combo)
    }

    // MARK: - Persistence

    private func persist() {
        let byString = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(byString) {
            UserDefaults.standard.set(data, forKey: overridesKey)
        }
    }

    private static func loadOverrides(key: String) -> [ShortcutID: KeyCombo] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let byString = try? JSONDecoder().decode([String: KeyCombo].self, from: data) else { return [:] }
        var result: [ShortcutID: KeyCombo] = [:]
        for (raw, combo) in byString { if let id = ShortcutID(rawValue: raw) { result[id] = combo } }
        return result
    }

    // MARK: - Defaults

    private static func c(_ key: String, _ mods: ShortcutModifiers) -> KeyCombo {
        KeyCombo(key: key, modifiers: mods)
    }

    private static let defaults: [ShortcutDefinition] = [
        // Tabs
        .init(id: .newTab,           name: "New Tab",                    category: .tabs,       defaultCombo: c("t", [.command])),
        .init(id: .closeTab,         name: "Close Tab",                  category: .tabs,       defaultCombo: c("w", [.command])),
        // Navigation
        .init(id: .openLocation,     name: "Open Location…",             category: .navigation, defaultCombo: c("l", [.command])),
        .init(id: .reload,           name: "Reload Page",                category: .navigation, defaultCombo: c("r", [.command])),
        .init(id: .hardReload,       name: "Hard Reload (Bypass Cache)", category: .navigation, defaultCombo: c("r", [.command, .shift])),
        .init(id: .emptyCacheReload, name: "Empty Cache and Hard Reload",category: .navigation, defaultCombo: c("r", [.command, .option])),
        .init(id: .back,             name: "Back",                       category: .navigation, defaultCombo: c("[", [.command])),
        .init(id: .forward,          name: "Forward",                    category: .navigation, defaultCombo: c("]", [.command])),
        // Page actions
        .init(id: .bookmark,         name: "Bookmark Page",              category: .page,       defaultCombo: c("d", [.command])),
        .init(id: .trustSite,        name: "Trust This Site",            category: .page,       defaultCombo: c("t", [.command, .shift])),
        // Surfaces (internal pages)
        .init(id: .history,          name: "History",                    category: .surfaces,   defaultCombo: c("y", [.command])),
        .init(id: .trustedSites,     name: "Trusted Sites",              category: .surfaces,   defaultCombo: c("y", [.command, .shift])),
        .init(id: .downloads,        name: "Downloads",                  category: .surfaces,   defaultCombo: c("j", [.command, .shift])),
        .init(id: .shortcuts,        name: "Keyboard Shortcuts",         category: .surfaces,   defaultCombo: c("/", [.command])),
    ]

    private static let reserved: [KeyCombo] = [
        c("q", [.command]),            // Quit
        c("h", [.command]),            // Hide
        c("h", [.command, .option]),   // Hide Others
        c("m", [.command]),            // Minimize
    ]
}

extension View {
    /// Apply a shortcut's **effective** binding (override ?? default) from the
    /// registry. Reads dynamically so menu items update if a binding changes.
    func appShortcut(_ id: ShortcutID, _ registry: ShortcutRegistry) -> some View {
        let combo = registry.binding(for: id)
        return keyboardShortcut(combo.keyEquivalent, modifiers: combo.modifiers.eventModifiers)
    }
}
