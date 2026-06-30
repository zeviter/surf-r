import SwiftUI

/// C2 — the in-page find bar overlay: a small native chrome panel reusing the spotlight field +
/// Esc-dismiss vocabulary. Native WebKit find does the highlight/scroll/wrap; a count-only isolated-world
/// script supplies the "3/17" total (the public `WKFindResult` has no count). Enter / ↓ = next, ↑ =
/// previous (⌘G / ⌘⇧G also), Esc closes.
struct FindBar: View {
    @Binding var text: String
    let focusToken: Int
    /// "3/17" when found, "No matches" when not, nil for an empty query.
    let countLabel: String?
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void

    private var noMatches: Bool { countLabel == "No matches" }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            // Reuse the omnibox field: reliable focus + Enter (→ next) + Esc (→ close) + ↑/↓ (prev/next).
            OmniboxField(text: $text, placeholder: "Find on page", large: false, focusToken: focusToken,
                         onMoveUp: onPrevious, onMoveDown: onNext, onSubmit: onNext, onCancel: onClose)
                .frame(width: 190)
            if let label = countLabel {
                Text(label).font(.caption).monospacedDigit()
                    .foregroundStyle(noMatches ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize()
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
