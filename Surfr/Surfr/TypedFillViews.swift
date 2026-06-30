import SwiftUI
import SurfrCore

/// TV-3a — in-browser card/address click-to-fill chrome. A native-overlay icon (card / pin glyph) sits
/// adjacent to a detected card or address form's primary field — drawn over the WKWebView, NOT in page
/// DOM (reuses the Slice-8e overlay's privacy property: the page can't query or observe it). Amber = a
/// saved card/address can fill here; green = surf-r filled this group. Hidden while scrolling. Clicking
/// summons the same auth-gated fill flow as the login path. Bank accounts are NOT web-filled.
struct TypedFieldOverlay: View {
    @ObservedObject var controller: AutofillController
    @EnvironmentObject private var vault: VaultGate
    /// Called with the group kind ("card" | "address") when an icon is clicked.
    let onFill: (String) -> Void

    private var hasCards: Bool { vault.items.contains { $0.type == VaultItemType.payment } }
    private var hasAddresses: Bool { vault.items.contains { $0.type == VaultItemType.address } }

    /// An anchor is offerable only when the vault is unlocked AND there's a saved item of that kind to
    /// fill with — exactly the login overlay's "available" rule, applied per group.
    private func offerable(_ anchor: AutofillController.TypedAnchor) -> Bool {
        guard vault.phase == .unlocked else { return false }
        return anchor.kind == "card" ? hasCards : hasAddresses
    }

    var body: some View {
        if vault.phase == .unlocked, !controller.scrolling {
            GeometryReader { geo in
                ForEach(controller.typedAnchors) { anchor in
                    if offerable(anchor) {
                        TypedFieldIcon(kind: anchor.kind,
                                       filled: controller.filledTypedKinds.contains(anchor.kind),
                                       action: { onFill(anchor.kind) })
                            .position(x: iconX(anchor, width: geo.size.width), y: anchor.y + anchor.h / 2)
                    }
                }
            }
        }
    }

    /// Just past the field's trailing edge (never over the site's own in-field icons); tuck inside on a
    /// narrow form. Same geometry rule as the login `FieldKeyOverlay`.
    private func iconX(_ a: AutofillController.TypedAnchor, width: CGFloat) -> CGFloat {
        let outside = a.x + a.w + 12
        return outside + 12 <= width ? outside : a.x + a.w - 11
    }
}

struct TypedFieldIcon: View {
    let kind: String   // "card" | "address"
    let filled: Bool
    let action: () -> Void
    private var glyph: String { kind == "card" ? "creditcard.fill" : "mappin.and.ellipse" }
    private var noun: String { kind == "card" ? "card" : "address" }
    var body: some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .padding(4)
                .background(Circle().fill(filled ? Color.green : Color.orange))
                .shadow(radius: 1, y: 0.5)
        }
        .buttonStyle(.plain)
        .help(filled ? "surf-r filled this \(noun)" : "Saved \(noun) available — click to fill")
    }
}

/// surf-r's inline card/address picker (WF-18) — keyboard-first, summoned by the typed icon when several
/// saved items can fill. Rows render from **cleartext metadata only** (card: nickname + network + ••••
/// last4 from the hint columns; address: label) — NO payload decryption until the user picks AND the auth
/// gate passes. Up/Down to choose, Return to fill, Esc to dismiss. Mirrors the login `AutofillSuggestionView`.
struct TypedFillPicker: View {
    let family: String   // "card" | "address"
    let candidates: [StoredItem]
    let onPick: (StoredItem) -> Void
    let onCancel: () -> Void

    @State private var selected = 0
    @FocusState private var focused: Bool

    private var heading: String { family == "card" ? "Fill card" : "Fill address" }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(heading).font(.caption).bold().foregroundStyle(.secondary)
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
            Image(systemName: family == "card" ? "creditcard.fill" : "mappin.and.ellipse")
                .frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title.isEmpty ? (family == "card" ? "Card" : "Address") : item.title).lineLimit(1)
                if family == "card", let sub = cardSubtitle(item) {
                    Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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

    /// "network  •••• last4" from the cleartext hint columns — NO decryption (address rows stay label-only,
    /// since city is encrypted-payload, not cleartext metadata).
    private func cardSubtitle(_ item: StoredItem) -> String? {
        let net = CardNetwork.from(hint: item.cardNetwork)
        let last4 = item.last4 ?? ""
        let parts = [net == .unknown ? nil : net.displayName,
                     last4.isEmpty ? nil : "•••• \(last4)"].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }
}
