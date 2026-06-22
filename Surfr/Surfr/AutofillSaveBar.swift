import SwiftUI

/// Unobtrusive post-submit save prompt (Slice 8b/WF-8). "Save"/"Update" (primary), "Never" (persisted
/// per-site suppression), and a distinct ✕ (dismiss once — does NOT suppress the site). Auto-dismisses
/// via the coordinator's bounded timeout if ignored, so it never re-nags after a plain dismissal.
struct AutofillSaveBar: View {
    @ObservedObject var coordinator: AutofillSaveCoordinator
    /// Locked vault → caller unlocks, then completes the save.
    let onUnlockAndSave: () -> Void

    var body: some View {
        if let p = coordinator.pending {
            HStack(spacing: 12) {
                Image(systemName: "key.horizontal.fill").foregroundStyle(.secondary)
                Text(prompt(p)).font(.callout).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Never") { coordinator.never() }
                    .help("Never offer to save for \(p.domain)")
                Button(primaryLabel(p)) {
                    if p.kind == .lockedSave { onUnlockAndSave() } else { Task { await coordinator.save() } }
                }
                .keyboardShortcut(.defaultAction)
                Button { coordinator.dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Not now")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.gray.opacity(0.25)))
            .shadow(radius: 14, y: 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 22)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func prompt(_ p: AutofillSaveCoordinator.Pending) -> String {
        p.kind == .update ? "Update saved password for \(p.domain)?" : "Save login for \(p.domain)?"
    }
    private func primaryLabel(_ p: AutofillSaveCoordinator.Pending) -> String {
        switch p.kind { case .update: return "Update"; case .lockedSave: return "Unlock & Save"; case .save: return "Save" }
    }
}
