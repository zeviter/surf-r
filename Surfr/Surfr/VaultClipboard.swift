import AppKit

/// Clipboard writes for the vault. Password copies are marked **concealed/transient** so compliant
/// clipboard-history managers and Handoff/Universal Clipboard skip them — a password shouldn't sync
/// sideways — and they auto-clear after a short delay. Username copies are normal.
enum VaultClipboard {
    /// Community convention (respected by clipboard managers) for "don't store/sync this".
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static let autoClearSeconds: TimeInterval = 30

    /// Copy a secret (password / TOTP) as concealed + transient, then clear it after `autoClearSeconds`
    /// if the pasteboard still holds it.
    static func copyConcealed(_ value: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
        pb.setString("", forType: concealedType)   // marker types — value lives only in .string
        pb.setString("", forType: transientType)
        scheduleClear(matching: value)
    }

    /// Copy a non-secret (username) normally.
    static func copyPlain(_ value: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
    }

    private static func scheduleClear(matching value: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + autoClearSeconds) {
            let pb = NSPasteboard.general
            if pb.string(forType: .string) == value { pb.clearContents() }   // only if unchanged
        }
    }
}
