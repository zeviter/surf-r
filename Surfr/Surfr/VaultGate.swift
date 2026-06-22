import Foundation
import Combine
import CryptoKit
import LocalAuthentication
import SurfrCore

/// Result of a CSV import (Slice 5b).
struct ImportSummary: Equatable {
    var imported: Int
    var skippedDuplicates: Int
    var failed: Bool
}

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
        savedVaultQuery = ""; savedVaultOpenItemID = nil
        UserDefaults.standard.removeObject(forKey: Self.hostRecoveryAttemptedKey)
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
            await loadItems()
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
            await loadItems()
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
            await loadItems()
            return true
        } catch {
            lastError = "Recovery code not recognized."
            return false
        }
    }

    func lockNow() {
        lock.lock()
        items = []
        savedVaultQuery = ""; savedVaultOpenItemID = nil   // reset UI state at the security boundary
        if phase == .unlocked { phase = .locked }
    }

    func clearError() { lastError = nil }

    // MARK: - Items (Slice 5)

    /// Cleartext metadata only (title/host/dates/health) — drives the list with **no decryption**.
    @Published private(set) var items: [StoredItem] = []

    /// Vault UI state that must survive the surface being recreated on navigate-away-and-back (the
    /// surface is ephemeral). Restored by `VaultListView`. Cleared on lock/reset.
    var savedVaultQuery = ""
    var savedVaultOpenItemID: UUID?

    /// (Re)load the list. Only the cleartext metadata is read; payloads stay encrypted on disk.
    static let hostRecoveryAttemptedKey = "SurfrVaultHostRecoveryAttemptedIDs"

    func loadItems() async {
        guard let store, phase == .unlocked else { items = []; return }
        var loaded = (try? await store.allItems()) ?? []
        var changed = false

        // Step 1 — every load, NO decryption: reduce existing item_hosts to the registrable domain
        // (heals www./full-URL/subdomain+path forms). Idempotent: once bare, re-running is a no-op.
        for item in loaded {
            let desired = Self.normalizedHosts(item.hosts)
            if !desired.isEmpty, desired.map(\.host) != item.hosts.map(\.host) {
                try? await store.updateHosts(desired, forItemID: item.id); changed = true
            }
        }

        // Step 2 — recover a host from the encrypted payload's URLs for items that have NO item_hosts
        // (an early import where URL parsing failed and stored nothing — e.g. Barbican). Tracked
        // PER ITEM (not a global flag), so each empty-host item gets exactly one recovery attempt ever:
        // truly hostless items (TOTP-only) are decrypted at most once, and a still-broken item is never
        // permanently skipped just because some earlier migration ran.
        var attempted = Set(UserDefaults.standard.stringArray(forKey: Self.hostRecoveryAttemptedKey) ?? [])
        var attemptedChanged = false
        for item in loaded where item.hosts.isEmpty && !attempted.contains(item.id.uuidString) {
            attempted.insert(item.id.uuidString); attemptedChanged = true
            guard let payload = decryptPayload(item) else { continue }
            let desired = Self.normalizedHosts(payload.urls.map { SurfrCore.Host(host: $0, isPrimary: true) })
            if !desired.isEmpty { try? await store.updateHosts(desired, forItemID: item.id); changed = true }
        }
        if attemptedChanged { UserDefaults.standard.set(Array(attempted), forKey: Self.hostRecoveryAttemptedKey) }

        if changed { loaded = (try? await store.allItems()) ?? loaded }
        items = loaded
    }

    /// Reduce each host to its registrable domain (from host-or-URL) and de-duplicate, preserving the
    /// primary flag. Shared by the loadItems repair pass.
    static func normalizedHosts(_ hosts: [SurfrCore.Host]) -> [SurfrCore.Host] {
        var seen = Set<String>()
        var out: [SurfrCore.Host] = []
        for h in hosts {
            let domain = TrustStore.registrableDomain(forHostOrURL: h.host)
            guard !domain.isEmpty, seen.insert(domain).inserted else { continue }
            out.append(SurfrCore.Host(host: domain, isPrimary: h.isPrimary))
        }
        return out
    }

    /// Decrypt ONE item's payload (detail view), via the unlocked vault key. Returns nil if locked /
    /// on failure. This is the only place a credential payload is decrypted.
    func decryptPayload(_ item: StoredItem) -> LoginPayload? {
        guard phase == .unlocked else { return nil }
        return try? lock.withVaultKey { key in
            var data = try VaultCrypto.decryptItem(item.sealed, vaultKey: key)
            defer { data.resetBytes(in: 0..<data.count) }   // zero the decrypted JSON immediately after use
            return try LoginPayload.decoded(from: data)
        }
    }

    // MARK: - Save-on-submit (Slice 8b)

    private static let neverSaveKey = "SurfrVaultNeverSaveDomains"
    /// Registrable domains the user said "Never save" for. Persisted.
    private(set) var neverSaveDomains: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: VaultGate.neverSaveKey) ?? [])

    func neverSave(domain: String) {
        let d = TrustStore.registrableDomain(forHostOrURL: domain)
        guard !d.isEmpty else { return }
        neverSaveDomains.insert(d)
        UserDefaults.standard.set(Array(neverSaveDomains), forKey: Self.neverSaveKey)
    }

    /// Classify a captured credential. Decrypts existing same-domain items to compare (the decrypted
    /// JSON Data is zeroed in `decryptPayload`; the transient `String`s are dropped immediately after).
    func saveDecision(host: String, username: String, password: String) -> SaveDecision {
        let domain = TrustStore.registrableDomain(forHostOrURL: host)
        if neverSaveDomains.contains(domain) { return .neverListed }
        guard phase == .unlocked, !domain.isEmpty else { return .save }   // can't dedup while locked
        let matched = items.filter { $0.hosts.contains { TrustStore.registrableDomain(forHostOrURL: $0.host) == domain } }
        var existing: [(id: UUID, username: String, password: String)] = []
        for it in matched { if let p = decryptPayload(it) { existing.append((it.id, p.username, p.password)) } }
        defer { existing.removeAll() }   // drop decrypted copies ASAP
        return SaveDecision.classify(username: username, password: password, existing: existing, neverListed: false)
    }

    /// Store a captured credential per the decision (new item or password update).
    func saveFromCapture(host: String, username: String, password: String, decision: SaveDecision) async {
        let domain = TrustStore.registrableDomain(forHostOrURL: host)
        switch decision {
        case .save:
            let label = TrustStore.primaryLabel(forDomain: domain)
            await saveItem(id: nil, title: label.isEmpty ? domain : label,
                           payload: LoginPayload(username: username, password: password, urls: ["https://\(domain)"]),
                           hosts: [SurfrCore.Host(host: domain, isPrimary: true)])
        case .update(let id):
            guard let it = items.first(where: { $0.id == id }), var payload = decryptPayload(it) else { return }
            payload.password = password
            await saveItem(id: id, title: it.title, payload: payload, hosts: it.hosts)
        case .noPrompt, .neverListed:
            break
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

    /// Bulk CSV import (Slice 5b): skip EXACT duplicates (every field incl. password — a same
    /// title/host/username but different password is a distinct credential and IS imported), encrypt
    /// the survivors under fresh per-item keys, and store them in **one atomic transaction** (a
    /// failure changes nothing). Requires the vault unlocked.
    func importLogins(_ candidates: [ImportCandidate]) async -> ImportSummary {
        guard let store, phase == .unlocked else { return ImportSummary(imported: 0, skippedDuplicates: 0, failed: true) }
        isWorking = true; defer { isWorking = false }

        // Fingerprints of existing items (decrypt each once) — and within-file dupes via the same set.
        var seen = Set<String>()
        for it in items {
            if let p = decryptPayload(it) { seen.insert(Self.fingerprint(title: it.title, hosts: it.hosts, payload: p)) }
        }

        var skippedDuplicates = 0
        let now = Date()
        do {
            let toStore: [StoredItem] = try lock.withVaultKey { key in
                var out: [StoredItem] = []
                for c in candidates {
                    let fp = Self.fingerprint(title: c.title, hosts: c.hosts, payload: c.payload)
                    guard seen.insert(fp).inserted else { skippedDuplicates += 1; continue }
                    var data = try c.payload.encoded()
                    let sealed = try VaultCrypto.encryptNewItem(data, vaultKey: key)
                    data.resetBytes(in: 0..<data.count)   // wipe the transient plaintext JSON
                    out.append(StoredItem(title: c.title, createdAt: now, modifiedAt: now, sealed: sealed, hosts: c.hosts))
                }
                return out
            }
            try await store.upsertMany(toStore)   // atomic — all or nothing
            await loadItems()
            vaultLog("import: \(toStore.count) added, \(skippedDuplicates) exact-duplicate(s) skipped")
            return ImportSummary(imported: toStore.count, skippedDuplicates: skippedDuplicates, failed: false)
        } catch {
            lastError = "Import failed — nothing was changed."
            return ImportSummary(imported: 0, skippedDuplicates: 0, failed: true)
        }
    }

    /// A conservative auto-match suggestion for a TOTP entry → an existing login, used only to *offer*
    /// an attach (never silent). Returns a match ONLY when exactly one item's title equals the issuer
    /// or a host contains it; any ambiguity (0 or >1) → nil → default to create-new.
    func suggestedMatchForTOTP(issuer: String) -> UUID? {
        let iss = issuer.lowercased().trimmingCharacters(in: .whitespaces)
        guard !iss.isEmpty else { return nil }
        let matches = items.filter { item in
            item.title.lowercased() == iss || item.hosts.contains { $0.host.lowercased().contains(iss) }
        }
        return matches.count == 1 ? matches[0].id : nil
    }

    /// Import TOTP entries (from paste / QR / GAuth migration). Each decision either ATTACHES the seed
    /// to an existing login (only when the user confirmed the offered match) or CREATES a new
    /// TOTP-only item. Encrypt under fresh per-item keys, store in one atomic transaction.
    func importTOTP(_ decisions: [TOTPImportDecision]) async -> ImportSummary {
        guard let store, phase == .unlocked, !decisions.isEmpty else {
            return ImportSummary(imported: 0, skippedDuplicates: 0, failed: decisions.isEmpty ? false : true)
        }
        isWorking = true; defer { isWorking = false }

        // Pre-decrypt the items we'll attach to.
        var attachTargets: [UUID: (item: StoredItem, payload: LoginPayload)] = [:]
        for d in decisions {
            guard let id = d.attachTo, attachTargets[id] == nil, let it = items.first(where: { $0.id == id }),
                  let p = decryptPayload(it) else { continue }
            attachTargets[id] = (it, p)
        }
        let now = Date()
        do {
            let toStore: [StoredItem] = try lock.withVaultKey { key in
                var out: [StoredItem] = []
                for d in decisions {
                    let uri = d.totp.otpauthURI()
                    if let id = d.attachTo, let target = attachTargets[id] {
                        var payload = target.payload
                        payload.totp = uri
                        var data = try payload.encoded()
                        let sealed = try VaultCrypto.encryptNewItem(data, vaultKey: key)
                        data.resetBytes(in: 0..<data.count)
                        out.append(StoredItem(id: target.item.id, type: target.item.type, title: target.item.title,
                                              createdAt: target.item.createdAt, modifiedAt: now, sealed: sealed,
                                              hosts: target.item.hosts, healthFlags: target.item.healthFlags))
                    } else {
                        let title = d.totp.issuer.isEmpty ? d.totp.account : d.totp.issuer
                        var data = try LoginPayload(totp: uri).encoded()
                        let sealed = try VaultCrypto.encryptNewItem(data, vaultKey: key)
                        data.resetBytes(in: 0..<data.count)
                        out.append(StoredItem(title: title.isEmpty ? "One-time code" : title,
                                              createdAt: now, modifiedAt: now, sealed: sealed, hosts: []))
                    }
                }
                return out
            }
            try await store.upsertMany(toStore)
            await loadItems()
            return ImportSummary(imported: toStore.count, skippedDuplicates: 0, failed: false)
        } catch {
            lastError = "Couldn’t import the one-time codes — nothing was changed."
            return ImportSummary(imported: 0, skippedDuplicates: 0, failed: true)
        }
    }

    /// Exact-match fingerprint across ALL fields (so different-password rows are distinct). Hashed so
    /// no plaintext lingers in the dedupe set.
    private static func fingerprint(title: String, hosts: [SurfrCore.Host], payload: LoginPayload) -> String {
        let host = hosts.first?.host ?? ""
        let joined = [title, host, payload.username, payload.password, payload.notes,
                      payload.totp ?? "", payload.urls.joined(separator: " ")].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Setting (WF-5, 6b): require authentication before revealing/copying a password — independent of
    /// whether biometric *unlock* is enabled. Default **ON** (it's a password manager). When off,
    /// reveal/copy is direct (the vault is already unlocked).
    @Published var requireAuthToReveal: Bool = (UserDefaults.standard.object(forKey: "SurfrVaultRequireAuthToReveal") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(requireAuthToReveal, forKey: "SurfrVaultRequireAuthToReveal") }
    }

    /// Fresh biometric check for reveal/copy via `LAContext.evaluatePolicy` (the reliable LA path, not
    /// the SE decrypt). Returns false on cancel/failure → the caller then offers the master-password
    /// fallback (6a). Only meaningful when `biometricState == .enabled`.
    func biometricAuthenticateForReveal() async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Use master password"
        return await withCheckedContinuation { cont in
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                   localizedReason: "Reveal your password") { ok, _ in
                cont.resume(returning: ok)
            }
        }
    }

    /// Verify the master password (the reveal fallback) WITHOUT changing lock state — re-derives the
    /// KEK and confirms it unwraps the vault key.
    func verifyMaster(_ password: String) async -> Bool {
        guard let store, let meta = try? await store.loadMeta() else { return false }
        let ok = await Task.detached(priority: .userInitiated) {
            (try? VaultCrypto.unlockWithMaster(password, meta: meta)) != nil
        }.value
        return ok
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
            await loadItems()
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
