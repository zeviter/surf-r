import SwiftUI
import SurfrCore

/// A quiet, clickable "saved login available" badge on the active host's rail tile (Slice 8d). Its
/// signal is **identical to the ⌘\ offer condition** — vault unlocked + a real detected login form
/// whose registrable host matches a stored credential (`candidates` is the same matcher path); it
/// never reflects host-match-alone. Renders a key glyph ONLY — never the username, a count, or which
/// account, and nothing reaches page DOM. Clicking summons the exact same fill flow as ⌘\.
struct LoginKeyBadge: View {
    @ObservedObject var controller: AutofillController
    @EnvironmentObject private var vault: VaultGate
    let onTap: () -> Void

    private var available: Bool {
        // Unlocked + at least one matching credential for a detected login form on this page. (Does
        // NOT depend on the "require auth" setting — the badge shows availability; auth happens at the
        // fill action.) When locked, items are empty → no badge; on navigation away the controller
        // resets → no badge.
        vault.phase == .unlocked && !controller.candidates(items: vault.items).isEmpty
    }

    var body: some View {
        if available {
            Button(action: onTap) {
                Image(systemName: "key.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .help("Saved login available — click to fill (⌘\\)")
        }
    }
}

/// Per-field click-to-fill key icons (Slice 8e), drawn in surf-r's **native chrome** over the web
/// view at each fillable field's rect — NOT in page DOM (the page can't query or observe it; reuses
/// the rail-badge privacy property the in-DOM approach would lose). Generic key glyph only — no vault
/// data. Hidden while scrolling (a native overlay can't track WebKit's async scroll); re-anchors on
/// settle. Amber = available; green = surf-r filled this field (a fact we own, not auth state).
struct FieldKeyOverlay: View {
    @ObservedObject var controller: AutofillController
    @EnvironmentObject private var vault: VaultGate
    let onFill: () -> Void

    private var available: Bool {
        vault.phase == .unlocked && !controller.candidates(items: vault.items).isEmpty
    }

    var body: some View {
        if available, !controller.scrolling {
            ForEach(controller.fieldAnchors) { anchor in
                FieldKeyIcon(filled: controller.filledFieldKinds.contains(anchor.kind), action: onFill)
                    .position(x: anchor.x + anchor.w - 11, y: anchor.y + anchor.h / 2)
            }
        }
    }
}

struct FieldKeyIcon: View {
    let filled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "key.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .padding(4)
                .background(Circle().fill(filled ? Color.green : Color.orange))
                .shadow(radius: 1, y: 0.5)
        }
        .buttonStyle(.plain)
        .help(filled ? "surf-r filled this field" : "Saved login available — click to fill (⌘\\)")
    }
}

/// surf-r's own inline credential picker (WF-7) — keyboard-first, summoned by ⌘\. Shows title + host
/// only (no decryption until the user picks and passes the biometric gate). Up/Down to choose, Return
/// to fill, Esc to dismiss.
struct AutofillSuggestionView: View {
    let candidates: [StoredItem]
    let onPick: (StoredItem) -> Void
    let onCancel: () -> Void

    @State private var selected = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Fill login").font(.caption).bold().foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, item in
                row(item, selected: index == selected)
                    .contentShape(Rectangle())
                    .onTapGesture { onPick(item) }
            }
        }
        .padding(.bottom, 6)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.gray.opacity(0.25)))
        .shadow(radius: 20, y: 8)
        .focusable()
        .focused($focused)
        .onAppear { focused = true; selected = 0 }
        .onKeyPress(.downArrow) { selected = min(selected + 1, candidates.count - 1); return .handled }
        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
        .onKeyPress(.return) { if candidates.indices.contains(selected) { onPick(candidates[selected]) }; return .handled }
        .onKeyPress(.escape) { onCancel(); return .handled }
    }

    private func row(_ item: StoredItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            FaviconView(host: item.hosts.first?.host ?? "", size: 22, cornerRadius: 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title.isEmpty ? (item.hosts.first?.host ?? "Login") : item.title).lineLimit(1)
                if let host = item.hosts.first?.host, !host.isEmpty {
                    Text(host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 4)
    }
}
