import Foundation

/// Pure state machine for the **mandatory** vault first-run flow (WF-2 / vault-spec §5).
///
/// It holds **no secrets** and does **no I/O**: it only decides the current step and emits an
/// `Effect` describing what the `VaultGate` should do. The single effect that touches disk is
/// `.commitToDisk`, and this reducer is the proof that `.commitToDisk` is **unreachable** until the
/// Recovery Kit step has been acknowledged — i.e. there is no path to a committed vault that skips
/// the kit. The gate executes the effects (crypto, store writes, secret wipes).
struct FirstRunReducer: Equatable {

    enum Step: Equatable {
        case setMaster      // entering + confirming the master password
        case recoveryKit    // the in-memory vault exists; user must save the kit before committing
        case committed      // terminal — vault persisted, flow done
    }

    enum Action: Equatable {
        case masterAccepted     // user set + confirmed a master password
        case acknowledgeKit     // user clicked "I've saved my Recovery Kit"
        case abandon            // cancel / quit mid-flow
    }

    enum Effect: Equatable {
        case none
        case createInMemoryVault   // generate recovery code + VaultCrypto.createVault — IN MEMORY ONLY
        case commitToDisk          // VaultStore.saveMeta + adopt key into the lock — the ONLY disk write
        case wipeInMemory          // zero the master-password + recovery-code buffers (lock discipline)
    }

    private(set) var step: Step = .setMaster

    /// Apply an action, returning the side-effect the gate must perform. Total over all
    /// (step, action) pairs; any combination not listed below cannot occur because the cases are
    /// exhaustive — and none of those fallthroughs can emit `.commitToDisk`.
    mutating func apply(_ action: Action) -> Effect {
        switch (step, action) {
        case (.setMaster, .masterAccepted):
            step = .recoveryKit
            return .createInMemoryVault

        case (.recoveryKit, .acknowledgeKit):
            step = .committed
            return .commitToDisk

        case (_, .abandon):
            // Abandon from anywhere resets to the start and wipes in-memory secrets.
            step = .setMaster
            return .wipeInMemory

        // ── Guards: everything else is a no-op that can NEVER commit. ──
        // The load-bearing one is (.setMaster, .acknowledgeKit): you cannot acknowledge a kit
        // that does not exist yet, so the kit step cannot be skipped.
        case (.setMaster, .acknowledgeKit),
             (.recoveryKit, .masterAccepted),
             (.committed, .masterAccepted),
             (.committed, .acknowledgeKit):
            return .none
        }
    }
}
