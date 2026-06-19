import Foundation

/// A mutable byte buffer for a short-lived secret (a master password or recovery code) that can be
/// **deterministically zeroed** with `memset_s` — the same wipe discipline `VaultLock` uses for the
/// vault key. Used by `VaultGate` during first-run so an abandoned/committed flow leaves no retained
/// plaintext copy of the password or recovery code.
///
/// **Honest limitation:** SwiftUI/AppKit may make transient `String` copies when this value is shown
/// in a field or rendered into the kit PDF; those are released when the views go away but are not
/// reachable for an explicit wipe. This buffer is the gate's *canonical retained* copy, and it is
/// wiped — so we don't merely drop the secret, we zero what we hold.
final class WipeableSecret {
    private var bytes: [UInt8]
    private(set) var isWiped = false

    init(_ string: String) {
        bytes = Array(string.utf8)
    }

    /// Reconstruct the secret as a `String` at a use boundary (deriving a KEK, rendering the kit).
    /// Returns "" once wiped.
    func reveal() -> String {
        guard !isWiped else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }

    var isEmpty: Bool { isWiped || bytes.isEmpty }

    func wipe() {
        guard !isWiped, !bytes.isEmpty else { isWiped = true; return }
        bytes.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress { memset_s(base, raw.count, 0, raw.count) }
        }
        bytes.removeAll(keepingCapacity: false)
        isWiped = true
    }

    deinit { wipe() }
}
