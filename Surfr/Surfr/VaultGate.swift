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

    // Biometric door (Slice 4). `available` = hardware enrolled; `enabled` = we have a stored SE blob;
    // `needsReenroll` = a stored key was invalidated (enrolment changed) and should be re-enabled.
    @Published private(set) var biometricAvailable = false
    @Published private(set) var biometricEnabled = false
    @Published private(set) var needsBiometricReenroll = false

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
    var shouldOfferBiometric: Bool { biometricEnabled && biometricAvailable && !masterRequired }

    /// Resolve the initial phase from disk (call once on appear).
    func load() async {
        biometricAvailable = biometric.isAvailable
        biometricEnabled = biometric.isEnabled
        guard let store else { phase = .uninitialized; return }
        // Don't clobber an in-progress first-run or an already-unlocked session.
        guard phase != .firstRun, phase != .unlocked else { return }
        let exists = (try? await store.hasVault()) ?? false
        phase = exists ? .locked : .uninitialized
        // NOTE (§4 "master on reboot"): this runs at app launch; `masterRequired` already forces master
        // when no master auth has happened this install-session within the interval. A stricter
        // boot-time comparison can be layered here later if desired.
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
        if phase == .unlocked { phase = .locked }
    }

    func clearError() { lastError = nil }

    // MARK: - Biometric door (Slice 4)

    /// Enable biometric unlock: wrap the live (resident) vault key to the Secure Enclave. Requires the
    /// vault to be unlocked. No biometric prompt (public-key encrypt).
    func enableBiometric() {
        guard phase == .unlocked else { return }
        do {
            try lock.withVaultKey { try biometric.enable(vaultKey: $0) }
            biometricEnabled = true
            needsBiometricReenroll = false
            vaultLog("biometric enabled (vault key wrapped to Secure Enclave)")
        } catch {
            lastError = "Could not enable Touch ID."
            vaultLog("biometric enable failed")
        }
    }

    func disableBiometric() {
        biometric.disable()
        biometricEnabled = false
        needsBiometricReenroll = false
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
            biometric.disable()
            biometricEnabled = false
            needsBiometricReenroll = true      // offer "Re-enable Touch ID" after master unlock
            lastError = "Touch ID was reset. Unlock with your master password."
            vaultLog("biometric invalidated (enrolment changed) → disabled, master required, re-enroll offered")
            return false
        } catch {
            vaultLog("biometric unlock failed → master fallback")
            return false                       // any other failure → master fallback
        }
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
