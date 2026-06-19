import Foundation
import CryptoKit

/// Owns the **live** vault key's in-memory residency — the lifetime Slice 1 deferred. A small state
/// machine: `locked` (no key in memory) ↔ `unlocked` (key resident). Unlock *orchestration* stays in
/// `VaultCrypto`; this type only takes residency of the returned key and zeroes it on lock.
///
/// **What it holds:** only the vault key. Per-item keys are derived transiently per-operation inside
/// `VaultCrypto` and never retained here; KEKs are wiped in Slice 1. So a transition to `locked` has
/// exactly one secret to zero — the vault-key residency buffer.
///
/// Thread-safe via an internal `NSLock`; `@unchecked Sendable` is justified because every access to
/// mutable state is guarded.
public final class VaultLock: @unchecked Sendable {

    public enum State: Equatable, Sendable { case locked, unlocked }

    private let mutex = NSLock()
    private var residency: VaultKeyResidency?
    private var lastActivity: Date
    private var idleTimer: DispatchSourceTimer?

    /// Idle window before auto-lock (vault-spec §4 default: 5 minutes).
    public let autoLockInterval: TimeInterval
    private let now: @Sendable () -> Date

    /// - Parameter now: injectable clock so idle-timeout logic is deterministically testable; defaults
    ///   to the wall clock, matching the `DispatchSourceTimer` used by `startIdleTimer`.
    public init(autoLockInterval: TimeInterval = 300,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.autoLockInterval = autoLockInterval
        self.now = now
        self.lastActivity = now()
    }

    deinit {
        idleTimer?.cancel()
        residency?.evict()
    }

    public var state: State {
        mutex.lock(); defer { mutex.unlock() }
        return residency == nil ? .locked : .unlocked
    }

    // MARK: - Unlock (delegates the envelope to VaultCrypto, then takes residency)

    public func unlockWithMaster(_ password: String, meta: VaultMeta) throws {
        let key = try VaultCrypto.unlockWithMaster(password, meta: meta)
        takeResidency(of: key)
    }

    public func unlockWithRecovery(_ code: String, meta: VaultMeta) throws {
        let key = try VaultCrypto.unlockWithRecovery(code, meta: meta)
        takeResidency(of: key)
    }

    private func takeResidency(of key: SymmetricKey) {
        mutex.lock(); defer { mutex.unlock() }
        residency?.evict()
        residency = VaultKeyResidency(key)
        lastActivity = now()
    }

    // MARK: - Scoped key access

    /// Run `body` with the vault key while unlocked; throws `VaultLockError.locked` otherwise.
    ///
    /// ⚠️ **Closure contract — read this.** The `SymmetricKey` handed to `body` is a *fresh transient
    /// copy*, valid **only** for the synchronous duration of the call. `body` MUST NOT retain, copy,
    /// stash, or escape it (no storing into a property, capturing in an escaping closure, or returning
    /// it). Use it, derive/seal/open with it, and let it go — `lock()` can zero the residency the
    /// instant this returns. Do your crypto inside the closure; return only the result.
    ///
    /// **By design this does NOT reset the idle timer.** Reading a credential is not "user activity";
    /// only an explicit `noteActivity()` (driven by real user interaction in the app layer) defers
    /// auto-lock. So a long-running background reader can't keep the vault unlocked forever.
    public func withVaultKey<T>(_ body: (SymmetricKey) throws -> T) throws -> T {
        mutex.lock()
        guard let residency else {
            mutex.unlock()
            throw VaultLockError.locked
        }
        let key = residency.makeKey()   // fresh transient SymmetricKey per call
        mutex.unlock()                  // don't hold the mutex across the user closure (reentrancy-safe)
        return try body(key)
    }

    // MARK: - Lock transitions (each zeroes the residency)

    /// Lock now: zero the vault-key residency and drop to `locked`. Idempotent.
    public func lock() {
        mutex.lock(); defer { mutex.unlock() }
        residency?.evict()
        residency = nil
    }

    /// Record genuine user activity, deferring idle auto-lock. The app layer calls this on real
    /// interaction — NOT on every `withVaultKey`.
    public func noteActivity() {
        mutex.lock(); defer { mutex.unlock() }
        lastActivity = now()
    }

    /// Lock if the idle window has elapsed since the last `noteActivity()` / unlock. Returns whether
    /// it locked. Driven by `startIdleTimer` in the app, or called directly (with an injected clock)
    /// in tests.
    @discardableResult
    public func lockIfIdle() -> Bool {
        mutex.lock(); defer { mutex.unlock() }
        guard residency != nil, now().timeIntervalSince(lastActivity) >= autoLockInterval else {
            return false
        }
        residency?.evict()
        residency = nil
        return true
    }

    // MARK: - Real-time idle driver (app starts it; logic stays clock-injectable for tests)

    /// Start a background timer that periodically calls `lockIfIdle()`. No-op if already running.
    public func startIdleTimer(checkInterval: TimeInterval = 30) {
        mutex.lock(); defer { mutex.unlock() }
        guard idleTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.zeviter.surfr.vaultlock.idle"))
        timer.schedule(deadline: .now() + checkInterval, repeating: checkInterval)
        timer.setEventHandler { [weak self] in self?.lockIfIdle() }
        idleTimer = timer
        timer.resume()
    }

    public func stopIdleTimer() {
        mutex.lock(); defer { mutex.unlock() }
        idleTimer?.cancel()
        idleTimer = nil
    }

    // MARK: - Background / resign-active seam
    //
    // Lock-on-background and lock-on-resign-active (vault-spec §4) are wired by the **app layer**,
    // which calls `lock()` from the relevant NSApplication/UIApplication notifications. Those AppKit/
    // UIKit symbols are deliberately not imported here, keeping SurfrCore import-clean.

    #if DEBUG
    /// Test hook: is the residency buffer currently present and zeroed? `nil` when there is no
    /// residency (already dropped). Lets the eviction test assert real zeroing, not just inaccessibility.
    var residencyIsZeroedForTest: Bool? {
        mutex.lock(); defer { mutex.unlock() }
        return residency?.isZeroedForTest
    }
    #endif
}

public enum VaultLockError: Error, Equatable {
    case locked
}

// MARK: - VaultKeyResidency

/// Owns the unlocked vault key's bytes in a heap buffer we control, so zeroing on lock is
/// **deterministic and testable** rather than relying solely on CryptoKit's deallocation-time wipe.
/// Access rebuilds a fresh transient `SymmetricKey`; the raw bytes are zeroed with `memset_s` (which
/// the compiler may not elide) on `evict()` and again on `deinit` as a backstop.
final class VaultKeyResidency {
    private let buffer: UnsafeMutableRawBufferPointer
    private let count: Int
    private(set) var isZeroed = false

    init(_ key: SymmetricKey) {
        count = key.withUnsafeBytes { $0.count }
        buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: count, alignment: 1)
        key.withUnsafeBytes { src in
            buffer.copyMemory(from: UnsafeRawBufferPointer(start: src.baseAddress, count: src.count))
        }
    }

    func makeKey() -> SymmetricKey {
        var tmp = Data(bytes: buffer.baseAddress!, count: count)
        defer { tmp.resetBytes(in: 0..<tmp.count) }
        return SymmetricKey(data: tmp)
    }

    func evict() {
        guard !isZeroed, let base = buffer.baseAddress else { isZeroed = true; return }
        memset_s(base, count, 0, count)   // guaranteed-not-elided zeroing
        isZeroed = true
    }

    #if DEBUG
    var isZeroedForTest: Bool {
        for i in 0..<count where buffer.load(fromByteOffset: i, as: UInt8.self) != 0 { return false }
        return true
    }
    #endif

    deinit {
        if !isZeroed, let base = buffer.baseAddress { memset_s(base, count, 0, count) }
        buffer.deallocate()
    }
}
