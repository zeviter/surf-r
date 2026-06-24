import SwiftUI
import AppKit
import SurfrCore

/// WF-9 — the vault Security Check ("Watchtower"-style). A **sub-surface** of the vault (not a rail
/// icon), reached from the vault-list header. Groups the local-only signals — Weak · Reused ·
/// 2FA-available · Needs attention (junk hosts) — in the amber/blue badge vocabulary, each row linking
/// to the item's editor (where the password generator, website, and TOTP fields live).
///
/// Everything here reads **already-derived metadata** (`gate.audit`, populated by the keyed-token,
/// zero-decryption walk in `VaultGate.runSecurityCheck()`); this view never decrypts a payload, and
/// **never displays a shared password value** — the Reused clusters are labelled generically.
/// Honest framing per vault-spec §13: 2FA-available is a *bundled-list* signal (dated), not proof.
struct SecurityCheckView: View {
    @EnvironmentObject private var gate: VaultGate
    /// Live search (owned by the vault surface so ESC can clear it before popping the nav stack).
    @Binding var query: String
    /// Open an item's editor (regenerate password / fix website / add a one-time code).
    let onOpenItem: (UUID) -> Void

    @State private var ran = false
    @FocusState private var searchFocused: Bool

    private var summary: VaultGate.AuditSummary { gate.audit }
    private func item(_ id: UUID) -> StoredItem? { gate.items.first { $0.id == id } }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    group(title: "Weak passwords",
                          systemImage: "exclamationmark.triangle.fill", tint: .orange,
                          ids: summary.weak,
                          allClear: "No weak passwords.",
                          actionLabel: "Regenerate", actionIcon: "wand.and.stars") { _ in
                        "Short or low-entropy — generate a stronger one."
                    }
                    reusedSection
                    group(title: "Two-factor available",
                          systemImage: "lock.shield.fill", tint: .blue,
                          ids: summary.twoFAAvailable,
                          allClear: "Nothing to add here.",
                          actionLabel: "Add code", actionIcon: "qrcode") { _ in
                        "This site supports a one-time code — add one for stronger sign-in."
                    }
                    group(title: "Needs attention",
                          systemImage: "questionmark.circle.fill", tint: .orange,
                          ids: summary.junk,
                          allClear: "No broken entries.",
                          actionLabel: "Fix website", actionIcon: "link") { _ in
                        "This entry has no usable website — add one so fill and favicons work."
                    }
                    footer
                }
                .padding(.horizontal, 16).padding(.vertical, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        // Recompute on open (cheap for a personal vault) — this is also the one-time backfill.
        .task { if !ran { ran = true; await gate.runSecurityCheck() } }
    }

    // MARK: Header — title, last-checked, manual re-run.

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Security check").font(.title2).bold()
                Text(lastCheckedText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if gate.isWorking { ProgressView().controlSize(.small) }
            Button { Task { await gate.runSecurityCheck() } } label: {
                Label("Re-run", systemImage: "arrow.clockwise")
            }
            .disabled(gate.isWorking)
            .help("Re-check your logins now")
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search logins", text: $query).textFieldStyle(.plain).focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.gray.opacity(0.25)))
        .padding(.horizontal, 20).padding(.bottom, 12)
    }

    private var lastCheckedText: String {
        guard let date = summary.lastChecked else { return "Not checked yet" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
        return "Last checked " + f.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Search filtering.

    private func matches(_ id: UUID) -> Bool {
        guard !query.isEmpty else { return true }
        guard let it = item(id) else { return false }
        let q = query.lowercased()
        return it.title.lowercased().contains(q) || it.hosts.contains { $0.host.lowercased().contains(q) }
    }

    private func orderedItems(_ ids: [UUID]) -> [StoredItem] {
        ids.compactMap(item).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: One flat category section. Empty groups show "all clear"; search misses show "no matches".

    @ViewBuilder
    private func group(title: String, systemImage: String, tint: Color, ids: [UUID],
                       allClear: String, actionLabel: String, actionIcon: String,
                       caption: @escaping (UUID) -> String) -> some View {
        let shown = ids.filter(matches)
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(title: title, systemImage: systemImage, tint: tint, count: ids.count)
            if shown.isEmpty {
                emptyRow(ids.isEmpty ? allClear : "No matches",
                         allClear: ids.isEmpty, tint: tint)
            } else {
                ForEach(orderedItems(shown)) { it in
                    row(it, caption: caption(it.id), actionLabel: actionLabel, actionIcon: actionIcon)
                }
            }
        }
    }

    // MARK: Reused — one block per shared-password cluster (the actionable unit). Never shows the value.

    @ViewBuilder
    private var reusedSection: some View {
        let clusters = summary.reuseClusters.filter { c in query.isEmpty || c.contains(where: matches) }
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "Reused passwords", systemImage: "rectangle.on.rectangle.fill",
                          tint: .orange, count: summary.reused.count)
            if clusters.isEmpty {
                emptyRow(summary.reuseClusters.isEmpty ? "No reused passwords." : "No matches",
                         allClear: summary.reuseClusters.isEmpty, tint: .orange)
            } else {
                ForEach(Array(clusters.enumerated()), id: \.offset) { _, cluster in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(cluster.count) logins share a password")   // never the password itself
                            .font(.subheadline).bold().padding(.horizontal, 8)
                        ForEach(orderedItems(cluster)) { it in
                            row(it, caption: it.hosts.first?.host,
                                actionLabel: "Change", actionIcon: "arrow.triangle.2.circlepath")
                        }
                    }
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.05)))
                }
            }
        }
    }

    // MARK: Shared pieces.

    private func sectionHeader(title: String, systemImage: String, tint: Color, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(count == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
            Text(title).font(.headline)
            if count > 0 {
                Text("\(count)").font(.caption).bold().foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(tint))
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private func emptyRow(_ text: String, allClear: Bool, tint: Color) -> some View {
        Label(text, systemImage: allClear ? "checkmark.circle.fill" : "magnifyingglass")
            .font(.callout).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func row(_ it: StoredItem, caption: String?, actionLabel: String, actionIcon: String) -> some View {
        PageRow(host: it.hosts.first?.host ?? "",
                primary: it.title.isEmpty ? (it.hosts.first?.host ?? "Login") : it.title,
                secondary: caption,
                onOpen: { onOpenItem(it.id) }) {
            Button { onOpenItem(it.id) } label: { Label(actionLabel, systemImage: actionIcon) }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }

    // MARK: Footer — honest framing + required attribution (vault-spec §13, §10 WF-9).

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.vertical, 4)
            Text("All checks run **on your device** — nothing is sent anywhere. Weak and reused are about your own passwords.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Two-factor availability is based on a bundled list (dated \(gate.twoFASnapshotDate)) — absence isn’t proof a site lacks 2FA.")
                .font(.caption).foregroundStyle(.secondary)
            Text(gate.twoFAAttribution)
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8).padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
