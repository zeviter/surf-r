import SwiftUI

/// C2 — the in-page find bar overlay: a small native chrome panel reusing the spotlight field +
/// Esc-dismiss vocabulary. Native WebKit find does the highlight/scroll/wrap; this is just the query +
/// controls. `WKFindResult` exposes only match-found (no index/count), so the bar shows a "No matches"
/// state rather than "3/17" — a numeric count would need private API or an injected JS find script, both
/// against the native-over-injected principle. Enter / ↓ = next, ⇧ via ↑ = previous (⌘G / ⌘⇧G also), Esc closes.
struct FindBar: View {
    @Binding var text: String
    let focusToken: Int
    let noMatches: Bool
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            // Reuse the omnibox field: reliable focus + Enter (→ next) + Esc (→ close) + ↑/↓ (prev/next).
            OmniboxField(text: $text, placeholder: "Find on page", large: false, focusToken: focusToken,
                         onMoveUp: onPrevious, onMoveDown: onNext, onSubmit: onNext, onCancel: onClose)
                .frame(width: 190)
            if !text.isEmpty && noMatches {
                Text("No matches").font(.caption).foregroundStyle(.orange).fixedSize()
            }
            Divider().frame(height: 16)
            Button(action: onPrevious) { Image(systemName: "chevron.up") }
                .buttonStyle(.plain).help("Previous match (⌘⇧G)")
            Button(action: onNext) { Image(systemName: "chevron.down") }
                .buttonStyle(.plain).help("Next match (⌘G)")
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.plain).help("Close (Esc)")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.gray.opacity(0.25)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
}
