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
    @Published private(set) var totp: TOTP?             // parsed from payload.totp; nil = none
    @Published private(set) var revealed: String?       // nil = masked
    @Published private(set) var loadFailed = false
    /// When biometric reveal is cancelled/unavailable, the view shows a master-password fallback (6a).
    @Published var awaitingMaster = false
    @Published var masterError = false
    /// Transient "… copied" confirmation shown after any copy.
    @Published var copyConfirmation: String?

    private var password = WipeableSecret("")
    private(set) var isWiped = false
    private var copyClearTask: Task<Void, Never>?

    private enum Pending { case none, reveal, copy }
    private var pending: Pending = .none

    /// Test/seam-friendly load from an already-decrypted payload.
    func load(payload: LoginPayload, hosts: [SurfrCore.Host]) {
        username = payload.username
        website = payload.urls.first ?? hosts.first?.host ?? ""
        notes = payload.notes
        totp = payload.totp.flatMap { TOTP(otpauthURI: $0) }
        password = WipeableSecret(payload.password)
        isWiped = false
    }

    func load(_ item: StoredItemRef, gate: VaultGate) {
        guard let payload = gate.decryptPayload(item.stored) else { loadFailed = true; return }
        load(payload: payload, hosts: item.stored.hosts)
    }

    func conceal() { revealed = nil }

    /// Reveal/copy with the reveal-auth policy (6a/6b): if auth not required → do it directly; else try
    /// Touch ID; on cancel/no-biometric → fall back to the master-password prompt (never a dead-end).
    func requestReveal(gate: VaultGate) async { await authThenPerform(.reveal, gate: gate) }
    func requestCopy(gate: VaultGate) async { await authThenPerform(.copy, gate: gate) }

    private func authThenPerform(_ action: Pending, gate: VaultGate) async {
        if !gate.requireAuthToReveal { perform(action); return }
        if gate.biometricState == .enabled, await gate.biometricAuthenticateForReveal() {
            perform(action); return
        }
        pending = action
        masterError = false
        awaitingMaster = true   // show the master-password fallback
    }

    /// Master-password fallback submit (6a). On success, perform the pending reveal/copy.
    func submitMaster(_ password: String, gate: VaultGate) async {
        guard await gate.verifyMaster(password) else { masterError = true; return }
        awaitingMaster = false; masterError = false
        perform(pending); pending = .none
    }

    func cancelMaster() { awaitingMaster = false; masterError = false; pending = .none }

    private func perform(_ action: Pending) {
        switch action {
        case .reveal: revealed = password.reveal()
        case .copy: VaultClipboard.copyConcealed(password.reveal()); noteCopied("Password")
        case .none: break
        }
    }

    /// Show a brief "… copied" confirmation (any field). Auto-clears after ~1.5 s.
    func noteCopied(_ label: String) {
        copyConfirmation = "\(label) copied"
        copyClearTask?.cancel()
        copyClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { self?.copyConfirmation = nil }
        }
    }

    func copyUsername() { VaultClipboard.copyPlain(username); noteCopied("Username") }
    func copyCode(_ code: String) { VaultClipboard.copyConcealed(code); noteCopied("Code") }

    /// Zero the password buffer and clear all decrypted fields. Called on disappear.
    func wipe() {
        password.wipe()
        username = ""; website = ""; notes = ""; revealed = nil; totp = nil
        awaitingMaster = false; masterError = false; pending = .none
        isWiped = true
    }

    var passwordIsWipedForTest: Bool { password.isWiped }
}

/// Lightweight wrapper so navigation can carry a `StoredItem` by value without making the SurfrCore
/// type `Hashable`.
struct StoredItemRef: Equatable { let stored: StoredItem }

/// TOTP countdown ring (green, amber in the last 5 s).
struct CountdownRing: View {
    let remaining: Int
    let period: Int
    var body: some View {
        ZStack {
            Circle().stroke(Color.gray.opacity(0.25), lineWidth: 2)
            Circle()
                .trim(from: 0, to: CGFloat(remaining) / CGFloat(max(1, period)))
                .stroke(remaining <= 5 ? Color.orange : Color.green, lineWidth: 2)
                .rotationEffect(.degrees(-90))
            Text("\(remaining)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
        }
        .frame(width: 22, height: 22)
    }
}

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
                        Button { model.copyUsername() } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.plain).help("Copy username")
                    }

                    passwordField

                    if let totp = model.totp { totpSection(totp) }
                    if !model.website.isEmpty { field("Website", value: model.website) { EmptyView() } }
                    if !model.notes.isEmpty { field("Notes", value: model.notes) { EmptyView() } }
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
        .overlay(alignment: .bottom) {
            if let msg = model.copyConfirmation {
                Label(msg, systemImage: "checkmark.circle.fill")
                    .font(.callout).padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.green.opacity(0.4)))
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.copyConfirmation)
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
                    if model.revealed == nil { Task { await model.requestReveal(gate: gate) } } else { model.conceal() }
                } label: { Image(systemName: model.revealed == nil ? "eye.fill" : "eye.slash.fill") }
                    .buttonStyle(.plain).help(model.revealed == nil ? "Reveal" : "Hide")
                Button { Task { await model.requestCopy(gate: gate) } } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).help("Copy password")
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))

            if model.awaitingMaster { masterFallback }
        }
    }

    /// Master-password fallback for reveal/copy (6a) — shown when biometric is cancelled/unavailable.
    @State private var fallbackMaster = ""
    private var masterFallback: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Enter your master password to reveal").font(.caption).foregroundStyle(.secondary)
            HStack {
                VaultPasswordField(placeholder: "Master password", text: $fallbackMaster, autoFocus: true,
                                   onSubmit: { submitFallback() })
                Button("Reveal") { submitFallback() }.keyboardShortcut(.defaultAction)
                Button("Cancel") { fallbackMaster = ""; model.cancelMaster() }
            }
            if model.masterError {
                Text("Incorrect master password.").font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.top, 4)
    }

    private func submitFallback() {
        let pw = fallbackMaster
        Task {
            await model.submitMaster(pw, gate: gate)
            if !model.awaitingMaster { fallbackMaster = "" }   // cleared on success
        }
    }

    /// Live TOTP code + countdown ring. `TimelineView(.periodic)` only ticks while this view is on
    /// screen, so navigating away stops it (no background timer); `model.wipe()` clears the secret.
    private func totpSection(_ totp: TOTP) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ONE-TIME CODE").font(.caption).bold().foregroundStyle(.secondary)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let code = totp.code(at: context.date)
                let remaining = totp.secondsRemaining(at: context.date)
                HStack(spacing: 10) {
                    Text(Self.grouped(code)).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    CountdownRing(remaining: remaining, period: totp.period)
                    Button { model.copyCode(code) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain).help("Copy code")
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
        }
    }

    /// "123456" → "123 456" for readability (8-digit → "1234 5678").
    private static func grouped(_ code: String) -> String {
        let mid = code.count / 2
        let i = code.index(code.startIndex, offsetBy: mid)
        return "\(code[..<i]) \(code[i...])"
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
