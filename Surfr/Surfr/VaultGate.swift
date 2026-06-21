import Foundation
import Combine
import LocalAuthentication
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

    /// The **single source of truth** for the biometric door's auth-state. Every view derives from
    /// this; every transition goes through `refreshBiometricState()` / the enable/disable/invalidate
    /// helpers — never set piecemeal.
    enum BiometricState: Equatable {
        case unavailable   // no biometric hardware / not enrolled in the OS
        case available     // usable, but the user hasn't enabled it for the vault
        case enabled       // enabled + a usable stored SE key
        case invalidated   // was enabled; the SE key died (enrolment changed) → re-enable needed
    }
    @Published private(set) var biometricState: BiometricState = .unavailable
    /// Sticky for the session: a genuine invalidation we've observed (the stored key was deleted, so
    /// the service alone can't report it). Cleared on enable/disable.
    private var biometricInvalidated = false

    // Convenience views over the single source (kept so call sites read naturally).
    var biometricAvailable: Bool { biometricState != .unavailable }
    var biometricEnabled: Bool { biometricState == .enabled }
    var needsBiometricReenroll: Bool { biometricState == .invalidated }

    private let store: VaultStore?
    private let lock = VaultLock()
    private let params: KDFParams
    private let biometric: BiometricUnlocking
    private let now: () -> Date

    /// §4: master password is required again after this long since the last master auth (independent
    /// of biometric use), on enrolment-change invalidation, and after a failed-attempt threshold.
    private let masterReauthInterval: TimeInterval = 14 * 24 * 60 * 60
    private let lastMasterAuthKey = "SurfrVaultLastMasterAuth"

    private var reducer = FirstRunReducer()
    private var pendingMeta: VaultMeta?            // in-memory during first-run (non-secret)
    private var pendingMaster: WipeableSecret?
    private var pendingRecovery: WipeableSecret?

    init(storePath: URL? = nil,
         params: KDFParams = .defaultMacOS,
         biometric: BiometricUnlocking = SecureEnclaveBiometricUnlock(),
         now: @escaping () -> Date = Date.init) {
        self.params = params
        self.biometric = biometric
        self.now = now
        self.store = try? VaultStore(path: storePath ?? Self.defaultStorePath())
    }

    /// §4: whether biometric must be skipped and master required (interval elapsed or a pending
    /// re-enroll). Reboot also requires master — see note in `load()`.
    var masterRequired: Bool {
        if needsBiometricReenroll { return true }
        let last = UserDefaults.standard.object(forKey: lastMasterAuthKey) as? Date
        guard let last else { return true }            // never master-authed → require it
        return now().timeIntervalSince(last) >= masterReauthInterval
    }

    /// Whether the unlock screen should auto-offer biometrics right now.
    var shouldOfferBiometric: Bool { biometricState == .enabled && !masterRequired }

    /// Resolve the initial phase from disk (call once on appear).
    func load() async {
        guard let store else { phase = .uninitialized; refreshBiometricState(); return }
        // Don't clobber an in-progress first-run or an already-unlocked session.
        guard phase != .firstRun, phase != .unlocked else { return }
        let exists = (try? await store.hasVault()) ?? false
        if !exists, biometric.isEnabled {
            // Bug 1: the vault key copies live in the SQLite vault, but the biometric SE key/blob live
            // in the Keychain. If the vault file is gone but Keychain material remains, that's an
            // orphaned half-state — purge it so we present a clean first-run, not a broken unlock.
            biometric.disable()
            biometricInvalidated = false
            vaultLog("orphaned biometric key material with no vault on disk → purged")
        }
        phase = exists ? .locked : .uninitialized
        refreshBiometricState()
        // NOTE (§4 "master on reboot"): this runs at app launch; `masterRequired` already forces master
        // when no master auth has happened this install-session within the interval.
    }

    /// Erase the entire vault — the SQLite vault (wherever it lives, incl. the sandbox container) **and**
    /// all Keychain biometric material — and return to a clean first-run. Backs the "Reset vault"
    /// affordance so a retest starts from genuinely fresh state.
    func resetVault() async {
        lock.lock()
        biometric.disable()
        biometricInvalidated = false
        try? await store?.wipeAll()
        items = []
        pendingMaster?.wipe(); pendingRecovery?.wipe()
        pendingMaster = nil; pendingRecovery = nil; pendingMeta = nil
        reducer = FirstRunReducer()
        firstRunStep = .setMaster
        recoveryCodeForDisplay = ""
        lastError = nil
        UserDefaults.standard.removeObject(forKey: lastMasterAuthKey)
        phase = .uninitialized
        refreshBiometricState()
        vaultLog("vault reset — wiped SQLite vault + Keychain biometric material; clean first-run")
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
    func acknowledgeKit(enableBiometric: Bool = false) async {
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
            recordMasterAuth()
            phase = .unlocked
            // First-run "enable biometric" (WF-2 step 2): wrap the now-resident key to the SE.
            if enableBiometric, biometricAvailable { self.enableBiometric() }
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
            recordMasterAuth()
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
            recordMasterAuth()
            phase = .unlocked
            return true
        } catch {
            lastError = "Recovery code not recognized."
            return false
        }
    }

    func lockNow() {
        lock.lock()
        items = []
        if phase == .unlocked { phase = .locked }
    }

    func clearError() { lastError = nil }

    // MARK: - Items (Slice 5)

    /// Cleartext metadata only (title/host/dates/health) — drives the list with **no decryption**.
    @Published private(set) var items: [StoredItem] = []

    /// (Re)load the list. Only the cleartext metadata is read; payloads stay encrypted on disk.
    func loadItems() async {
        guard let store, phase == .unlocked else { items = []; return }
        items = (try? await store.allItems()) ?? []
    }

    /// Decrypt ONE item's payload (detail view), via the unlocked vault key. Returns nil if locked /
    /// on failure. This is the only place a credential payload is decrypted.
    func decryptPayload(_ item: StoredItem) -> LoginPayload? {
        guard phase == .unlocked else { return nil }
        return try? lock.withVaultKey { key in
            let data = try VaultCrypto.decryptItem(item.sealed, vaultKey: key)
            return try LoginPayload.decoded(from: data)
        }
    }

    /// Create (id == nil) or update an item: encrypt the payload under a fresh per-item key, upsert,
    /// and refresh the list.
    func saveItem(id: UUID?, title: String, payload: LoginPayload, hosts: [SurfrCore.Host]) async {
        guard let store, phase == .unlocked else { return }
        do {
            var data = try payload.encoded()
            defer { data.resetBytes(in: 0..<data.count) }   // wipe the transient plaintext JSON
            let sealed = try lock.withVaultKey { key in try VaultCrypto.encryptNewItem(data, vaultKey: key) }
            let existing = items.first { $0.id == id }
            let now = Date()
            let item = StoredItem(
                id: id ?? UUID(),
                type: "login",
                title: title,
                createdAt: existing?.createdAt ?? now,
                modifiedAt: now,
                sealed: sealed,
                hosts: hosts,
                healthFlags: existing?.healthFlags ?? 0
            )
            try await store.upsert(item)
            await loadItems()
        } catch {
            lastError = "Could not save the item."
        }
    }

    func deleteItem(_ id: UUID) async {
        guard let store else { return }
        try? await store.deleteItem(id: id)
        await loadItems()
    }

    /// Biometric gate for revealing/copying a password (WF-5). If biometric isn't enabled, the vault
    /// is already unlocked so reveal proceeds (`true`). If enabled, require a fresh Touch ID via
    /// `LAContext.evaluatePolicy` — the reliable LA path (not the SE decrypt). **A cancel returns
    /// `false`**, so the caller simply stays masked: a no-op, never an error.
    func authenticateForReveal() async -> Bool {
        guard biometricState == .enabled else { return true }
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        return await withCheckedContinuation { cont in
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                   localizedReason: "Reveal your password") { ok, _ in
                cont.resume(returning: ok)
            }
        }
    }

    // MARK: - Biometric door (Slice 4)

    /// Enable biometric unlock: wrap the live (resident) vault key to the Secure Enclave. Requires the
    /// vault to be unlocked. No biometric prompt (public-key encrypt).
    func enableBiometric() {
        guard phase == .unlocked else { return }
        do {
            try lock.withVaultKey { try biometric.enable(vaultKey: $0) }
            biometricInvalidated = false
            refreshBiometricState()
            vaultLog("biometric enabled (vault key wrapped to Secure Enclave)")
        } catch {
            lastError = "Could not enable Touch ID."
            vaultLog("biometric enable failed")
        }
    }

    func disableBiometric() {
        biometric.disable()
        biometricInvalidated = false
        refreshBiometricState()
    }

    /// Recompute the single biometric state from the source of truth (service availability/enabled +
    /// the sticky invalidation flag). Called on every surface/overlay appear so the UI always mirrors
    /// reality — no app-restart needed.
    func refreshBiometricState() {
        let newState: BiometricState
        if biometricInvalidated {
            // We KNOW the stored key is dead. Offer re-enable whenever biometry is usable; this must
            // not be clobbered by a *transient* unavailability right after the failed decrypt — and it
            // recovers live once biometry is back (e.g. a fingerprint re-added), via the refresh on
            // app-activate / surface-appear. (Bug 2.)
            newState = biometric.isAvailable ? .invalidated : .unavailable
        } else if !biometric.isAvailable {
            newState = .unavailable
        } else {
            newState = biometric.isEnabled ? .enabled : .available
        }
        if newState != biometricState { biometricState = newState }
    }

    /// Cancel an in-flight Touch ID prompt — called when the user turns to master/recovery so the two
    /// paths are mutually exclusive (the prompt dismisses; the pending unlock resolves as a benign
    /// cancel that leaves biometric enabled).
    func cancelBiometricPrompt() { biometric.cancel() }

    /// Regenerate the Recovery Kit (authenticated): mint a fresh recovery code, re-wrap **copy 2** of
    /// the vault key under it (old code stops working), persist, and return the new code for the kit
    /// PDF. Requires the vault to be unlocked. Returns nil on failure.
    func regenerateRecoveryKit() async -> String? {
        guard phase == .unlocked, let store else { return nil }
        isWorking = true; lastError = nil
        defer { isWorking = false }
        guard let meta = try? await store.loadMeta() else { lastError = "No vault found."; return nil }
        let newCode = VaultCrypto.generateRecoveryCode()
        do {
            // Re-wrap with the live key (never leaves the lock's closure); deliberate, rare action.
            let newMeta = try lock.withVaultKey { key in
                try VaultCrypto.rewrapForNewRecovery(vaultKey: key, newRecoveryCode: newCode, meta: meta)
            }
            try await store.saveMeta(newMeta)
            // Observable proof (no secrets): the recovery salt + wrapped copy must have changed, which
            // is what makes the OLD code stop working. The new code is fresh CSPRNG (see test).
            let reloaded = try? await store.loadMeta()
            let saltChanged = reloaded?.kdfSaltRecovery != meta.kdfSaltRecovery
            let blobChanged = reloaded?.wrappedVaultKeyRecovery != meta.wrappedVaultKeyRecovery
            vaultLog("recovery kit regenerated — recovery salt changed=\(saltChanged), wrapped copy changed=\(blobChanged); old code now invalid")
            return newCode
        } catch {
            lastError = "Could not regenerate the Recovery Kit."
            return nil
        }
    }

    /// Attempt a biometric unlock. Returns true on success; on any failure returns false and leaves the
    /// master field as the fallback. An enrolment-change invalidation disables biometric and flags a
    /// re-enroll; a user cancel changes nothing.
    func unlockWithBiometric() async -> Bool {
        guard shouldOfferBiometric else { return false }
        isWorking = true; lastError = nil
        defer { isWorking = false }
        do {
            let key = try await biometric.unlock()
            lock.adopt(key)
            phase = .unlocked
            vaultLog("biometric unlock succeeded")
            return true
        } catch BiometricFailure.userCancelled {
            vaultLog("biometric unlock cancelled → master fallback")
            return false                       // fall to master, no penalty, stay enabled
        } catch BiometricFailure.invalidated {
            handleBiometricInvalidation()      // disable + message + button removal, on the FIRST failure
            return false
        } catch {
            // Transient (e.g. lockout): keep biometric enabled, but never fail silently.
            lastError = "Touch ID didn’t work — use your master password."
            vaultLog("biometric unlock failed (transient) → master fallback")
            return false
        }
    }

    /// The `.biometryCurrentSet` invalidation path: the stored SE key is dead. Disable immediately so
    /// the Touch ID button disappears this instant (`shouldOfferBiometric` flips false), refresh
    /// availability (re-enable is only offered if biometry is still enrolled), and surface the reset
    /// message — all on the first failure, no retry lag.
    private func handleBiometricInvalidation() {
        biometric.disable()
        biometricInvalidated = true        // sticky for the session
        refreshBiometricState()            // → .invalidated (single source of truth)
        lastError = "Touch ID was reset. Unlock with your master password."
        vaultLog("biometric invalidated (enrolment changed) → disabled, master required, re-enroll offered")
    }

    private func recordMasterAuth() {
        UserDefaults.standard.set(now(), forKey: lastMasterAuthKey)
    }

    /// DEBUG-only, **secret-free** status line for observing the biometric paths during the on-device
    /// driven run. Never logs keys, passwords, recovery codes, or vault contents.
    private func vaultLog(_ message: String) {
        #if DEBUG
        print("[Vault] \(message)")
        #endif
    }

    // MARK: - Storage location

    private static func defaultStorePath() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Surfr", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vault.sqlite")
    }

    #if DEBUG
    /// Test-only factory: fast Argon2 params + injected biometric door + temp store, so the test
    /// target doesn't need to name SurfrCore's `KDFParams`.
    static func makeForTests(storePath: URL,
                             biometric: BiometricUnlocking,
                             now: @escaping () -> Date = Date.init) -> VaultGate {
        VaultGate(storePath: storePath,
                  params: KDFParams(memoryKiB: 256, iterations: 1, parallelism: 1),
                  biometric: biometric,
                  now: now)
    }
    #endif
}
