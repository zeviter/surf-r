import Foundation
import Combine

/// Drives the post-submit "save login?" prompt (Slice 8b). Holds the captured plaintext password in a
/// `WipeableSecret` with a **bounded lifetime** and **zero-on-every-exit** (save / Never / dismiss /
/// tab-switch / timeout / replacement / deinit) — never held indefinitely. Shared so per-tab autofill
/// controllers can route captures here without threading the gate through every Tab.
@MainActor
final class AutofillSaveCoordinator: ObservableObject {
    static let shared = AutofillSaveCoordinator()

    weak var gate: VaultGate?

    enum Kind: Equatable { case save, update, lockedSave }
    struct Pending: Identifiable {
        let id = UUID()
        let host: String
        let domain: String
        let username: String
        let password: WipeableSecret
        let kind: Kind
        let updateID: UUID?
    }

    @Published private(set) var pending: Pending?
    private var timeoutTask: Task<Void, Never>?
    private static let timeoutNanos: UInt64 = 90 * 1_000_000_000   // bounded: discard if unattended

    static let offerToSaveKey = "SurfrVaultOfferToSave"
    var isEnabled: Bool { UserDefaults.standard.object(forKey: Self.offerToSaveKey) as? Bool ?? true }

    /// Called by the autofill message handler on a login submit (HTTPS, native frame origin).
    func handleSubmit(host: String, username: String, password: String) {
        guard isEnabled, let gate else { return }
        let domain = TrustStore.registrableDomain(forHostOrURL: host)
        guard !domain.isEmpty else { return }

        // Locked: can't dedup yet — offer Unlock & Save (decision recomputed after unlock).
        guard gate.phase == .unlocked else {
            present(host: host, domain: domain, username: username, password: password, kind: .lockedSave, updateID: nil)
            return
        }
        switch gate.saveDecision(host: host, username: username, password: password) {
        case .noPrompt, .neverListed:
            return
        case .save:
            present(host: host, domain: domain, username: username, password: password, kind: .save, updateID: nil)
        case .update(let id):
            present(host: host, domain: domain, username: username, password: password, kind: .update, updateID: id)
        }
    }

    private func present(host: String, domain: String, username: String, password: String, kind: Kind, updateID: UUID?) {
        dismiss()   // zero any prior pending before replacing
        pending = Pending(host: host, domain: domain, username: username,
                          password: WipeableSecret(password), kind: kind, updateID: updateID)
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.timeoutNanos)
            if !Task.isCancelled { self?.dismiss() }
        }
    }

    /// Store the captured credential. For `lockedSave` the caller unlocks first; the decision is
    /// recomputed now that the vault is unlocked (so a post-unlock duplicate is still skipped).
    func save() async {
        guard let gate, let p = pending, gate.phase == .unlocked else { return }
        let password = p.password.reveal()
        let decision: SaveDecision = (p.kind == .update && p.updateID != nil)
            ? .update(itemID: p.updateID!)
            : gate.saveDecision(host: p.host, username: p.username, password: password)
        await gate.saveFromCapture(host: p.host, username: p.username, password: password, decision: decision)
        dismiss()
    }

    func never() {
        if let p = pending { gate?.neverSave(domain: p.domain) }
        dismiss()
    }

    /// The single zero-on-exit path: cancel the timeout and wipe the held secret.
    func dismiss() {
        timeoutTask?.cancel(); timeoutTask = nil
        pending?.password.wipe()
        pending = nil
    }
}
