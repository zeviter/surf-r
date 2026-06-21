import SwiftUI
import AppKit
import Combine
import SurfrCore

/// Holds the decrypted credential for a single open item (WF-5). The password is kept in a
/// `WipeableSecret` (memset-zeroed) and **`wipe()` is called on the detail view's disappear** — same
/// discipline as `VaultLock`'s key zeroing — so a closed item leaves no lingering plaintext.
@MainActor
final class VaultItemDetailModel: ObservableObject {
    @Published private(set) var username = ""
    @Published private(set) var website = ""
    @Published private(set) var notes = ""
    @Published private(set) var hasTOTP = false
    @Published private(set) var revealed: String?       // nil = masked
    @Published private(set) var loadFailed = false

    private var password = WipeableSecret("")
    private(set) var isWiped = false

    /// Test/seam-friendly load from an already-decrypted payload.
    func load(payload: LoginPayload, hosts: [SurfrCore.Host]) {
        username = payload.username
        website = payload.urls.first ?? hosts.first?.host ?? ""
        notes = payload.notes
        hasTOTP = (payload.totp?.isEmpty == false)
        password = WipeableSecret(payload.password)
        isWiped = false
    }

    func load(_ item: StoredItemRef, gate: VaultGate) {
        guard let payload = gate.decryptPayload(item.stored) else { loadFailed = true; return }
        load(payload: payload, hosts: item.stored.hosts)
    }

    /// Reveal the password (biometric-gated). On cancel → stays masked, no error.
    func reveal(gate: VaultGate) async {
        guard await gate.authenticateForReveal() else { return }
        revealed = password.reveal()
    }

    func conceal() { revealed = nil }

    func copyPassword(gate: VaultGate) async {
        guard await gate.authenticateForReveal() else { return }
        VaultClipboard.copyConcealed(password.reveal())
    }

    /// Zero the password buffer and clear all decrypted fields. Called on disappear.
    func wipe() {
        password.wipe()
        username = ""; website = ""; notes = ""; revealed = nil; hasTOTP = false
        isWiped = true
    }

    var passwordIsWipedForTest: Bool { password.isWiped }
}

/// Lightweight wrapper so navigation can carry a `StoredItem` by value without making the SurfrCore
/// type `Hashable`.
struct StoredItemRef: Equatable { let stored: StoredItem }

struct VaultItemView: View {
    let item: StoredItem
    @EnvironmentObject private var gate: VaultGate
    @StateObject private var model = VaultItemDetailModel()
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var confirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    FaviconView(host: item.hosts.first?.host ?? "", size: 40, cornerRadius: 8)
                    VStack(alignment: .leading) {
                        Text(item.title.isEmpty ? (item.hosts.first?.host ?? "Login") : item.title)
                            .font(.title2).bold()
                        if let host = item.hosts.first?.host, !host.isEmpty {
                            Text(host).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }

                if model.loadFailed {
                    Label("Couldn’t decrypt this item.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                } else {
                    field("Username", value: model.username) {
                        Button { VaultClipboard.copyPlain(model.username) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.plain).help("Copy username")
                    }

                    passwordField

                    if !model.website.isEmpty { field("Website", value: model.website) { EmptyView() } }
                    if !model.notes.isEmpty { field("Notes", value: model.notes) { EmptyView() } }
                    if model.hasTOTP {
                        Text("One-time code stored — display arrives in Slice 7.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }

                HStack {
                    Button("Edit", action: onEdit)
                    Spacer()
                    Button("Delete", role: .destructive) { confirmingDelete = true }
                }
                .padding(.top, 8)
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .task { model.load(StoredItemRef(stored: item), gate: gate) }
        .onDisappear { model.wipe() }   // zero decrypted plaintext on close
        .confirmationDialog("Delete this login?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PASSWORD").font(.caption).bold().foregroundStyle(.secondary)
            HStack {
                Text(model.revealed ?? "••••••••••")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button {
                    if model.revealed == nil { Task { await model.reveal(gate: gate) } } else { model.conceal() }
                } label: { Image(systemName: model.revealed == nil ? "eye.fill" : "eye.slash.fill") }
                    .buttonStyle(.plain).help(model.revealed == nil ? "Reveal (Touch ID)" : "Hide")
                Button { Task { await model.copyPassword(gate: gate) } } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).help("Copy password (Touch ID)")
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
        }
    }

    private func field<Trailing: View>(_ label: String, value: String,
                                       @ViewBuilder trailing: () -> Trailing) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.caption).bold().foregroundStyle(.secondary)
            HStack {
                Text(value).textSelection(.enabled)
                Spacer()
                trailing()
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
        }
    }
}
