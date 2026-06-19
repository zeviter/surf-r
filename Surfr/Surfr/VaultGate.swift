import Foundation
import Combine
import SurfrCore

/// App-level coordinator for the password vault UI. Owns the single `VaultStore` + `VaultLock`,
/// resolves the on-screen `Phase`, and drives the mandatory first-run flow via `FirstRunReducer`.
///
/// Secret discipline: the master password and recovery code held during first-run live in
/// `WipeableSecret` buffers and are `memset`-zeroed on commit or abandon. The live vault key only
/// ever resides inside `VaultLock` (zeroed on lock). Nothing here logs a secret. All Argon2 work is
/// pushed off the main thread.
@MainActor
final class VaultGate: ObservableObject {

    enum Phase: Equatable { case uninitialized, firstRun, locked, unlocked }

    @Published private(set) var phase: Phase = .uninitialized
    @Published private(set) var firstRunStep: FirstRunReducer.Step = .setMaster
    /// The recovery code shown on the kit step (WF-10). Cleared when first-run ends.
    @Published private(set) var recoveryCodeForDisplay = ""
    /// True while an Argon2 derivation is running, so the UI can show a spinner.
    @Published private(set) var isWorking = false
    @Published private(set) var lastError: String?

    private let store: VaultStore?
    private let lock = VaultLock()
    private let params: KDFParams

    private var reducer = FirstRunReducer()
    private var pendingMeta: VaultMeta?            // in-memory during first-run (non-secret)
    private var pendingMaster: WipeableSecret?
    private var pendingRecovery: WipeableSecret?

    init(storePath: URL? = nil, params: KDFParams = .defaultMacOS) {
        self.params = params
        self.store = try? VaultStore(path: storePath ?? Self.defaultStorePath())
    }

    /// Resolve the initial phase from disk (call once on appear).
    func load() async {
        guard let store else { phase = .uninitialized; return }
        // Don't clobber an in-progress first-run or an already-unlocked session.
        guard phase != .firstRun, phase != .unlocked else { return }
        let exists = (try? await store.hasVault()) ?? false
        phase = exists ? .locked : .uninitialized
    }

    var isUnlocked: Bool { phase == .unlocked }

    // MARK: - First run (WF-2)

    func beginFirstRun() {
        guard phase == .uninitialized else { return }
        reducer = FirstRunReducer()
        firstRunStep = .setMaster
        recoveryCodeForDisplay = ""
        lastError = nil
        phase = .firstRun
    }

    /// Step 1 → 2: accept the master password, create the vault **in memory**, generate the recovery
    /// code, and advance to the kit step. Nothing is written to disk here.
    func submitMaster(_ password: String) async {
        guard phase == .firstRun, firstRunStep == .setMaster, !password.isEmpty else { return }
        isWorking = true; lastError = nil
        defer { isWorking = false }

        guard reducer.apply(.masterAccepted) == .createInMemoryVault else { return }

        let code = VaultCrypto.generateRecoveryCode()
        let p = params
        do {
            let meta = try await Task.detached(priority: .userInitiated) {
                try VaultCrypto.createVault(masterPassword: password, recoveryCode: code, params: p).meta
            }.value
            pendingMeta = meta
            pendingMaster = WipeableSecret(password)
            pendingRecovery = WipeableSecret(code)
            recoveryCodeForDisplay = code
            firstRunStep = reducer.step          // .recoveryKit
        } catch {
            abandonFirstRun()
            lastError = "Could not create the vault. Please try again."
        }
    }

    /// Step 2 → committed: the user confirmed they saved the kit. **This is the only disk write of
    /// first-run.** Persist meta, adopt the key into the lock, then wipe the in-memory secrets.
    func acknowledgeKit() async {
        guard phase == .firstRun, firstRunStep == .recoveryKit else { return }
        isWorking = true; lastError = nil
        defer { isWorking = false }

        guard reducer.apply(.acknowledgeKit) == .commitToDisk,
              let store, let meta = pendingMeta, let master = pendingMaster?.reveal(), !master.isEmpty
        else { abandonFirstRun(); return }

        do {
            try await store.saveMeta(meta)
            try await Task.detached(priority: .userInitiated) { [lock] in
                try lock.unlockWithMaster(master, meta: meta)
            }.value
            wipePending()
            phase = .unlocked
        } catch {
            // Commit failed; allow a retry from the kit step rather than losing the in-memory vault.
            reducer = FirstRunReducer()
            _ = reducer.apply(.masterAccepted)   // back to .recoveryKit, secrets still held
            lastError = "Could not save the vault. Please try again."
        }
    }

    /// Abandon mid-first-run (cancel / quit): wipe the in-memory secrets with lock discipline and
    /// drop the half-created vault. Next entry starts a clean first-run.
    func abandonFirstRun() {
        _ = reducer.apply(.abandon)
        wipePending()
        reducer = FirstRunReducer()
        firstRunStep = .setMaster
        phase = .uninitialized
    }

    private func wipePending() {
        pendingMaster?.wipe(); pendingRecovery?.wipe()
        pendingMaster = nil; pendingRecovery = nil
        pendingMeta = nil
        recoveryCodeForDisplay = ""
    }

    // MARK: - Unlock (WF-3)

    /// Returns true on success. On failure sets `lastError` and stays locked.
    func unlock(master: String) async -> Bool {
        guard let store, !master.isEmpty else { return false }
        isWorking = true; lastError = nil
        defer { isWorking = false }
        guard let meta = try? await store.loadMeta() else { lastError = "No vault found."; return false }
        do {
            try await Task.detached(priority: .userInitiated) { [lock] in
                try lock.unlockWithMaster(master, meta: meta)
            }.value
            phase = .unlocked
            return true
        } catch {
            lastError = "Incorrect master password."
            return false
        }
    }

    /// Recovery path: unlock with the recovery code and set a new master password, then re-persist.
    func resetWithRecovery(code: String, newMaster: String) async -> Bool {
        guard let store, !code.isEmpty, !newMaster.isEmpty else { return false }
        isWorking = true; lastError = nil
        defer { isWorking = false }
        guard let meta = try? await store.loadMeta() else { lastError = "No vault found."; return false }
        do {
            let newMeta = try await Task.detached(priority: .userInitiated) {
                try VaultCrypto.recoverAndResetMaster(recoveryCode: code, newPassword: newMaster, meta: meta).meta
            }.value
            try await store.saveMeta(newMeta)
            try await Task.detached(priority: .userInitiated) { [lock] in
                try lock.unlockWithMaster(newMaster, meta: newMeta)
            }.value
            phase = .unlocked
            return true
        } catch {
            lastError = "Recovery code not recognized."
            return false
        }
    }

    func lockNow() {
        lock.lock()
        if phase == .unlocked { phase = .locked }
    }

    func clearError() { lastError = nil }

    // MARK: - Storage location

    private static func defaultStorePath() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Surfr", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vault.sqlite")
    }
}
