import SwiftUI
import SurfrCore

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
